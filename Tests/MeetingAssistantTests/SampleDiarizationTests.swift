import Foundation
import class FluidAudio.AudioConverter
import Synchronization
import Testing
@testable import MeetingAssistantCore

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
