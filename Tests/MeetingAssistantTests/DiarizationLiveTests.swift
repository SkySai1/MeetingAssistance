import Foundation
import class FluidAudio.AudioConverter
import Synchronization
import Testing
@testable import MeetingAssistantCore

/// Opt-in local Core ML smoke test. Fixtures are synthesized to files, never played.
/// Audio and wall-clock budgets are both below one minute.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_TEST_DIARIZATION"] == "1"), .timeLimit(.minutes(1)))
func shortFluidAudioSeparatesSourcesAndFlushesFinalTail() async throws {
    let selection = DiarizationModel(rawValue: ProcessInfo.processInfo.environment["MEETING_TEST_DIARIZER"] ?? "ls-eend-dihard3") ?? .lsEENDDIHARD3
    let directory = URL(fileURLWithPath: ".build/validation/diarization", isDirectory: true)
    let converter = AudioConverter(sampleRate: 16000)
    let first = try converter.resampleAudioFile(directory.appendingPathComponent("first.aiff"))
    let second = try converter.resampleAudioFile(directory.appendingPathComponent("second.aiff"))
    var audio = Array<Float>(repeating: 0, count: 16000)
    var ranges: [(Double, Double)] = []
    for (index, clip) in [first, second, first, second].enumerated() {
        let start = Double(audio.count) / 16000
        audio += clip
        ranges.append((start, Double(audio.count) / 16000))
        audio += Array(repeating: 0, count: index == 1 ? 18 * 16000 : 8000)
    }
    guard audio.count < 55 * 16000 else { throw MeetingError("Use fixtures totalling less than 55 seconds") }
    let statuses = Mutex<[AudioSource: DiarizationState]>([:])
    let remote = SourceDiarizer(source: .remote, model: selection) { state in statuses.withLock { $0[state.source] = state } }
    let microphone = SourceDiarizer(source: .you, model: selection) { state in statuses.withLock { $0[state.source] = state } }
    let began = ContinuousClock.now
    let remoteRun = Task { await remote.run() }, microphoneRun = Task { await microphone.run() }
    defer { remoteRun.cancel(); microphoneRun.cancel(); remote.inlet.close(); microphone.inlet.close() }
    while statuses.withLock({ $0.count != 2 || !$0.values.allSatisfy { $0.phase == .ready } }) {
        if statuses.withLock({ $0.values.contains { $0.phase == .failed } }) { throw MeetingError("Model load failed") }
        guard began.duration(to: .now) < .seconds(20) else { throw MeetingError("Model load exceeded smoke budget") }
        try await Task.sleep(for: .milliseconds(20))
    }
    for offset in stride(from: 0, to: audio.count, by: 8000) {
        guard began.duration(to: .now) < .seconds(45) else { throw MeetingError("Diarization smoke exceeded 45-second feed budget") }
        let packet = Array(audio[offset..<min(offset + 8000, audio.count)])
        remote.inlet.append(packet, start: 12.5 + Double(offset) / 16000)
        microphone.inlet.append(packet, start: 35 + Double(offset) / 16000)
        try await Task.sleep(for: .milliseconds(100))
    }
    remote.inlet.close(); microphone.inlet.close()
    await remoteRun.value; await microphoneRun.value
    var results: [TranscriptEvent] = []
    for (source, worker, origin) in [(AudioSource.remote, remote, 12.5), (.you, microphone, 35.0)] {
        let events = ranges.enumerated().map { index, range in
            TranscriptEvent(id: "\(source.rawValue)_\(index)", source: source, startTime: origin + range.0, endTime: origin + range.1, text: "Fixture \(index)")
        }
        let annotated = await worker.annotate(events)
        results += annotated
        let last = try #require(statuses.withLock { $0[source] })
        #expect(last.phase == .completed, "\(last.error ?? "")")
        #expect(abs(last.processedThrough - origin - Double(audio.count) / 16000) < 0.01)
        #expect(last.detectedSpeakers >= 2)
        #expect(last.participants.count >= 2)
        if selection == .sortformer { #expect((last.voiceMemoryFrames ?? 0) > 0) }
        func dominant(_ event: TranscriptEvent) -> String? {
            var durations: [String: Double] = [:]
            for span in event.speakerSpans ?? [] { durations[span.speakerID, default: 0] += span.endTime - span.startTime }
            return durations.max { $0.value < $1.value }?.key
        }
        let labels = annotated.compactMap(dominant)
        #expect(labels.count == 4)
        if labels.count == 4 {
            #expect(labels[0] != labels[1])
            #expect(labels[0] == labels[2] && labels[1] == labels[3])
            #expect(labels.allSatisfy { $0.hasPrefix(source.rawValue + "_speaker_") })
        }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: directory.appendingPathComponent("events.json"))
    print("FluidAudio smoke: \(Double(audio.count) / 16000)s audio/source, \(began.duration(to: .now)) wall time, two independent streams")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_TEST_DIARIZATION"] == "1"), .timeLimit(.minutes(1)))
func shortDualWhisperAndFluidAudioDrainBothSources() async throws {
    let began = ContinuousClock.now
    let directory = URL(fileURLWithPath: ".build/validation/diarization", isDirectory: true)
    let converter = AudioConverter(sampleRate: 16000)
    let first = try converter.resampleAudioFile(directory.appendingPathComponent("first.aiff"))
    let second = try converter.resampleAudioFile(directory.appendingPathComponent("second.aiff"))
    let audio = Array<Float>(repeating: 0, count: 8000) + first + Array(repeating: 0, count: 8000) + second + Array(repeating: 0, count: 8000) + first
    guard audio.count < 30 * 16000 else { throw MeetingError("Use fixtures totalling less than 30 seconds") }
    let results = Mutex<[TranscriptEvent]>([])
    let states = Mutex<[AudioSource: DiarizationState]>([:])
    let timeline = TranscriptTimeline(sources: [.you, .remote]) { event in results.withLock { $0.append(event) } }
    let paths = try ModelPaths()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for source in AudioSource.allCases {
            let transcriber = try await WhisperTranscriber(source: source, paths: paths)
            let pipeline = StreamPipeline(source: source, thresholdDB: -42, timeline: timeline)
            let diarizer = SourceDiarizer(source: source) { state in states.withLock { $0[state.source] = state } }
            group.addTask { await diarizer.run() }
            group.addTask {
                while !Task.isCancelled {
                    if let chunk = await pipeline.next() {
                        let events = try await transcriber.transcribe(chunk)
                        let annotated = await diarizer.annotate(events)
                        try await pipeline.complete(annotated, lag: 0)
                    } else if await pipeline.isDrained { return }
                    else { try await Task.sleep(for: .milliseconds(20)) }
                }
            }
            group.addTask {
                defer { diarizer.inlet.close() }
                let origin = source == .you ? 2.0 : 0.0
                for offset in stride(from: 0, to: audio.count, by: 8000) {
                    try Task.checkCancellation()
                    let packet = Array(audio[offset..<min(offset + 8000, audio.count)])
                    let start = origin + Double(offset) / 16000
                    diarizer.inlet.append(packet, start: start)
                    try await pipeline.ingest(packet, start: start)
                    try await Task.sleep(for: .milliseconds(100))
                }
                try await pipeline.finish()
            }
        }
        for try await _ in group { }
    }
    let events = results.withLock { $0 }
    #expect(events.map(\.startTime) == events.map(\.startTime).sorted())
    #expect(Set(events.map(\.id)).count == events.count)
    for source in AudioSource.allCases {
        let phrases = events.filter { $0.source == source }
        #expect(!phrases.isEmpty)
        #expect(phrases.allSatisfy { !($0.speakerSpans ?? []).isEmpty })
        #expect(Set(phrases.flatMap { $0.speakerIDs ?? [] }).count >= 2)
        #expect(phrases.last?.text.lowercased().contains("копи") == true)
        #expect(states.withLock { $0[source]?.phase } == .completed)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(events).write(to: directory.appendingPathComponent("dual-asr-events.json"))
    print("Dual Whisper + FluidAudio: \(Double(audio.count) / 16000)s audio/source, \(events.count) finalized phrases, \(began.duration(to: .now)) wall time")
}
