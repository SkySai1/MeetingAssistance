import Foundation
import Testing
@testable import MeetingAssistantCore
@testable import MeetingAssistantApp

private func phrase(_ id: String, _ start: Double, _ end: Double, source: AudioSource = .remote,
                    speakers: [String]? = ["REMOTE_speaker_1"], text: String = "Да, да.") -> TranscriptEvent {
    TranscriptEvent(id: id, source: source, startTime: start, endTime: end, text: text,
        speakerSpans: speakers.map { $0.map { SpeakerSpan(speakerID: $0, startTime: start, endTime: end) } })
}

@Test func groupingPublishesImmediatelyPreservesWordsAndStableIdentity() {
    var grouping = TranscriptGrouping()
    let first = phrase("first", 0, 4, text: "Пройдём по")
    let tail = phrase("tail", 4.4, 9, text: "текущему состоянию.")
    let addedFirst = grouping.append(first)
    #expect(addedFirst && grouping.groups.first?.text == first.text)
    // Event time controls joining, irrespective of how much later ASR delivers it.
    let addedTail = grouping.append(tail)
    #expect(addedTail)
    #expect(grouping.groups.count == 1 && grouping.groups[0].id == first.id)
    #expect(grouping.groups[0].text == "Пройдём по текущему состоянию.")
    #expect(grouping.groups[0].events == [first, tail] && grouping.groupID(for: tail.id) == first.id)
    let duplicate = grouping.append(tail)
    #expect(!duplicate)
    grouping.append(phrase("repeat1", 9, 10)); grouping.append(phrase("repeat2", 10, 11))
    #expect(grouping.groups[0].text.hasSuffix("Да, да. Да, да."))
    #expect(grouping.groups[0].events.count == 4)
}

@Test func groupingRespectsPauseDurationAndIndivisibleLongEvent() {
    var config = TranscriptDisplayConfiguration(); config.maximumDuration = 5
    var grouping = TranscriptGrouping(configuration: config)
    for event in [phrase("a", 0, 2), phrase("b", 3.2, 5), phrase("c", 5, 6),
                  phrase("d", 7.21, 8), phrase("long", 8, 20), phrase("after", 20, 21)] { grouping.append(event) }
    #expect(grouping.groups.map { $0.events.map(\.id) } == [["a", "b"], ["c"], ["d"], ["long"], ["after"]])
    #expect(grouping.groups[3].endTime == 20)
    var overlap = TranscriptGrouping()
    overlap.append(phrase("a", 0, 4)); overlap.append(phrase("b", 3.9, 5))
    #expect(overlap.groups.count == 2)
    config.enabled = false
    var disabled = TranscriptGrouping(configuration: config)
    disabled.append(phrase("a", 0, 1)); disabled.append(phrase("b", 1, 2))
    #expect(disabled.groups.count == 2)
}

@Test func groupingNeverBridgesSpeakersUnknownVoicesOrSources() {
    var grouping = TranscriptGrouping()
    let events = [phrase("a", 0, 1), phrase("b", 1, 2, speakers: ["REMOTE_speaker_2"]),
        phrase("a2", 2, 3), phrase("mixed", 3, 4, speakers: ["REMOTE_speaker_1", "REMOTE_speaker_2"]),
        phrase("a3", 4, 5), phrase("unknown", 5, 6, speakers: []), phrase("unknown2", 6, 7, speakers: []),
        phrase("remote", 7, 8, speakers: nil), phrase("remote2", 8, 9, speakers: nil),
        phrase("you1", 9, 10, source: .you, speakers: nil), phrase("you2", 10.1, 11, source: .you, speakers: nil),
        phrase("youDiarized", 11, 12, source: .you, speakers: ["REMOTE_speaker_1"]),
        phrase("remote3", 12, 13)]
    for event in events { grouping.append(event) }
    #expect(grouping.groups.count == events.count - 1)
    #expect(grouping.groups[9].events.map(\.id) == ["you1", "you2"])
    #expect(grouping.groups.flatMap(\.events) == events)
    var microphone = TranscriptGrouping()
    for event in [phrase("one", 0, 1, source: .you, speakers: ["YOU_speaker_1"]),
                  phrase("two", 1, 2, source: .you, speakers: ["YOU_speaker_1"]),
                  phrase("other", 2, 3, source: .you, speakers: ["YOU_speaker_2"])] { microphone.append(event) }
    #expect(microphone.groups.count == 2)
}

@Test func groupingTenThousandEventsRemainsBoundedAndPreservesEveryReference() {
    let events = (0..<10_000).map { phrase(String($0), Double($0), Double($0 + 1)) }
    let began = ContinuousClock.now
    for duration in [30.0, 120.0] {
        var config = TranscriptDisplayConfiguration(); config.maximumDuration = duration
        var grouping = TranscriptGrouping(configuration: config)
        for event in events { grouping.append(event) }
        #expect(grouping.groups.count == Int(ceil(10000 / duration)))
        #expect(grouping.groups.flatMap(\.events) == events)
        #expect(events.allSatisfy { grouping.groupID(for: $0.id) != nil })
    }
    #expect(ContinuousClock.now - began < .seconds(2))
}

@Test func transcriptDisplaySettingsPersistPrivatelyAndRejectInvalidFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TranscriptDisplaySettingsStore(directory: directory)
    #expect(try store.load() == TranscriptDisplayConfiguration())
    var config = TranscriptDisplayConfiguration(); config.maximumPause = 2; config.maximumDuration = 60
    try store.save(config)
    #expect(try store.load() == config)
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    let file = directory.appendingPathComponent("transcript-display.json")
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    let previous = try Data(contentsOf: file)
    config.maximumPause = .nan
    #expect(throws: MeetingError.self) { try store.save(config) }
    #expect(try Data(contentsOf: file) == previous)
    try Data(#"{"enabled":true,"maximumPause":99,"maximumDuration":30}"#.utf8).write(to: file)
    #expect(throws: MeetingError.self) { try store.load() }
    try Data("broken".utf8).write(to: file)
    #expect(throws: (any Error).self) { try store.load() }
}

@Test @MainActor func regroupingKeepsRawEventsFocusCopyAndAIStateAcrossRestart() throws {
    let suite = UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    let store = TranscriptDisplaySettingsStore(directory: directory)
    let model = MeetingViewModel(preferences: preferences, transcriptDisplayStore: store)
    let first = phrase("first", 0, 4), tail = phrase("tail", 4.5, 8)
    let ai = model.aiState
    model.appendTranscriptEvents([first])
    let revision = model.transcriptRevision
    model.appendTranscriptEvents([tail, tail])
    #expect(model.transcriptGroups.count == 1 && model.transcriptRevision > revision)
    model.focusedEventID = tail.id
    #expect(model.focusedTranscriptGroupID == first.id)
    #expect(model.transcriptCopyText == "[00:00:00–00:00:08] REMOTE_speaker_1: Да, да. Да, да.")
    model.transcriptDisplayConfiguration.enabled = false
    model.flushTranscriptDisplaySettings() // Closing/copying before the debounce fires.
    #expect(model.transcriptGroups.count == 2 && model.focusedTranscriptGroupID == tail.id)
    #expect(model.transcript == [first, tail] && model.aiState == ai)
    let restarted = MeetingViewModel(preferences: preferences, transcriptDisplayStore: store)
    #expect(!restarted.transcriptDisplayConfiguration.enabled && restarted.transcript.isEmpty)
    model.resetTranscript()
    #expect(model.transcriptGroups.isEmpty && model.focusedTranscriptGroupID == nil)
    model.appendTranscriptEvents([first])
    #expect(model.transcript == [first])
}
