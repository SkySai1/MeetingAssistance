import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore
@testable import MeetingAssistantApp

private func testConfiguration() -> MeetingConfiguration {
    MeetingConfiguration(selected: [
        .you: AudioDevice(id: 1001, name: "Test microphone", inputChannels: 1, sampleRate: 48000),
        .remote: AudioDevice(id: 1002, name: "Test remote", inputChannels: 2, sampleRate: 48000),
    ])
}

@Test func workerLogsOriginalFailureBeforeCancellingSibling() async throws {
    let messages = Mutex<[String]>([])
    await Log.$sink.withValue({ message in messages.withLock { $0.append(message) } }) {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await runMeetingWorker(source: .you, component: "capture") { throw MeetingError("primary failure") }
                }
                group.addTask {
                    try await runMeetingWorker(source: .remote, component: "ASR") { try await Task.sleep(for: .seconds(10)) }
                }
                for try await _ in group { }
            }
            Issue.record("Expected originating worker error")
        } catch { #expect(String(describing: error) == "primary failure") }
    }
    let records = messages.withLock { $0 }
    let error = try #require(records.firstIndex { $0.contains("ERROR: Worker failed: source=YOU") })
    let cancellation = try #require(records.firstIndex { $0.contains("Worker cancelled: source=REMOTE") })
    #expect(error < cancellation)
    #expect(records.filter { $0.contains("ERROR:") }.count == 1)
}

@Test func stopBeforeRunDoesNotLoadModelsOrOpenDevicesAndSessionCannotRunTwice() async throws {
    let phases = Mutex<[MeetingPhase]>([])
    let events = Mutex<[TranscriptEvent]>([])
    var configuration = testConfiguration()
    configuration.modelPath = "/nonexistent-model"
    let session = MeetingSession(configuration: configuration, callbacks: MeetingCallbacks(
        phase: { phase in phases.withLock { $0.append(phase) } },
        transcript: { event in events.withLock { $0.append(event) } }
    ))
    session.requestStop()
    session.requestStop()
    try await session.run()
    #expect(phases.withLock { $0 } == [.preparing, .stopped])
    #expect(events.withLock { $0.isEmpty })
    await #expect(throws: MeetingError.self) { try await session.run() }
    #expect(phases.withLock { $0 } == [.preparing, .stopped])
}

@Test func coreValidatesNonCLIConfigurationAndPublishesFailure() async {
    var configuration = testConfiguration()
    configuration.selected[.remote] = configuration.selected[.you]
    let phases = Mutex<[MeetingPhase]>([])
    let session = MeetingSession(configuration: configuration, callbacks: MeetingCallbacks(
        phase: { phase in phases.withLock { $0.append(phase) } }
    ))
    await #expect(throws: MeetingError.self) { try await session.run() }
    #expect(phases.withLock { $0.count } == 2)
    #expect(phases.withLock { $0.last } == .failed("YOU and REMOTE must use different input devices"))
    for duration in [0, -1, Double.infinity, Double.nan] {
        var invalid = testConfiguration()
        invalid.duration = duration
        #expect(throws: MeetingError.self) { try invalid.validate() }
    }
}

@Test func finalDrainDeliversBothSourcesBeforeReturningAndPropagatesSinkFailure() async throws {
    let delivered = Mutex<[TranscriptEvent]>([])
    let timeline = TranscriptTimeline(sources: [.you, .remote]) { event in delivered.withLock { $0.append(event) } }
    let remote = StreamPipeline(source: .remote, thresholdDB: -42, timeline: timeline)
    let you = StreamPipeline(source: .you, thresholdDB: -42, timeline: timeline)
    try await remote.ingest([Float](repeating: 0.2, count: 16000), start: 0)
    try await you.ingest([Float](repeating: 0.2, count: 16000), start: 0)
    try await remote.finish()
    try await you.finish()
    #expect(await remote.next()?.isFinal == true)
    #expect(await you.next()?.isFinal == true)
    let late = TranscriptEvent(source: .remote, startTime: 0.5, endTime: 0.9, text: "Да.")
    let early = TranscriptEvent(source: .you, startTime: 0.1, endTime: 0.4, text: "Готово?")
    try await remote.complete([late], lag: 0)
    #expect(delivered.withLock { $0.isEmpty })
    try await you.complete([early], lag: 0)
    #expect(delivered.withLock { $0 } == [early, late])
    #expect(await remote.isDrained)
    #expect(await you.isDrained)

    let failedSink = TranscriptTimeline(sources: [.remote]) { _ in throw MeetingError("sink unavailable") }
    await #expect(throws: MeetingError.self) {
        try await failedSink.update(source: .remote, events: [late], frontier: .infinity)
    }
}

@Test func guiMailboxKeepsFinalEventsAndBoundsSlowConsumerMemory() throws {
    let mailbox = SessionMailbox()
    let callbacks = mailbox.callbacks
    let event = TranscriptEvent(source: .you, startTime: 0, endTime: 1, text: "Тест.")
    for index in 0..<1024 {
        try callbacks.transcript(event)
        callbacks.diagnostic("Message \(index)")
        callbacks.metrics(AudioMetrics(source: .you, elapsed: Double(index), levelDB: -20, backlogSeconds: 0))
    }
    #expect(throws: MeetingError.self) { try callbacks.transcript(event) }
    callbacks.phase(.stopped)
    let batch = mailbox.drain()
    #expect(batch.events.count == 1024)
    #expect(batch.diagnostics.count == 100)
    #expect(batch.diagnostics.last == "Message 1023")
    #expect(batch.metrics.count == 1)
    #expect(batch.metrics[.you]?.elapsed == 1023)
    #expect(batch.phase == .stopped)
    #expect(mailbox.drain().events.isEmpty)
    try callbacks.transcript(event)
    #expect(mailbox.drain().events == [event])
}
