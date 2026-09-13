import Foundation
import FluidAudio
import Synchronization

/// Capture only copies PCM into this bounded inlet. Inference never holds this lock.
final class DiarizationInlet: Sendable {
    struct Packet: Sendable { let samples: [Float]; let start: Double }
    private struct Storage {
        var packets: [Packet] = []
        var samples = 0
        var closed = false
        var failure: String?
    }
    private let storage = Mutex(Storage())
    func append(_ samples: [Float], start: Double) {
        guard !samples.isEmpty else { return }
        storage.withLock { state in
            guard !state.closed, state.failure == nil else { return }
            guard state.samples + samples.count <= 30 * 16000 else {
                state.failure = "Диаризация отстала более чем на 30 секунд и остановлена. Транскрипция продолжается."
                state.packets = []; state.samples = 0
                return
            }
            state.packets.append(Packet(samples: samples, start: start)); state.samples += samples.count
        }
    }
    func next() throws -> Packet? {
        try storage.withLock { state in
            if let failure = state.failure { throw MeetingError(failure) }
            guard !state.packets.isEmpty else { return nil }
            let packet = state.packets.removeFirst(); state.samples -= packet.samples.count
            return packet
        }
    }
    func close() { storage.withLock { $0.closed = true } }
    func abandon() { storage.withLock { $0.closed = true; $0.packets = []; $0.samples = 0 } }
    var drained: Bool { storage.withLock { $0.closed && $0.packets.isEmpty } }
}

/// One actor and persistent model state per source for the whole meeting.
/// Never reset/enroll between packets: that would erase voice memory and timestamps.
actor SourceDiarizer {
    nonisolated let inlet = DiarizationInlet()
    private let source: AudioSource
    private let modelURL: URL
    private let modelSelection: DiarizationModel
    private let output: @Sendable (DiarizationState) -> Void
    private var window: SpeakerActivityWindow
    private var state: DiarizationState
    private struct Snapshot: Sendable {
        var window: SpeakerActivityWindow
        var state: DiarizationState
        var finished = false
    }
    private nonisolated let snapshot: Mutex<Snapshot>

    init(source: AudioSource, model: DiarizationModel = .lsEENDDIHARD3, modelURL: URL? = nil, output: @escaping @Sendable (DiarizationState) -> Void) {
        self.source = source; self.modelURL = modelURL ?? DiarizationModels.modelURL(for: model); self.output = output
        modelSelection = model
        window = SpeakerActivityWindow(source: source)
        state = DiarizationState(source: source, phase: .loading)
        state.model = model
        snapshot = Mutex(Snapshot(window: window, state: state))
    }

    private func publish(finished: Bool = false) {
        snapshot.withLock { $0 = Snapshot(window: window, state: state, finished: finished) }
        output(state)
    }

    func run() async {
        publish()
        defer { inlet.abandon(); publish(finished: true) }
        do {
            guard FileManager.default.fileExists(atPath: modelURL.path) else { throw MeetingError("Подготовьте модель диаризации в настройках аудио.") }
            let diarizer = try DiarizationModels.makeDiarizer(modelSelection, at: modelURL)
            defer { diarizer.cleanup() }
            guard let frameHz = diarizer.modelFrameHz, frameHz > 0, let speakers = diarizer.numSpeakers else {
                throw MeetingError("Модель не сообщила частоту кадров и число голосов.")
            }
            state.phase = .ready; publish()
            var origin: Double?
            var end = 0.0
            var pending: [Float] = []
            func record(_ update: DiarizerTimelineUpdate?) throws {
                guard let update, let origin else { return }
                try window.ingest(update.chunkResult.finalizedPredictions, frameStart: update.chunkResult.startFrame,
                    frameDuration: 1 / frameHz, speakers: speakers, origin: origin, audioEnd: end)
                state.processedThrough = min(end, window.processedThrough)
                state.detectedSpeakers = window.detected.count
                state.participants = window.ledger.participants
                if let sortformer = diarizer as? SortformerDiarizer {
                    state.voiceMemoryFrames = sortformer.state.spkcacheLength + sortformer.state.fifoLength
                }
                state.phase = .running
                publish()
            }
            while !Task.isCancelled {
                if let packet = try inlet.next() {
                    if origin == nil { origin = packet.start; end = packet.start }
                    guard abs(packet.start - end) < 0.05 else { throw MeetingError("Разрыв временной шкалы диаризации. Транскрипция продолжается.") }
                    end = packet.start + Double(packet.samples.count) / 16000
                    pending += packet.samples
                    if pending.count >= 8000 {
                        try record(diarizer.process(samples: pending, sourceSampleRate: 16000))
                        pending.removeAll(keepingCapacity: true)
                        await Task.yield()
                    }
                } else if inlet.drained {
                    if !pending.isEmpty { try record(diarizer.process(samples: pending, sourceSampleRate: 16000)) }
                    try record(diarizer.finalizeSession())
                    state.processedThrough = end
                    state.phase = .completed
                    return
                } else { try await Task.sleep(for: .milliseconds(10)) }
            }
            state.phase = .completed
        } catch {
            state.phase = .failed
            state.error = (error as? MeetingError)?.description
                ?? "Не удалось обработать голоса локальной моделью. Транскрипция продолжается; подробности доступны в диагностике."
            Log.info("Diarization \(source.rawValue): \(error)")
        }
    }

    // Reading annotations never queues behind Core ML inference on this actor.
    nonisolated func annotate(_ events: [TranscriptEvent]) async -> [TranscriptEvent] {
        guard !events.isEmpty else { return events }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let end = events.map(\.endTime).max() ?? 0
        while snapshot.withLock({ !$0.finished && $0.state.phase != .failed && $0.state.processedThrough < end }) && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        // Empty spans explicitly mean unknown; never substitute an assumed person.
        let result = snapshot.withLock { $0 }
        return events.map { event in
            if result.state.processedThrough + 0.001 >= event.endTime {
                return result.window.annotate(event)
            }
            return TranscriptEvent(id: event.id, source: event.source, startTime: event.startTime, endTime: event.endTime, text: event.text, speakerSpans: [])
        }
    }
}
