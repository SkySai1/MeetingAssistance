import Foundation
import Testing
@testable import MeetingAssistantCore

@Test(arguments: [160, 171, 320, 512])
func quietMicrophoneWithShortNoiseBurstsKeepsFrontierMonotonic(packetSize: Int) async throws {
    let timeline = TranscriptTimeline(sources: [.you]) { _ in
        Issue.record("Sub-200 ms noise must not create transcript events")
    }
    let pipeline = StreamPipeline(source: .you, thresholdDB: -42, timeline: timeline)
    // Eight minutes in varying packet sizes with isolated clicks, without ASR.
    // A nonzero origin matches the first AUHAL packet's meeting-relative time.
    let origin = 0.046451416666669
    for offset in stride(from: 0, to: 480 * 16000, by: packetSize) {
        let value: Float = (offset / 320) % 137 == 0 ? 0.1 : 0
        let count = min(packetSize, 480 * 16000 - offset)
        try await pipeline.ingest([Float](repeating: value, count: count), start: origin + Double(offset) / 16000)
        #expect(await pipeline.next() == nil)
    }
    try await pipeline.finish()
    #expect(await pipeline.isDrained)
}

@Test func sampleClockStillRejectsRealDiscontinuitiesAndTimelineRollback() async throws {
    var chunker = SpeechChunker(thresholdDB: -42)
    _ = try chunker.append([Float](repeating: 0, count: 320), start: 0.1)
    #expect(throws: MeetingError.self) { try chunker.append([0], start: 0.14) }
    #expect(throws: MeetingError.self) { try chunker.append([0], start: 0.11) }
    #expect(throws: MeetingError.self) { try chunker.append([0], start: .nan) }
    #expect(chunker.endTime == 0.1 + 320.0 / 16000)
    _ = try chunker.append([0], start: 0.12)

    let timeline = TranscriptTimeline(sources: [.you]) { _ in }
    try await timeline.update(source: .you, frontier: 10)
    await #expect(throws: MeetingError.self) { try await timeline.update(source: .you, frontier: 9.99) }
    try await timeline.update(source: .you, frontier: 10.01)
}
