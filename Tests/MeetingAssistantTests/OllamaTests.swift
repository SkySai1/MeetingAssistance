import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore

private func event(_ id: String, _ text: String = "Релиз в пятницу") -> TranscriptEvent {
    TranscriptEvent(id: id, source: .remote, startTime: 0, endTime: 1, text: text)
}

private func item(_ source: String, id: String = "", text: String = "Релиз в пятницу", status: String = "active") -> ContextEntry {
    ContextEntry(id: id, kind: .decision, text: text, sourceIDs: [source], status: status, owner: "", deadline: "")
}

@Test func ndjsonHandlesUnicodeFramingAndRequiresCompleteResponse() throws {
    var decoder = OllamaStreamDecoder()
    let stream = "{\"message\":{\"content\":\"Привет 👋\"},\"done\":false}\n{\"message\":{\"content\":\"!\"},\"done\":true}"
    for byte in stream.utf8 { _ = try decoder.append(byte) }
    #expect(try decoder.finish() == "Привет 👋!")
    for invalid in ["{\"message\":{\"content\":\"черновик\"},\"done\":false}\n", "{\"error\":\"model missing\"}\n", "{\"done\":true,\"done_reason\":\"length\"}\n", "{\"message\":"] {
        #expect(throws: (any Error).self) {
            var failed = OllamaStreamDecoder()
            for byte in invalid.utf8 { _ = try failed.append(byte) }
            _ = try failed.finish()
        }
    }
    #expect(ContextMemory.draftSummary(from: #"{"summary":"Привет\nмир","updates":["#) == "Привет\nмир")
    #expect(ContextMemory.draftSummary(from: #"{"summary":"Привет"#).isEmpty)
}

@Test func contextRetainsEarlyDecisionsAndAppliesCorrectionsAtomically() throws {
    var memory = ContextMemory()
    try memory.apply(ContextDelta(topic: "Релиз", summary: "Пятница", updates: [item("early")]), newEvents: [event("early")], knownIDs: ["early"])
    try memory.apply(ContextDelta(topic: "Документ", summary: "Обсуждаем документ", updates: []), newEvents: [event("middle")], knownIDs: ["early", "middle"])
    #expect(memory.briefing.entries.count == 1)
    let snapshot = memory.briefing
    #expect(throws: MeetingError.self) {
        try memory.apply(ContextDelta(topic: "ошибка", summary: "", updates: [item("late", id: "item_1", status: "superseded"), item("invented")]), newEvents: [event("late")], knownIDs: ["early", "late"])
    }
    #expect(memory.briefing == snapshot)
    try memory.apply(ContextDelta(topic: "Релиз", summary: "Перенесён", updates: [item("late", id: "item_1", status: "superseded"), item("late", text: "Релиз в понедельник")]), newEvents: [event("late")], knownIDs: ["early", "late"])
    #expect(memory.briefing.entries.first?.sourceIDs == ["early", "late"])
    #expect(memory.briefing.entries.first?.status == "superseded")
    #expect(memory.briefing.entries.count == 2)
    #expect(try memory.promptContext(for: [event("late")], byteLimit: 1000).utf8.count <= 1000)
    #expect(memory.briefing.entries.count == 2)
}

@Test func journalDeduplicatesAndStopsIntakeAtBoundWithoutThrowingIntoASR() {
    let journal = MeetingEventJournal()
    journal.append(event("same")); journal.append(event("same"))
    #expect(journal.snapshot().events.count == 1)
    for index in 1...12000 { journal.append(event(String(index))) }
    #expect(journal.snapshot().events.count == 12000)
    #expect(journal.snapshot().failure != nil)
    journal.close()
    journal.append(event("tail"))
    #expect(journal.snapshot().events.count == 12000)
}

@Test func replacingActiveDecisionPreservesItsOriginalRevision() throws {
    var memory = ContextMemory()
    try memory.apply(ContextDelta(topic: "Релиз", summary: "", updates: [item("early")]), newEvents: [event("early")], knownIDs: ["early"])
    try memory.apply(ContextDelta(topic: "Релиз", summary: "", updates: [item("late", id: "item_1", text: "Релиз в понедельник")]), newEvents: [event("late")], knownIDs: ["early", "late"])
    #expect(memory.briefing.entries.count == 2)
    #expect(memory.briefing.entries[0].status == "superseded" && memory.briefing.entries[0].text == "Релиз в пятницу")
    #expect(memory.briefing.entries[1].status == "active" && memory.briefing.entries[1].id != "item_1")
    #expect(memory.briefing.entries.allSatisfy { $0.sourceIDs.contains("early") && $0.sourceIDs.contains("late") })
}

