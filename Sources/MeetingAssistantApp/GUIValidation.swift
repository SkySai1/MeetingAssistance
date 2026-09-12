import AppKit
import Foundation
import MeetingAssistantCore

/// Explicit development-only invocation: --validate-gui OUTPUT_DIRECTORY.
/// Drives the same view model as the buttons, using real devices and local TTS.
/// Normal app launches never invoke capture or playback automatically.
@MainActor
enum GUIValidation {
    private static var started = false

    static func runIfRequested(_ model: MeetingViewModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !started, let flag = arguments.firstIndex(of: "--validate-gui"), arguments.indices.contains(flag + 1) else { return }
        started = true
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        var report: [String: Any] = [:]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let defaults = try AudioDeviceManager.defaultDeviceIDs()
            try require(model.canStart, "Audio sources and model must be ready")

            model.start(audioTest: true)
            try await waitUntil { model.phase == .running || !model.isBusy }
            try require(model.phase == .running, model.errorDetails)
            try await waitUntil { model.metrics.count == 2 || !model.isBusy }
            try require(model.metrics.count == 2, "Both live audio meters must update")
            model.stop()
            await model.stopAndWait()
            try require(model.phase == .stopped && !model.isBusy && model.transcript.isEmpty, "Audio test must stop without transcript")
            report["audio_test"] = "passed"

            model.start()
            model.stop() // Stop during the permission/startup task, before capture.
            await model.stopAndWait()
            try require(model.phase == .stopped && model.transcript.isEmpty, "Stop during startup must be safe")
            report["stop_during_startup"] = "passed"

            model.start()
            model.start() // Must not create a second concurrent meeting.
            try await waitUntil { model.phase == .running || !model.isBusy }
            try require(model.phase == .running, model.errorDetails)
            let outputs = try AudioDeviceManager.devices().filter { $0.inputChannels == 0 && $0.name.contains("MacBook") }
            guard let speaker = outputs.first else { throw MeetingError("Physical MacBook output is required for this acoustic test") }
            let remote = try say("Коллеги, проверяем новое окно встречи. Релиз запланирован на пятницу. Нужно проверить документ и согласовать время следующего разговора.", device: model.deviceName(.remote))
            let you = try say("Проверка локального микрофона. Я подготовлю документ к четвергу. Уточните время следующей встречи.", device: speaker.name)
            defer {
                if remote.isRunning { remote.terminate() }
                if you.isRunning { you.terminate() }
            }
            try await waitUntil { !remote.isRunning && !you.isRunning }
            try require(remote.terminationStatus == 0 && you.terminationStatus == 0, "Local speech playback failed")
            let beforeStop = model.transcript.count
            await model.stopAndWait() // Last short phrase must be flushed here.
            try require(model.phase == .stopped && model.errorMessage == nil, model.errorDetails)
            let events = model.transcript
            for source in AudioSource.allCases {
                try require(events.contains { $0.source == source }, "No finalized events from \(source.rawValue)")
            }
            try require(events.map(\.startTime) == events.map(\.startTime).sorted(), "Transcript is not chronological")
            let identities = events.map { "\($0.source.rawValue)|\($0.startTime)|\($0.endTime)|\($0.text)" }
            try require(Set(identities).count == events.count, "Duplicate finalized events")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(events).write(to: directory.appendingPathComponent("transcript.json"))
            try model.diagnostics.joined(separator: "\n").write(to: directory.appendingPathComponent("diagnostics.log"), atomically: true, encoding: .utf8)
            report["events_before_stop"] = beforeStop
            report["events_after_drain"] = events.count
            report["sources"] = Array(Set(events.map { $0.source.rawValue })).sorted()
            report["chronological"] = true
            report["elapsed_seconds"] = model.elapsed
            let stoppedTime = model.elapsed
            try await Task.sleep(for: .milliseconds(400))
            try require(model.elapsed == stoppedTime && model.transcript == events, "Stopped meeting continued changing")

            model.start()
            try await waitUntil { model.phase == .running || !model.isBusy }
            try require(model.phase == .running && model.transcript.isEmpty, "New meeting did not reset its transcript")
            await model.stopAndWait()
            try require(model.phase == .stopped && !model.isBusy, "Restarted meeting failed to stop")
            let finalDefaults = try AudioDeviceManager.defaultDeviceIDs()
            try require(defaults.input == finalDefaults.input && defaults.output == finalDefaults.output, "Global audio devices changed")
            report["restart"] = "passed"
            report["global_devices_unchanged"] = true
            report["result"] = "passed"
        } catch {
            await model.stopAndWait()
            report["result"] = "failed"
            report["error"] = String(describing: error)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("report.json"))
        } catch { FileHandle.standardError.write(Data("GUI validation report: \(error)\n".utf8)) }
        NSApp.terminate(nil)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw MeetingError(message) }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !condition() {
            if ContinuousClock.now >= deadline { throw MeetingError("GUI validation timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func say(_ text: String, device: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["--audio-device=\(device)", "-v", "Milena", "-r", "170", text]
        try process.run()
        return process
    }
}
