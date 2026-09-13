import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore
@testable import MeetingAssistant
@testable import MeetingAssistantApp

@Test func diarizationPreservesSourceTextIDsAndOverlappingVoices() throws {
    var remote = SpeakerActivityWindow(source: .remote)
    var microphone = SpeakerActivityWindow(source: .you)
    // Two voices, with one overlapping frame; timeline starts 12.5 s into meeting.
    let frames: [Float] = [0.9, 0.1, 0.8, 0.8, 0.1, 0.9, 0.1, 0.1]
    try remote.ingest(frames, frameStart: 0, frameDuration: 0.5, speakers: 2, origin: 12.5)
    try microphone.ingest(frames, frameStart: 0, frameDuration: 0.5, speakers: 2, origin: 12.5)
    let event = TranscriptEvent(id: "stable", source: .remote, startTime: 12.75, endTime: 14, text: "Готово. Проверяем.")
    let result = remote.annotate(event)
    #expect(result.id == event.id && result.text == event.text && result.source == .remote)
    #expect(result.startTime == event.startTime && result.endTime == event.endTime)
    #expect(result.speakerIDs == ["REMOTE_speaker_1", "REMOTE_speaker_2"])
    #expect(result.speakerSpans?.first?.startTime == 12.75)
    #expect(result.speakerSpans?.first?.endTime == 13.5)
    #expect(result.speakerSpans?.last?.startTime == 13)
    let local = TranscriptEvent(source: .you, startTime: 12.75, endTime: 14, text: "Ответ")
    #expect(microphone.annotate(local).speakerIDs == ["YOU_speaker_1", "YOU_speaker_2"])
    #expect(remote.annotate(local).speakerIDs == [])
    #expect(ContextInputEvent(result).speakerIDs == result.speakerIDs)
    #expect(try JSONDecoder().decode(TranscriptEvent.self, from: JSONEncoder().encode(result)) == result)
}

@Test func diarizationRetainsStableSlotsAndBoundsRecentTimeline() throws {
    var window = SpeakerActivityWindow(source: .remote)
    try window.ingest([0.9, 0.1, 0.1, 0.9, 0.9, 0.1], frameStart: 0, frameDuration: 1, speakers: 2, origin: 0)
    let returning = window.annotate(TranscriptEvent(source: .remote, startTime: 2, endTime: 3, text: "Снова первый"))
    #expect(returning.speakerIDs == ["REMOTE_speaker_1"])
    try window.ingest(Array(repeating: 0, count: 244), frameStart: 3, frameDuration: 1, speakers: 2, origin: 0)
    let expired = window.annotate(TranscriptEvent(source: .remote, startTime: 0, endTime: 1, text: "Старая фраза"))
    #expect(expired.speakerIDs == [])
    #expect(window.detected.count == 2)
    #expect(throws: MeetingError.self) { try window.ingest([0.5], frameStart: 125, frameDuration: 1, speakers: 2, origin: 0) }
}

@Test func diarizationInletsFailIndependentlyAndDrainOnClose() throws {
    let remote = DiarizationInlet(), microphone = DiarizationInlet()
    remote.append(Array(repeating: 0, count: 30 * 16000), start: 0)
    remote.append([0], start: 30)
    microphone.append([0.2, 0.3], start: 1)
    #expect(throws: MeetingError.self) { try remote.next() }
    microphone.close()
    #expect(try microphone.next()?.samples == [0.2, 0.3])
    #expect(microphone.drained)
    microphone.append([0.4], start: 2)
    #expect(try microphone.next() == nil)
}

@Test func missingDiarizationModelKeepsUnknownTranscriptAndPublishesFailure() async throws {
    let states = Mutex<[DiarizationState]>([])
    let worker = SourceDiarizer(source: .remote, modelURL: URL(fileURLWithPath: "/nonexistent-diarization-model")) { state in states.withLock { $0.append(state) } }
    await worker.run()
    let input = TranscriptEvent(source: .remote, startTime: 0, endTime: 1, text: "Текст остаётся доступен")
    let output = try #require(await worker.annotate([input]).first)
    #expect(output.text == input.text && output.id == input.id && output.speakerIDs == [])
    #expect(states.withLock { $0.last?.phase } == .failed)
    #expect(worker.inlet.drained)
}

@Test func stalledDiarizationCannotHoldTranscriptBeyondTwoSeconds() async {
    // Simulate a worker stuck loading: its inference actor is never needed here.
    let worker = SourceDiarizer(source: .remote) { _ in }
    let began = ContinuousClock.now
    let output = await worker.annotate([TranscriptEvent(source: .remote, startTime: 0, endTime: 1, text: "Сохранить")])
    #expect(began.duration(to: .now) < .seconds(3))
    #expect(output.first?.speakerIDs == [])
}

@Test func microphoneDiarizationIsExplicitAndMailboxKeepsSourcesSeparate() throws {
    let defaults = try Options(arguments: [])
    #expect(!defaults.diarization.enabled(for: .you) && !defaults.diarization.enabled(for: .remote))
    let remote = try Options(arguments: ["--diarization"])
    #expect(remote.diarization.remoteEnabled && !remote.diarization.microphoneEnabled)
    let both = try Options(arguments: ["--diarization", "--microphone-diarization"])
    #expect(both.diarization.remoteEnabled && both.diarization.microphoneEnabled)
    let legacy = Data(#"{"source":"YOU","startTime":0,"endTime":1,"text":"Я"}"#.utf8)
    #expect(try JSONDecoder().decode(TranscriptEvent.self, from: legacy).speakerLabel == "YOU")
    let mailbox = SessionMailbox()
    mailbox.callbacks.diarization(DiarizationState(source: .you, phase: .ready))
    mailbox.callbacks.diarization(DiarizationState(source: .remote, phase: .failed))
    #expect(mailbox.drain().diarization.count == 2)
}
