import Foundation
import Synchronization
import CoreML
import Testing
@testable import MeetingAssistant
@testable import MeetingAssistantCore

@Test func deviceSelectionSupportsLocalizedNamesAndChangingIDs() throws {
    let devices = [
        AudioDevice(id: 900, name: "Микрофон MacBook Pro", inputChannels: 1, sampleRate: 48000),
        AudioDevice(id: 1200, name: "BlackHole 2ch", inputChannels: 2, sampleRate: 48000),
        AudioDevice(id: 901, name: "MacBook Pro Speakers", inputChannels: 0, sampleRate: 48000),
    ]
    #expect(try AudioDeviceManager.select(devices, name: nil, source: .you).id == 900)
    #expect(try AudioDeviceManager.select(devices, name: nil, source: .remote).id == 1200)
    #expect(throws: MeetingError.self) { try AudioDeviceManager.select(Array(devices.prefix(1)), name: nil, source: .remote) }
    #expect(throws: MeetingError.self) { try AudioDeviceManager.select(devices + [devices[0]], name: nil, source: .you) }
}

@Test func resamplingPreservesTimeAcrossFractionalPacketSizes() throws {
    for rate in [48000.0, 44100.0] {
        let converter = try AudioResampler(device: AudioDevice(id: 1, name: "test", inputChannels: 2, sampleRate: rate))
        var converted: [Float] = []
        let total = Int(rate * 3)
        var offset = 0
        while offset < total {
            let frames = min(512, total - offset)
            var samples: [Float] = []
            for index in 0..<frames {
                let value = Float(sin(2 * .pi * 440 * Double(offset + index) / rate)) * 0.5
                samples.append(value); samples.append(value)
            }
            let result = try converter.convert(CapturedAudio(samples: samples, hostTime: 0, sampleTime: Double(offset), frames: frames), time: 2 + Double(offset) / rate)
            #expect(abs(result.start - (2 + Double(converted.count) / 16000)) < 0.000001)
            converted.append(contentsOf: result.samples)
            offset += frames
        }
        #expect(abs(converted.count - 48000) <= 2)
        let rms = sqrt(converted.reduce(Double(0)) { $0 + Double($1 * $1) } / Double(converted.count))
        #expect(abs(rms - 0.35355) < 0.01)
    }
}

@Test func speechEndsOnceAfterSilenceAndSilenceAloneDoesNotEmit() throws {
    var chunker = SpeechChunker(thresholdDB: -42)
    #expect(try chunker.append([Float](repeating: 0, count: 16000), start: 0).isEmpty)
    #expect(try chunker.append([Float](repeating: 0.2, count: 16000), start: 1).isEmpty)
    let chunks = try chunker.append([Float](repeating: 0, count: 16000), start: 2)
    #expect(chunks.count == 1)
    #expect(chunks.first?.isFinal == true)
    #expect(abs((chunks.first?.start ?? 0) - 0.7) < 0.001)
    #expect(chunker.finish() == nil)
}

@Test func continuousSpeechUsesBoundedOverlappingWindowsAndFlushesTail() throws {
    var chunker = SpeechChunker(thresholdDB: -42)
    var chunks: [SpeechChunk] = []
    for second in 0..<35 {
        chunks += try chunker.append([Float](repeating: 0.1, count: 16000), start: Double(second))
    }
    #expect(chunks.count == 3)
    #expect(chunks.allSatisfy { !$0.isFinal && $0.samples.count == 192000 })
    #expect(chunks.map(\.start) == [0, 10, 20])
    let tail = chunker.finish()
    #expect(tail?.isFinal == true)
    #expect(tail?.start == 30)
    #expect(tail?.samples.count == 80000)
}

@Test func longPhrasesEndAtShortPausesWithoutSplittingShortUtterances() throws {
    var chunker = SpeechChunker(thresholdDB: -42)
    #expect(try chunker.append([Float](repeating: 0.1, count: 16000), start: 0).isEmpty)
    #expect(try chunker.append([Float](repeating: 0, count: 3200), start: 1).isEmpty)
    #expect(try chunker.append([Float](repeating: 0.1, count: 48000), start: 1.2).isEmpty)
    #expect(try chunker.append([Float](repeating: 0, count: 2880), start: 4.2).isEmpty)
    let chunks = try chunker.append([Float](repeating: 0, count: 320), start: 4.38)
    #expect(chunks.count == 1)
    #expect(chunks.first?.isFinal == true)
    #expect(chunks.first?.start == 0)
    #expect(abs((chunks.first?.end ?? 0) - 4.4) < 0.001)
    #expect(chunker.finish() == nil)
}

private final class EventCollector: Sendable {
    let events = Mutex<[TranscriptEvent]>([])
    func add(_ event: TranscriptEvent) { events.withLock { $0.append(event) } }
    var values: [TranscriptEvent] { events.withLock { $0 } }
}