@Test func configurationRejectsInvalidServerAndLegacyEventsRemainReadable() throws {
    for url in ["localhost:11434", "ftp://localhost", "https://user:pass@host", "http://host/?query=1", "http://host/#fragment"] {
        #expect(throws: MeetingError.self) { _ = try OllamaClient(server: url) }
    }
    #expect(try OllamaClient.baseURL(" https://host/ollama ").absoluteString == "https://host/ollama")
    let old = Data(#"{"source":"YOU","startTime":1,"endTime":2,"text":"Да"}"#.utf8)
    let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: old)
    #expect(!decoded.id.isEmpty)
    #expect(try JSONDecoder().decode(TranscriptEvent.self, from: JSONEncoder().encode(decoded)) == decoded)
}

private final class DeliveryFlag: Sendable { let value = Mutex(false) }

private actor FakeOllama: OllamaServing {
    let name: String
    var requests: [OllamaChatRequest] = []
    var failFirst: Bool
    var slow: Bool
    let delivered: DeliveryFlag
    var unloaded = false
    var deliveryBeforeUnload = false
    init(name: String, delivered: DeliveryFlag, failFirst: Bool = false, slow: Bool = false) {
        self.name = name; self.delivered = delivered; self.failFirst = failFirst; self.slow = slow
    }
    func models() -> [OllamaModel] { [OllamaModel(name: name, size: nil, digest: nil, capabilities: ["completion"])] }
    func chat(_ request: OllamaChatRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        requests.append(request)
        if slow { try await Task.sleep(for: .seconds(60)) }
        if failFirst { failFirst = false; await onText(#"{"summary":"черновик","updates":["#); throw MeetingError("stream interrupted") }
        if request.format == nil {
            await onText("# Протокол\nПятница")
            return "# Протокол\nПятница и финальная фраза"
        }
        let prompt = request.messages.last!.content
        let marker = "НОВЫЕ СОБЫТИЯ:\n"
        let data = Data(prompt.components(separatedBy: marker).last!.utf8)
        let events = try JSONDecoder().decode([TranscriptEvent].self, from: data)
        let result = ContextDelta(topic: "Релиз", summary: "План встречи", updates: events.map { item($0.id, text: $0.text) })
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        await onText(text)
        return text
    }
    func unload(model: String) {
        deliveryBeforeUnload = delivered.value.withLock { $0 }
        unloaded = true
    }
}

@Test func engineRetriesWithoutLosingInputAndDeliversBeforeUnload() async throws {
    var config = AIConfiguration(); config.model = UUID().uuidString; config.systemPrompt = "Тестовый промпт"
    let delivered = DeliveryFlag()
    let states = Mutex<[AIState]>([])
    let client = FakeOllama(name: config.model, delivered: delivered, failFirst: true)
    let engine = ContextEngine(configuration: config, client: client) { state in
        states.withLock { $0.append(state) }
        if state.protocolComplete { delivered.value.withLock { $0 = true } }
    }
    engine.journal.append(event("early"))
    engine.journal.append(event("tail", "Финальная фраза"))
    engine.journal.close()
    await engine.run()
    let result = try #require(states.withLock { $0.last })
    #expect(result.phase == .completed && result.protocolComplete && result.processedEvents == 2)
    #expect(result.briefing.entries.count == 2)
    #expect(states.withLock { $0.contains { $0.phase == .failed && $0.processedEvents == 0 && $0.briefing.entries.isEmpty } })
    #expect(await client.deliveryBeforeUnload)
    #expect(await client.requests.allSatisfy { $0.messages.first?.content == "Тестовый промпт" })
    #expect(await client.requests.count == 3)
    #expect(result.releaseStatus == .unloaded)
}

@Test func cancellingSlowAIIsBoundedAndReleasesModel() async throws {
    var config = AIConfiguration(); config.model = UUID().uuidString
    let client = FakeOllama(name: config.model, delivered: DeliveryFlag(), slow: true)
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(event("early"))
    let run = Task { await engine.run() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await client.requests.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let began = ContinuousClock.now
    await engine.cancel(); await run.value
    #expect(ContinuousClock.now - began < .seconds(2))
    #expect(states.withLock { $0.last?.phase } == .cancelled)
    #expect(await client.unloaded)
    #expect(!states.withLock { $0.last?.protocolComplete ?? true })
}

@Test func modelLeaseRejectsConcurrentOwnerAndIgnoresStaleRelease() async throws {
    let lease = OllamaModelLease(), a = UUID(), b = UUID()
    try await lease.acquire("server/model", owner: a)
    await #expect(throws: MeetingError.self) { try await lease.acquire("server/model", owner: b) }
    await lease.release("server/model", owner: a)
    try await lease.acquire("server/model", owner: b)
    await lease.release("server/model", owner: a)
    await #expect(throws: MeetingError.self) { try await lease.acquire("server/model", owner: a) }
}
