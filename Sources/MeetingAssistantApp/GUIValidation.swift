import AppKit
import Foundation
import MeetingAssistantCore
import SwiftUI

/// Explicit development-only invocation: --validate-gui OUTPUT_DIRECTORY.
/// Drives the same view model as the buttons, using real devices and local TTS.
/// Normal app launches never invoke capture or playback automatically.
@MainActor
enum GUIValidation {
    private static var started = false

    static func runIfRequested(_ model: MeetingViewModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--validate-layout"), arguments.indices.contains(flag + 1), !started {
            started = true
            await validateLayout(model, directory: URL(fileURLWithPath: arguments[flag + 1]))
            return
        }
        guard !started, let flag = arguments.firstIndex(of: "--validate-gui"), arguments.indices.contains(flag + 1) else { return }
        started = true
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        let originalAI = model.aiSettings.configuration
        let originalEnabled = model.aiSettings.enabled
        defer { model.aiSettings.configuration = originalAI; model.aiSettings.enabled = originalEnabled }
        let aiModel = arguments.firstIndex(of: "--validate-ollama-model").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        model.aiSettings.enabled = aiModel != nil
        if let aiModel { model.aiSettings.configuration.model = aiModel }
        if let server = arguments.firstIndex(of: "--validate-ollama-server"), arguments.indices.contains(server + 1) {
            model.aiSettings.configuration.server = arguments[server + 1]
        }
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
            if aiModel != nil {
                try encoder.encode(model.aiState).write(to: directory.appendingPathComponent("ai-state.json"))
                try model.aiState.protocolText.write(to: directory.appendingPathComponent("protocol.md"), atomically: true, encoding: .utf8)
                try require(model.aiState.protocolComplete && model.aiState.processedEvents == events.count, "AI did not include every finalized event")
                try require(model.aiState.releaseStatus == .unloaded, model.aiState.error ?? "Model unloading was not confirmed")
                let pasteboard = NSPasteboard.general
                let saved = (pasteboard.pasteboardItems ?? []).map { item in
                    item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
                }
                defer {
                    pasteboard.clearContents()
                    pasteboard.writeObjects(saved.map { values in
                        let item = NSPasteboardItem()
                        for (type, data) in values { item.setData(data, forType: type) }
                        return item
                    })
                }
                model.copyProtocol()
                try require(pasteboard.string(forType: .string) == model.aiState.protocolText, "Copy did not deliver the complete protocol")
                report["ai_protocol_and_copy"] = "passed"
                report["model_unloaded"] = true
            }
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

    /// Native view snapshots and tab cycling only. Never captures/plays audio.
    private static func validateLayout(_ model: MeetingViewModel, directory: URL) async {
        var report: [String: Any] = [:]
        let originalDisplay = model.transcriptDisplayConfiguration
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(500))
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView else {
                throw MeetingError("No visible native window")
            }
            for ai in [false, true] {
                model.transcriptDisplayConfiguration = TranscriptDisplayConfiguration()
                model.applyTranscriptDisplaySettings()
                model.loadLayoutFixture(aiEnabled: ai)
                try require(model.transcript.count == 3 && model.transcriptGroups.count == 2, "Continuation did not join its card")
                let continuation = model.transcript[1]
                model.focusedEventID = continuation.id
                try require(model.focusedTranscriptGroupID == model.transcript[0].id, "Source link did not resolve to its group")
                model.transcriptDisplayConfiguration.enabled = false
                model.applyTranscriptDisplaySettings()
                try require(model.transcriptGroups.count == 3 && model.focusedTranscriptGroupID == continuation.id, "Regrouping lost its source link")
                model.transcriptDisplayConfiguration.enabled = true
                model.applyTranscriptDisplaySettings()
                try require(model.transcriptGroups.count == 2 && model.transcriptCopyText.contains(continuation.text), "Regrouping or copy lost the continuation")
                report["transcript_grouping_and_source_links"] = "passed"
                for size in [NSSize(width: 1280, height: 800), NSSize(width: 980, height: 620)] {
                    window.setContentSize(size)
                    for screen in [Screen.home, .audio, .meeting, .ai, .meeting] {
                        model.selectedScreen = screen
                        try await Task.sleep(for: .milliseconds(180))
                        content.layoutSubtreeIfNeeded()
                        let label = "\(Int(size.width))-\(ai ? "ai" : "no-ai")-\(screen)"
                        let frames = model.layoutFrames
                        if screen == .meeting, let root = frames["root"] {
                            try require(root.minX >= -1 && root.maxX <= content.bounds.width + 1,
                                "Root exceeds native window at \(label): \(root), window \(content.bounds)")
                            for key in ["meeting", "transcript", "meeting-controls", "meeting-footer"] + (ai ? ["context"] : []) {
                                guard let frame = frames[key] else { throw MeetingError("Missing layout frame: \(key)") }
                                let visible = root.intersection(frame)
                                try require(visible.width >= frame.width - 2 && visible.height >= frame.height - 2 && frame.height > 30,
                                    "Clipped \(key) at \(label): \(frame), root \(root)")
                            }
                            guard let fragment = frames["transcript-focused-fragment"], let pane = frames["transcript"] else {
                                throw MeetingError("Focused source fragment is not displayed")
                            }
                            try require(fragment.intersection(pane).height >= min(fragment.height, pane.height) - 2,
                                "Focused source fragment is outside the transcript pane at \(label)")
                        }
                        var splitFrames: [[String: Double]] = []
                        func inspect(_ view: NSView) throws {
                            if let split = view as? NSSplitView, !split.isHidden, split.bounds.height > 0 {
                                for pane in split.arrangedSubviews where !pane.isHidden && !split.isSubviewCollapsed(pane) {
                                    try require(pane.frame.width > 0 && pane.frame.height > 0, "Collapsed visible pane: \(label)")
                                    splitFrames.append(["width": pane.frame.width, "height": pane.frame.height])
                                }
                            }
                            for child in view.subviews { try inspect(child) }
                        }
                        try inspect(content)
                        // SwiftUI/composited layers are absent from NSView.cacheDisplay.
                        // Capture only our own window, never the desktop or other apps.
                        if CGPreflightScreenCaptureAccess() {
                            let capture = Process()
                            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory.appendingPathComponent(label + ".png").path]
                            try capture.run()
                            while capture.isRunning { try await Task.sleep(for: .milliseconds(20)) }
                            if capture.terminationStatus != 0 { report["screenshots"] = "unavailable" }
                        } else { report["screenshots"] = "unavailable: macOS screen-capture permission" }
                        report[label] = splitFrames
                        report[label + "-frames"] = frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
                    }
                }
            }
            report["result"] = "passed"
        } catch { report["result"] = "failed"; report["error"] = String(describing: error) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
        model.transcriptDisplayConfiguration = originalDisplay
        model.applyTranscriptDisplaySettings()
        model.finishLayoutFixture()
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

struct LayoutFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

extension View {
    @ViewBuilder func layoutProbe(_ name: String) -> some View {
        if ProcessInfo.processInfo.arguments.contains("--validate-layout") {
            background(GeometryReader { geometry in Color.clear.preference(key: LayoutFramesKey.self, value: [name: geometry.frame(in: .global)]) })
        } else { self }
    }
}