@Test func timelineWaitsForSlowerStreamAndAdvancesOnSilence() async throws {
    let collector = EventCollector()
    let timeline = TranscriptTimeline(sources: [.you, .remote]) { collector.add($0) }
    let you = TranscriptEvent(source: .you, startTime: 3, endTime: 4, text: "Да.")
    let remote = TranscriptEvent(source: .remote, startTime: 1, endTime: 2, text: "Готово?")
    try await timeline.update(source: .you, events: [you], frontier: 5)
    #expect(collector.values.isEmpty)
    try await timeline.update(source: .remote, events: [remote], frontier: 2.5)
    #expect(collector.values == [remote])
    try await timeline.update(source: .remote, frontier: 6)
    #expect(collector.values == [remote, you])
    await #expect(throws: MeetingError.self) { try await timeline.update(source: .you, events: [you], frontier: 6) }
}

@Test func pipelineReportsBackpressureInsteadOfDroppingAudio() async throws {
    let timeline = TranscriptTimeline(sources: [.remote]) { _ in }
    let pipeline = StreamPipeline(source: .remote, thresholdDB: -42, timeline: timeline)
    await #expect(throws: MeetingError.self) {
        for second in 0..<80 {
            try await pipeline.ingest([Float](repeating: 0.1, count: 16000), start: Double(second))
        }
    }
}

@Test func optionValidationRejectsInvalidDurationsAndUnknownFlags() {
    for value in ["0", "-1", "nan", "inf", "oops"] {
        #expect(throws: MeetingError.self) { try Options(arguments: ["--duration", value]) }
    }
    #expect(throws: MeetingError.self) { try Options(arguments: ["--model-path"]) }
    #expect(throws: MeetingError.self) { try Options(arguments: ["--typo"]) }
}

@Test func missingAndCorruptTokenizersFailLocally() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    await #expect(throws: (any Error).self) { try await LocalWhisperTokenizer(folder: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("invalid json".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
    try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer_config.json"))
    try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
    await #expect(throws: (any Error).self) { try await LocalWhisperTokenizer(folder: folder) }
}

@Test func overlappingWindowsKeepBoundaryWordsWithoutRepeatingConfirmedContext() throws {
    var finalizer = TranscriptFinalizer(source: .remote)
    let first = SpeechChunk(samples: [Float](repeating: 0, count: 192000), start: 0, isFinal: false)
    let firstEvents = try finalizer.finalize([[
        RecognizedWord(text: " Пройдём", start: 9.2, end: 9.8),
        RecognizedWord(text: " по", start: 10.1, end: 10.9),
        RecognizedWord(text: " текущему", start: 10.9, end: 11.7),
    ]], chunk: first)
    #expect(firstEvents.map(\.text) == ["Пройдём по"])
    let next = SpeechChunk(samples: [Float](repeating: 0, count: 64000), start: 10, isFinal: true)
    let nextHypothesis = [[
        RecognizedWord(text: " по", start: 0.05, end: 0.5),
        RecognizedWord(text: " текущему", start: 0.5, end: 1.2),
        RecognizedWord(text: " состоянию.", start: 1.2, end: 2.3),
    ]]
    let nextEvents = try finalizer.finalize(nextHypothesis, chunk: next)
    #expect(nextEvents.map(\.text) == ["текущему состоянию."])
    #expect(nextEvents.first?.startTime == 10.9)
    #expect(try finalizer.finalize(nextHypothesis, chunk: next).isEmpty)
}

@Test func finalizationKeepsLegitimateRepetitionAndZeroDurationWords() throws {
    var finalizer = TranscriptFinalizer(source: .you)
    for start in [0.0, 5.0] {
        let chunk = SpeechChunk(samples: [Float](repeating: 0, count: 32000), start: start, isFinal: true)
        let events = try finalizer.finalize([[
            RecognizedWord(text: " Да,", start: 0.2, end: 0.5),
            RecognizedWord(text: " я", start: 0.5, end: 0.5),
            RecognizedWord(text: " согласен.", start: 0.5, end: 1.2),
        ]], chunk: chunk)
        #expect(events.map(\.text) == ["Да, я согласен."])
        #expect(events.first?.source == .you)
    }
}

@Test func initialTimestampLimitAppliesOnlyDuringInitialPrompt() throws {
    let filter = InitialTimestampFilter(timeTokenBegin: 50366, vocabularySize: 51866)
    // The resolved WhisperKit filters use Float16 logits on Apple Silicon.
    let logits = try MLMultiArray(shape: [1, 1, 51866], dataType: .float16)
    for index in 0..<logits.count { logits[index] = 0 }
    let initial = filter.filterLogits(logits, withTokens: [50258, 50263, 50359, 50366])
    #expect(initial[50366].floatValue == 0)
    #expect(initial[50416].floatValue == 0)
    #expect(initial[50417].floatValue == -.infinity)
    logits[50500] = 0
    let later = filter.filterLogits(logits, withTokens: [50258, 50263, 50359, 50366, 123])
    #expect(later[50500].floatValue == 0)
}
