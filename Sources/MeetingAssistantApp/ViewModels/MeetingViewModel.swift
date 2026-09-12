import AppKit
import AVFoundation
import Combine
import Foundation
import MeetingAssistantCore
import Synchronization

/// Coalesce meters and diagnostics while preserving every finalized event.
/// A slow frontend fails explicitly instead of silently dropping transcript text.
final class SessionMailbox: Sendable {
    struct Batch: Sendable {
        var phase: MeetingPhase?
        var metrics: [AudioSource: AudioMetrics] = [:]
        var events: [TranscriptEvent] = []
        var diagnostics: [String] = []
    }
    private let pending = Mutex(Batch())

    var callbacks: MeetingCallbacks {
        MeetingCallbacks(
            phase: { phase in self.pending.withLock { $0.phase = phase } },
            metrics: { metrics in self.pending.withLock { $0.metrics[metrics.source] = metrics } },
            diagnostic: { message in
                self.pending.withLock {
                    $0.diagnostics.append(message)
                    if $0.diagnostics.count > 100 { $0.diagnostics.removeFirst() }
                }
            },
            transcript: { event in
                try self.pending.withLock {
                    guard $0.events.count < 1024 else {
                        throw MeetingError("The interface cannot keep up with finalized transcript events")
                    }
                    $0.events.append(event)
                }
            }
        )
    }

    func drain() -> Batch {
        pending.withLock { batch in
            let result = batch
            batch = Batch()
            return result
        }
    }
}

