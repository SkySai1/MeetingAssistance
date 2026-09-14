import Foundation
import class FluidAudio.AudioConverter
import Synchronization
import Testing
@testable import MeetingAssistantCore

private struct SavedDiarization: Decodable { let event: TranscriptEvent }

// Replay recorded model spans with the production intersection rule. This is
// model output, not a ground-truth speaker annotation.
private func annotatedSample(_ event: TranscriptEvent, spans: [SpeakerSpan], shift: Double = 0) -> TranscriptEvent {
    let minimum = min(0.15, max(0, event.endTime - event.startTime) / 2)
    let selected = spans.compactMap { span -> SpeakerSpan? in
        let start = max(event.startTime, span.startTime - shift), end = min(event.endTime, span.endTime - shift)
        guard end > start, end - start >= minimum else { return nil }
        return SpeakerSpan(speakerID: span.speakerID, startTime: start, endTime: end)
    }
    return TranscriptEvent(id: event.id, source: event.source, startTime: event.startTime, endTime: event.endTime,
        text: event.text, speakerSpans: selected)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_TEST_GROUPING_SAMPLES"] == "1"), .timeLimit(.minutes(1)))
func groupingRecordedMeetingSamplesPreservesAllEvents() throws {
    let directory = URL(fileURLWithPath: ".build/validation/samples", isDirectory: true)
    var report: [String: [Int]] = [:]
    for (name, reference, shift, expected) in [("simple-0", "simple-0", 0.0, [5, 5, 5]),
        ("simple-90", "simple-90", 0.0, [1, 1, 1]), ("hard-0", "hard-0", 0.0, [3, 2, 2]),
        ("hard-90", "hard-90", 0.0, [1, 1, 1]), ("hard-110", "hard-90", 20.0, [5, 5, 5])] {
        let original = try JSONDecoder().decode([TranscriptEvent].self, from: Data(contentsOf: directory.appendingPathComponent(name + "-transcript.json")))
        let saved = try JSONDecoder().decode(SavedDiarization.self, from: Data(contentsOf: directory.appendingPathComponent(reference + "-sortformer-v2.1.json")))
        let annotated = original.map { annotatedSample($0, spans: saved.event.speakerSpans ?? [], shift: shift) }
        var counts: [Int] = []
        for pause in [0.6, 1.2, 2.0] {
            var config = TranscriptDisplayConfiguration(); config.maximumPause = pause
            var grouping = TranscriptGrouping(configuration: config)
            for event in annotated { grouping.append(event) }
            #expect(grouping.groups.flatMap(\.events) == annotated)
            #expect(grouping.groups.filter { $0.events.count > 1 }.allSatisfy { Set($0.events.flatMap { $0.speakerIDs ?? [] }).count == 1 })
            counts.append(grouping.groups.count)
        }
        #expect(counts == expected, "\(name): \(counts)")
        report[name] = [original.count] + counts
        print("\(name): \(original.count) events → \(counts) cards at 0.6 / 1.2 / 2.0 seconds")
    }
    let output = URL(fileURLWithPath: ".build/validation/utterance-grouping", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try JSONEncoder().encode(report).write(to: output.appendingPathComponent("implemented-groups.json"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_TEST_GROUPING_AUDIO"] == "1"), .timeLimit(.minutes(1)))
func shortGroupedDualSampleWindowsIncludeFinalTail() async throws {
    let began = ContinuousClock.now
    let directory = URL(fileURLWithPath: ".build/validation/samples", isDirectory: true)
    let audio = Array(try AudioConverter(sampleRate: 16000).resampleAudioFile(directory.appendingPathComponent("simple-90.wav")).prefix(20 * 16000))
    let saved = try JSONDecoder().decode(SavedDiarization.self, from: Data(contentsOf: directory.appendingPathComponent("simple-90-sortformer-v2.1.json")))
    let results = Mutex<[TranscriptEvent]>([])
    let timeline = TranscriptTimeline(sources: [.you, .remote]) { event in results.withLock { $0.append(event) } }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for source in AudioSource.allCases {
            group.addTask {
                let transcriber = try await WhisperTranscriber(source: source, paths: ModelPaths())
                let pipeline = StreamPipeline(source: source, thresholdDB: -42, timeline: timeline)
                for offset in stride(from: 0, to: audio.count, by: 8000) {
                    try await pipeline.ingest(Array(audio[offset..<min(offset + 8000, audio.count)]), start: Double(offset) / 16000)
                }
                // Exactly the production stop path: enqueue and drain the tail
                // using the same transcriber/finalizer as the preceding window.
                try await pipeline.finish()
                while let chunk = await pipeline.next() {
                    try Task.checkCancellation()
                    var events = try await transcriber.transcribe(chunk)
                    if source == .remote { events = events.map { annotatedSample($0, spans: saved.event.speakerSpans ?? []) } }
                    try await pipeline.complete(events, lag: 0)
                }
                let drained = await pipeline.isDrained
                let windows = await pipeline.decodedChunks
                #expect(drained && windows >= 2)
            }
        }
        group.addTask { try await Task.sleep(for: .seconds(45)); throw MeetingError("Grouped dual-ASR check exceeded 45 seconds") }
        defer { group.cancelAll() }
        // The remaining task is the watchdog and must be cancelled after both sources.
        for _ in 0..<2 { try await group.next() }
    }
    let events = results.withLock { $0 }
    #expect(events.map(\.startTime) == events.map(\.startTime).sorted())
    var combined = TranscriptGrouping()
    for event in events { combined.append(event) }
    #expect(combined.groups.flatMap(\.events) == events)
    for source in AudioSource.allCases {
        let stream = events.filter { $0.source == source }
        #expect(stream.contains { $0.endTime > 18 })
        #expect(stream.contains { $0.endTime <= 11.001 })
        var grouping = TranscriptGrouping()
        for event in stream { grouping.append(event) }
        #expect(grouping.groups.count < stream.count)
        print("\(source.rawValue): \(stream.count) events → \(grouping.groups.count) cards; tail \(stream.last?.endTime ?? 0)")
    }
    let output = URL(fileURLWithPath: ".build/validation/utterance-grouping", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(events).write(to: output.appendingPathComponent("dual-window-events.json"))
    print("Grouped dual sample: 20 seconds/source, \(began.duration(to: .now)) wall time")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_TEST_SAMPLE"] != nil), .timeLimit(.minutes(1)))
func shortSampleTranscript() async throws {
    let name = try #require(ProcessInfo.processInfo.environment["MEETING_TEST_SAMPLE"])
    let directory = URL(fileURLWithPath: ".build/validation/samples", isDirectory: true)
    let audio = try AudioConverter(sampleRate: 16000).resampleAudioFile(directory.appendingPathComponent(name + ".wav"))
    let transcriber = try await WhisperTranscriber(source: .remote, paths: ModelPaths())
    let events = try await transcriber.transcribe(SpeechChunk(samples: Array(audio.prefix(12 * 16000)), start: 0, isFinal: true))
    #expect(!events.isEmpty)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(events).write(to: directory.appendingPathComponent(name + "-transcript.json"))
    print(events.map { "[\($0.startTime)–\($0.endTime)] \($0.text)" }.joined(separator: "\n"))
}

/// Offline excerpts only: no microphone, playback, model downloads, or LLM calls.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_TEST_SAMPLE"] != nil), .timeLimit(.minutes(1)))
func shortMeetingSampleDiarization() async throws {
    let env = ProcessInfo.processInfo.environment
    let name = try #require(env["MEETING_TEST_SAMPLE"])
    let selection = try #require(DiarizationModel(rawValue: env["MEETING_TEST_DIARIZER"] ?? "ls-eend-dihard3"))
    let directory = URL(fileURLWithPath: ".build/validation/samples", isDirectory: true)
    let audio = try AudioConverter(sampleRate: 16000).resampleAudioFile(directory.appendingPathComponent(name + ".wav"))
    guard audio.count <= 45 * 16000 else { throw MeetingError("Sample excerpts must be at most 45 seconds") }
    let began = ContinuousClock.now
    let statuses = Mutex<[DiarizationState]>([])
    let worker = SourceDiarizer(source: .remote, model: selection) { state in statuses.withLock { $0.append(state) } }
    let run = Task { await worker.run() }
    defer { run.cancel(); worker.inlet.close() }
    // Cold model loading must not overflow the production 30-second audio inlet.
    while statuses.withLock({ $0.last?.phase != .ready }) {
        if let state = statuses.withLock({ $0.last }), state.phase == .failed { throw MeetingError(state.error ?? "Model failed") }
        guard began.duration(to: .now) < .seconds(25) else { throw MeetingError("Model load exceeded short test budget") }
        try await Task.sleep(for: .milliseconds(20))
    }
    for offset in stride(from: 0, to: audio.count, by: 8000) {
        while Double(offset) / 16000 - statuses.withLock({ $0.last?.processedThrough ?? 0 }) > 8 {
            guard began.duration(to: .now) < .seconds(50) else { throw MeetingError("Inference exceeded short test budget") }
            if statuses.withLock({ $0.last?.phase }) == .failed { throw MeetingError("Diarization worker failed") }
            try await Task.sleep(for: .milliseconds(10))
        }
        worker.inlet.append(Array(audio[offset..<min(offset + 8000, audio.count)]), start: Double(offset) / 16000)
        await Task.yield()
    }
    worker.inlet.close()
    await run.value
    let state = try #require(statuses.withLock { $0.last })
    #expect(state.phase == .completed, "\(state.error ?? "")")
    #expect(abs(state.processedThrough - Double(audio.count) / 16000) < 0.01)
    let event = TranscriptEvent(source: .remote, startTime: 0, endTime: state.processedThrough, text: "Local sample: \(name)")
    let annotated = try #require(await worker.annotate([event]).first)
    #expect(!(annotated.speakerIDs ?? []).isEmpty)
    if selection == .sortformer { #expect((state.voiceMemoryFrames ?? 0) > 0) }
    struct Report: Encodable {
        let sample: String; let model: String; let wallSeconds: Double
        let event: TranscriptEvent; let participants: [MeetingParticipant]; let voiceMemoryFrames: Int?
    }
    let elapsed = began.duration(to: .now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let report = Report(sample: name, model: selection.rawValue, wallSeconds: seconds, event: annotated,
        participants: state.participants, voiceMemoryFrames: state.voiceMemoryFrames)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: directory.appendingPathComponent(name + "-" + selection.rawValue + ".json"))
    #expect(seconds < 60)
    print("Sample \(name), \(selection.rawValue): \(state.detectedSpeakers) voices, \(seconds)s wall, voice memory \(state.voiceMemoryFrames ?? 0) frames")
}
