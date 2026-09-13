import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore

private actor WaitingOllama: OllamaServing {
    let name = UUID().uuidString
    let holdProtocol: Bool
    var released = false
    var requestCount = 0
    var didUnload = false
    init(holdProtocol: Bool) { self.holdProtocol = holdProtocol }
    func allowResponse() { released = true }
    func models() -> [OllamaModel] { [OllamaModel(name: name, size: nil, digest: nil, capabilities: ["completion"])] }
    func chat(_ request: OllamaChatRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        requestCount += 1
        if (request.format == nil) == holdProtocol {
            while !released { try await Task.sleep(for: .milliseconds(10)) }
        }
        let result = request.format == nil ? "# Протокол\nГотово после ожидания" : #"{"topic":"Тест","summary":"Краткая справка","updates":[]}"#
        await onText(result)
        return result
    }
    func unload(model: String) { didUnload = true }
}

@Test(.timeLimit(.minutes(1)))
func responseWarningKeepsSameRequestAliveUntilUserContinuesWaiting() async throws {
    let client = WaitingOllama(holdProtocol: false)
    var config = AIConfiguration(); config.model = client.name
    config.responseWarningSeconds = 5
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(source: .you, startTime: 0, endTime: 1, text: "Проверка"))
    let run = Task { await engine.run() }
    do {
        try await waitForWarning(states)
        #expect(await client.requestCount == 1)
        #expect(await client.didUnload == false)
        #expect(states.withLock { $0.last?.phase } == .updating)
        await engine.continueWaiting()
        #expect(states.withLock { $0.last?.waitWarning } == nil)
        await client.allowResponse()
        engine.journal.close()
        await run.value
        #expect(states.withLock { $0.last?.protocolComplete } == true)
        #expect(await client.requestCount == 2)
        #expect(await client.didUnload)
    } catch { await engine.cancel(); await run.value; throw error }
}

@Test(.timeLimit(.minutes(1)))
func protocolWarningDoesNotFailFinalizationAndExplicitCancellationStillWorks() async throws {
    let client = WaitingOllama(holdProtocol: true)
    var config = AIConfiguration(); config.model = client.name
    config.protocolWarningSeconds = 5
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(source: .remote, startTime: 0, endTime: 1, text: "Последняя фраза"))
    engine.journal.close()
    let run = Task { await engine.run() }
    do {
        try await waitForWarning(states)
        #expect(states.withLock { $0.last?.phase } == .finalizing)
        #expect(states.withLock { $0.last?.error } == nil)
        #expect(await client.didUnload == false)
        let began = ContinuousClock.now
        await engine.cancel(); await run.value
        #expect(began.duration(to: .now) < .seconds(2))
        #expect(states.withLock { $0.last?.phase } == .cancelled)
        #expect(await client.didUnload)
    } catch { await engine.cancel(); await run.value; throw error }
}

private func waitForWarning(_ states: borrowing Mutex<[AIState]>) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while states.withLock({ $0.last?.waitWarning == nil }) {
        guard .now < deadline else { throw MeetingError("No soft warning within the short test budget") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Test func oldAISettingsReceiveSoftLimitDefaultsAndNewLimitsRoundTrip() throws {
    let old = try JSONDecoder().decode(AIConfiguration.self, from: Data(#"{"server":"http://localhost:11434","model":"test"}"#.utf8))
    #expect(old.responseWarningSeconds == 120 && old.protocolWarningSeconds == 180 && old.outputTokenLimit == 3000)
    var updated = old
    updated.outputTokenLimit = 8192; updated.contextTokens = 65536; updated.protocolWarningSeconds = 1800
    updated.responseByteLimit = 1_048_576; updated.temperature = 0.4
    try updated.validate()
    #expect(try JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(updated)) == updated)
    updated.protocolWarningSeconds = .nan
    #expect(throws: MeetingError.self) { try updated.validate() }
}