@MainActor
final class MeetingViewModel: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published var microphoneID: UInt32? { didSet { rememberDevice(microphoneID, key: "microphoneName") } }
    @Published var remoteID: UInt32? { didSet { rememberDevice(remoteID, key: "remoteName") } }
    @Published private(set) var modelPath: String
    @Published private(set) var tokenizerPath: String
    @Published private(set) var modelReady = false
    @Published private(set) var phase: MeetingPhase = .idle
    @Published private(set) var isBusy = false
    @Published private(set) var isAudioTest = false
    @Published private(set) var hasMeeting = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var metrics: [AudioSource: AudioMetrics] = [:]
    @Published private(set) var transcript: [TranscriptEvent] = []
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorDetails = ""
    @Published private(set) var aiState = AIState()
    @Published private(set) var aiWasEnabled = false
    @Published var focusedEventID: String?
    @Published var contextMessage = ""
    @Published private(set) var contextMessageError: String?
    @Published private(set) var isSendingContextMessage = false
    let aiSettings: AISettingsViewModel

    private let preferences: UserDefaults
    private var session: MeetingSession?
    private var runTask: Task<Void, Never>?
    private var stopPending = false
    private var lastActivePhase: MeetingPhase = .idle

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        aiSettings = AISettingsViewModel(preferences: preferences)
        modelPath = preferences.string(forKey: "modelPath") ?? ""
        tokenizerPath = preferences.string(forKey: "tokenizerPath") ?? ""
        refresh()
    }

    var canStart: Bool { !isBusy && inputsReady && modelReady }
    var inputsReady: Bool { microphoneID != nil && remoteID != nil && microphoneID != remoteID }
    var canStop: Bool { isBusy && !stopPending && phase != .finishingAnalysis }

    var statusText: String {
        if phase == .finishingAnalysis {
            return aiState.phase == .unloading ? "Освобождаем модель…" : "Готовим протокол встречи…"
        }
        if stopPending { return "Завершаем обработку фраз…" }
        switch phase {
        case .idle: return "Готовы к встрече"
        case .preparing: return "Проверяем доступ к аудио…"
        case .loadingModels: return "Загружаем модель распознавания…"
        case .running: return isAudioTest ? "Проверка звука" : "Встреча идёт"
        case .stopping: return "Завершаем обработку фраз…"
        case .finishingAnalysis: return "Готовим протокол встречи…"
        case .stopped: return isAudioTest ? "Проверка завершена" : "Встреча завершена"
        case .failed: return "Не удалось завершить сессию"
        }
    }

    func deviceName(_ source: AudioSource) -> String {
        let id = source == .you ? microphoneID : remoteID
        return devices.first { $0.id == id }?.name ?? "Устройство не выбрано"
    }

    func refresh() {
        guard !isBusy else { return }
        errorMessage = nil; errorDetails = ""
        do {
            devices = try AudioDeviceManager.devices().filter { $0.inputChannels > 0 }
            microphoneID = try? AudioDeviceManager.select(devices, name: preferences.string(forKey: "microphoneName"), source: .you).id
            remoteID = try? AudioDeviceManager.select(devices, name: preferences.string(forKey: "remoteName"), source: .remote).id
        } catch {
            devices = []; microphoneID = nil; remoteID = nil
            showError("Не удалось получить список аудиоустройств. Проверьте подключение и обновите список.", error)
        }
        checkModel()
    }

    private func rememberDevice(_ id: UInt32?, key: String) {
        if let device = devices.first(where: { $0.id == id }) { preferences.set(device.name, forKey: key) }
    }

    private func checkModel() {
        do {
            _ = try ModelPaths(model: modelPath.isEmpty ? nil : modelPath, tokenizer: tokenizerPath.isEmpty ? nil : tokenizerPath)
            modelReady = true
        } catch {
            modelReady = false
            showError("Не найдены файлы локальной модели. Укажите папки модели и словаря в настройках аудио.", error)
        }
    }

    func chooseModelFolder(tokenizer: Bool) {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = tokenizer ? "Выберите папку словаря Whisper large-v3" : "Выберите папку модели Whisper large-v3"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if tokenizer { tokenizerPath = url.path; preferences.set(url.path, forKey: "tokenizerPath") }
        else { modelPath = url.path; preferences.set(url.path, forKey: "modelPath") }
        errorMessage = nil; errorDetails = ""
        checkModel()
    }

    func start(audioTest: Bool = false) {
        guard !isBusy, inputsReady, audioTest || modelReady else { return }
        isBusy = true; isAudioTest = audioTest; stopPending = false
        phase = .preparing; lastActivePhase = .preparing; errorMessage = nil; errorDetails = ""
        metrics = [:]; diagnostics = []
        let ai = !audioTest && aiSettings.enabled ? aiSettings.configuration : nil
        if !audioTest {
            transcript = []; elapsed = 0; hasMeeting = true
            aiWasEnabled = ai != nil; aiState = AIState(); focusedEventID = nil
            contextMessage = ""; contextMessageError = nil
        }
        // Mark busy before permission/model loading so repeated clicks cannot start
        // overlapping sessions. Stop is also valid while permission is pending.
        runTask = Task { await performRun(audioTest: audioTest, ai: ai) }
    }

    private func performRun(audioTest: Bool, ai: AIConfiguration?) async {
        defer {
            session = nil; runTask = nil; isBusy = false; stopPending = false
            metrics = [:]
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            phase = .failed("Microphone permission denied")
            showError("Разрешите MeetingAssistant доступ к микрофону в Системных настройках → Конфиденциальность и безопасность → Микрофон.", MeetingError("Microphone permission denied"))
            return
        }
        guard !stopPending else { phase = .stopped; return }
        do {
            // Refresh metadata immediately before starting; match the explicitly
            // selected IDs and names, and report unplugged devices without fallback.
            let available = try AudioDeviceManager.devices()
            var selected: [AudioSource: AudioDevice] = [:]
            for source in AudioSource.allCases {
                let id = source == .you ? microphoneID : remoteID
                guard let old = devices.first(where: { $0.id == id }),
                      let current = available.first(where: { $0.id == id && $0.name == old.name && $0.inputChannels > 0 }) else {
                    throw MeetingError("\(source.rawValue): selected device is no longer available")
                }
                selected[source] = current
            }
            var configuration = MeetingConfiguration(selected: selected)
            configuration.captureOnly = audioTest
            configuration.modelPath = modelPath.isEmpty ? nil : modelPath
            configuration.tokenizerPath = tokenizerPath.isEmpty ? nil : tokenizerPath
            configuration.ai = ai
            let mailbox = SessionMailbox()
            var callbacks = mailbox.callbacks
            callbacks.analysis = { [weak self] state in await self?.receiveAnalysis(state) }
            let session = MeetingSession(configuration: configuration, callbacks: callbacks)
            self.session = session
            let pump = Task {
                while !Task.isCancelled {
                    apply(mailbox.drain(), audioTest: audioTest)
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
            do {
                try await session.run()
                pump.cancel()
                await pump.value
                apply(mailbox.drain(), audioTest: audioTest)
            } catch {
                pump.cancel()
                await pump.value
                apply(mailbox.drain(), audioTest: audioTest)
                throw error
            }
        } catch {
            let previousPhase = lastActivePhase
            phase = .failed(String(describing: error))
            let message: String
            if previousPhase == .preparing {
                message = "Выбранный источник звука недоступен. Проверьте подключение микрофона и BlackHole, затем обновите список устройств."
            } else if previousPhase == .loadingModels || metrics.isEmpty {
                message = "Не удалось запустить распознавание. Проверьте локальную модель и доступность выбранных аудиоустройств."
            } else {
                message = "Обработка встречи остановилась. Проверьте аудиоустройства и нагрузку на Mac. Полученный текст остался в окне встречи."
            }
            showError(message, error)
        }
    }

    private func apply(_ batch: SessionMailbox.Batch, audioTest: Bool) {
        if let phase = batch.phase {
            self.phase = phase
            if case .failed = phase { } else { lastActivePhase = phase }
        }
        for (source, metric) in batch.metrics {
            metrics[source] = metric
            if !audioTest { elapsed = max(elapsed, metric.elapsed) }
        }
        transcript.append(contentsOf: batch.events)
        diagnostics.append(contentsOf: batch.diagnostics)
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
        // Temporary in-memory GUI transcript, until the persistence milestone.
        // Stop at a generous bound, retaining the final drain as well.
        if transcript.count >= 10_000 && !stopPending {
            errorMessage = "Достигнут лимит текста этой версии. Встреча завершается; скопируйте транскрипт перед новой встречей."
            stop()
        }
    }

    func stop() {
        guard isBusy else { return }
        stopPending = true
        session?.requestStop()
    }

    func stopAndWait() async {
        stop()
        await runTask?.value
    }

    private func receiveAnalysis(_ state: AIState) { aiState = state }

    func cancelAnalysis() { session?.cancelAnalysis() }
    func retryAnalysis() { session?.retryAnalysis() }
    var canSendContextMessage: Bool { isBusy && aiWasEnabled && canStop && !isSendingContextMessage && ![.disabled, .cancelled, .completed, .unloading].contains(aiState.phase) }
    func sendContextMessage() async {
        guard canSendContextMessage, let session else { return }
        let text = contextMessage
        isSendingContextMessage = true
        defer { isSendingContextMessage = false }
        do {
            try await session.addContextMessage(text, time: elapsed)
            if contextMessage == text { contextMessage = "" }
            contextMessageError = nil
        } catch { contextMessageError = String(describing: error) }
    }

    func copyProtocol() {
        guard aiState.protocolComplete else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(aiState.protocolText, forType: .string)
    }

    func copyTranscript() {
        let text = transcript.map { "[\(Self.timestamp($0.startTime))] \($0.source.rawValue): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func timestamp(_ time: Double) -> String {
        let seconds = Int(max(0, time))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func showError(_ message: String, _ error: any Error) {
        errorMessage = message; errorDetails = String(describing: error)
    }
}
