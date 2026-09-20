import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore

private func recoveryEntry(_ id: String, text: String, existingID: String = "", status: String = "active") -> ContextEntry {
    ContextEntry(id: existingID, kind: .decision, text: text, sourceIDs: [id], status: status, owner: "", deadline: "")
}

private enum RecoveryReply: Sendable {
    case delta(ContextDelta)
    case page([ContextEntry], more: Bool)
    case overview(String)
    case cut
    case networkFailure
    case protocolText
}

private actor RecoveryOllama: OllamaServing {
    let name = UUID().uuidString
    var replies: [RecoveryReply]
    var requests: [OllamaChatRequest] = []
    var unloaded = false
    init(_ replies: [RecoveryReply]) { self.replies = replies }
    func models() -> [OllamaModel] { [OllamaModel(name: name, size: nil, digest: nil, capabilities: nil)] }
    func unload(model: String) { unloaded = true }
    func chat(_ request: OllamaChatRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> OllamaChatResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw MeetingError("Unexpected extra recovery request") }
        let reply = replies.removeFirst()
        let text: String
        var reason = "stop"
        switch reply {
        case .delta(let delta): text = String(decoding: try JSONEncoder().encode(delta), as: UTF8.self)
        case .page(let updates, let more):
            struct Page: Encodable { let updates: [ContextEntry]; let hasMore: Bool }
            text = String(decoding: try JSONEncoder().encode(Page(updates: updates, hasMore: more)), as: UTF8.self)
        case .overview(let summary):
            text = String(decoding: try JSONEncoder().encode(["topic": "Релиз", "summary": summary]), as: UTF8.self)
        case .cut: text = #"{"summary":"Оборванный черновик"#; reason = "length"
        case .networkFailure: throw MeetingError("Соединение оборвалось")
        case .protocolText: text = "# Протокол\nРелиз перенесён с пятницы на понедельник."
        }
        await onText(text)
        return OllamaChatResponse(text: text, doneReason: reason, evaluationCount: request.options.num_predict)
    }
}

private func earlyDelta() -> ContextDelta {
    ContextDelta(topic: "Релиз", summary: "Релиз в пятницу", updates: [recoveryEntry("early", text: "Релиз в пятницу")])
}

@Test func factDisplayLimitDoesNotRejectGroundedFactsOrLoseThemFromProtocol() async throws {
    let facts = (1...3).map { index in
        ContextEntry(id: "", kind: .fact, text: "Факт \(index)", sourceIDs: ["source"], status: "active", owner: "", deadline: "")
    }
    let client = RecoveryOllama([.delta(ContextDelta(topic: "Тема", summary: "Справка", updates: facts)), .protocolText])
    var config = AIConfiguration(); config.model = client.name; config.factLimit = 1
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "source", source: .remote, startTime: 0, endTime: 1, text: "Факт 1. Факт 2. Факт 3."))
    engine.journal.close()
    await engine.run()
    let result = try #require(states.withLock { $0.last })
    #expect(result.phase == .completed && result.processedEvents == 1 && result.protocolComplete)
    #expect(result.briefing.entries.filter { $0.kind == .fact }.count == 1)
    #expect(result.hiddenFactCount == 2)
    let requests = await client.requests
    #expect(requests.count == 2)
    for fact in facts { #expect(requests.last?.messages.last?.content.contains(fact.text) == true) }
    #expect(result.releaseStatus == .unloaded)
}

@Test func pagedFactsAlsoExceedDisplayLimitWithoutLosingMemory() async throws {
    let facts = (1...3).map { index in
        ContextEntry(id: "", kind: .fact, text: "Факт \(index)", sourceIDs: ["source"], status: "active", owner: "", deadline: "")
    }
    let client = RecoveryOllama([.cut, .page(Array(facts.prefix(2)), more: true), .page([facts[2]], more: false), .overview("Три факта"), .protocolText])
    var config = AIConfiguration(); config.model = client.name; config.factLimit = 1; config.outputTokenLimit = 1024
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "source", source: .remote, startTime: 0, endTime: 1, text: "Факт 1. Факт 2. Факт 3."))
    engine.journal.close()
    await engine.run()
    let result = try #require(states.withLock { $0.last })
    #expect(result.phase == .completed && result.processedEvents == 1 && result.hiddenFactCount == 2)
    #expect(result.briefing.entries.count == 1 && result.protocolComplete && result.releaseStatus == .unloaded)
    let requests = await client.requests
    #expect(requests.count == 5)
    for fact in facts { #expect(requests.last?.messages.last?.content.contains(fact.text) == true) }
}

@Test func rejectedAIResponseLogsRequestAndPayloadWithoutCommittingInvalidSources() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = MeetingDebugLog(directory: directory, reportError: { _ in })
    log.start()
    let delta = ContextDelta(topic: "Тема", summary: "Справка", updates: [recoveryEntry("invented", text: "Неподтверждённый пункт")])
    let client = RecoveryOllama(Array(repeating: .delta(delta), count: 3))
    var config = AIConfiguration(); config.model = client.name; config.systemPrompt = "PRIVATE_SYSTEM_PROMPT"
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "source", source: .remote, startTime: 0, endTime: 1, text: "Обсуждение"))
    engine.journal.close()
    await Log.$file.withValue(log) { await engine.run() }
    await log.close()
    let state = try #require(states.withLock { $0.last })
    #expect(state.phase == .failed && state.processedEvents == 0 && state.briefing.entries.isEmpty)
    let text = try String(contentsOf: log.fileURL, encoding: .utf8)
    #expect(text.contains("AI validation rejected: request=1"))
    #expect(text.contains("AI rejected response: request=1, part=1"))
    #expect(text.contains("invented") && text.contains("Неподтверждённый пункт"))
    #expect(text.contains("AI batch:") && text.contains("AI delta:"))
    #expect(!text.contains("PRIVATE_SYSTEM_PROMPT"))
}

@Test(.timeLimit(.minutes(1))) func contextRecoveryPagesRetainEarlyDecisionAndFinalTailAfterNetworkRetry() async throws {
    let client = RecoveryOllama([
        .delta(earlyDelta()), .cut, .networkFailure,
        .page([recoveryEntry("tail", text: "Релиз в пятницу", existingID: "item_1", status: "superseded")], more: true),
        .page([recoveryEntry("tail", text: "Релиз в понедельник")], more: false),
        .overview("Релиз перенесён на понедельник."), .protocolText,
    ])
    var config = AIConfiguration(); config.model = client.name; config.batchEventLimit = 1; config.outputTokenLimit = 512
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "early", source: .remote, startTime: 0, endTime: 1, text: "Релиз в пятницу"))
    engine.journal.append(TranscriptEvent(id: "tail", source: .you, startTime: 2, endTime: 3, text: "Переносим релиз с пятницы на понедельник"))
    engine.journal.close()
    await engine.run()
    let result = try #require(states.withLock { $0.last })
    #expect(result.phase == .completed && result.processedEvents == 2 && result.protocolComplete)
    #expect(result.error == nil && result.generationNotice == nil && result.releaseStatus == .unloaded)
    #expect(result.briefing.summary == "Релиз перенесён на понедельник.")
    #expect(result.briefing.entries.map(\.id) == ["item_1", "item_2"])
    #expect(result.briefing.entries[0].status == "superseded" && result.briefing.entries[0].sourceIDs == ["early", "tail"])
    #expect(result.briefing.entries[1].sourceIDs == ["tail"])
    // No visible half-transaction: the early decision remains active until both
    // the cancellation and its replacement AND the new summary are validated.
    #expect(states.withLock { $0.filter { $0.processedEvents == 1 }.allSatisfy {
        $0.briefing.summary == "Релиз в пятницу" && $0.briefing.entries.count == 1 && $0.briefing.entries[0].status == "active"
    } })
    #expect(states.withLock { $0.contains { $0.generationNotice?.contains("Автоматический повтор") == true } })
    let requests = await client.requests
    #expect(requests.count == 7 && requests.allSatisfy { $0.options.num_predict == 512 })
    let pageSchema = try String(decoding: JSONEncoder().encode(try #require(requests[3].format)), as: UTF8.self)
    #expect(pageSchema.contains("hasMore") && pageSchema.contains("boolean") && !pageSchema.contains("maxLength"))
    #expect(requests[4].messages.last?.content.contains("УЖЕ ОБРАБОТАНО В ЭТОМ ПАКЕТЕ") == true)
    #expect(requests.last?.messages.last?.content.contains("Релиз в пятницу") == true)
    #expect(requests.last?.messages.last?.content.contains("Релиз в понедельник") == true)
}

@Test(.timeLimit(.minutes(1))) func contextRecoveryExhaustedOverviewRollsBackPagesAndPreservesPendingEvent() async throws {
    let client = RecoveryOllama([
        .delta(earlyDelta()), .cut,
        .page([recoveryEntry("tail", text: "Релиз в понедельник")], more: false),
        .cut, .cut, .cut,
    ])
    var config = AIConfiguration(); config.model = client.name; config.batchEventLimit = 1
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "early", source: .remote, startTime: 0, endTime: 1, text: "Релиз в пятницу"))
    engine.journal.append(TranscriptEvent(id: "tail", source: .you, startTime: 2, endTime: 3, text: "Релиз в понедельник"))
    engine.journal.close()
    await engine.run()
    let state = try #require(states.withLock { $0.last })
    #expect(state.phase == .failed && state.processedEvents == 1 && !state.protocolComplete)
    #expect(state.briefing.summary == "Релиз в пятницу" && state.briefing.entries.count == 1)
    #expect(engine.journal.snapshot().events.count == 2 && state.draftSummary.isEmpty)
    #expect(state.error?.contains("3 попыток") == true && state.error?.contains("токенов") == true)
    #expect(await client.requests.count == 6 && state.releaseStatus == .unloaded)
}

@Test(.timeLimit(.minutes(1))) func contextRecoveryRejectsRepeatedPagesAndUnknownSources() async throws {
    for invalid in [recoveryEntry("source", text: "Первый пункт"), recoveryEntry("invented", text: "Ложная ссылка")] {
        let client = RecoveryOllama([
            .cut, .page([recoveryEntry("source", text: "Первый пункт")], more: true),
            .page([invalid], more: true), .page([invalid], more: true), .page([invalid], more: true),
        ])
        var config = AIConfiguration(); config.model = client.name; config.outputTokenLimit = 512
        let states = Mutex<[AIState]>([])
        let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
        engine.journal.append(TranscriptEvent(id: "source", source: .remote, startTime: 0, endTime: 1, text: "Первый пункт"))
        engine.journal.close()
        await engine.run()
        let state = try #require(states.withLock { $0.last })
        #expect(state.phase == .failed && state.processedEvents == 0 && state.briefing.entries.isEmpty)
        #expect(await client.requests.count == 5 && state.releaseStatus == .unloaded)
    }
}

@Test(.timeLimit(.minutes(1))) func contextRecoveryCancellationDuringBackoffPreventsAnotherRequest() async throws {
    let client = RecoveryOllama([.cut, .networkFailure, .page([], more: false)])
    var config = AIConfiguration(); config.model = client.name
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "source", source: .remote, startTime: 0, endTime: 1, text: "Обсуждение"))
    let run = Task { await engine.run() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !states.withLock({ $0.contains { $0.generationNotice?.contains("Автоматический повтор") == true } }) && .now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    await engine.cancel()
    await run.value
    let state = try #require(states.withLock { $0.last })
    #expect(state.phase == .cancelled && state.processedEvents == 0 && state.releaseStatus == .unloaded)
    #expect(await client.requests.count == 2)
}

@Test(.timeLimit(.minutes(1))) func contextRecoveryManualRetryRestartsTransactionWithoutDuplicateIDs() async throws {
    let client = RecoveryOllama([
        .cut, .page([recoveryEntry("source", text: "Первый пункт")], more: false), .cut, .cut, .cut,
        .page([recoveryEntry("source", text: "Первый пункт")], more: false), .overview("Первый пункт согласован."), .protocolText,
    ])
    var config = AIConfiguration(); config.model = client.name
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "source", source: .remote, startTime: 0, endTime: 1, text: "Первый пункт"))
    let run = Task { await engine.run() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !states.withLock({ $0.contains { $0.phase == .failed } }) && .now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    let paused = try #require(states.withLock { $0.last })
    #expect(paused.phase == .failed && paused.processedEvents == 0 && paused.briefing.entries.isEmpty)
    await engine.retry()
    engine.journal.close()
    await run.value
    let state = try #require(states.withLock { $0.last })
    #expect(state.phase == .completed && state.processedEvents == 1 && state.protocolComplete)
    #expect(state.briefing.entries.map(\.id) == ["item_1"] && state.error == nil)
    #expect(await client.requests.count == 8 && state.releaseStatus == .unloaded)
}

/// Real Ollama generates all JSON responses with num_predict=512. Only the final
/// Markdown call is stubbed: generation has a 35 s watchdog, plus bounded unload.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_TEST_CONTEXT_RECOVERY_MODEL"] != nil), .timeLimit(.minutes(1)))
func liveContextRecoveryAtSmallTokenLimit() async throws {
    let environment = ProcessInfo.processInfo.environment
    var config = AIConfiguration()
    config.model = try #require(environment["MEETING_TEST_CONTEXT_RECOVERY_MODEL"])
    config.server = environment["MEETING_TEST_OLLAMA_SERVER"] ?? config.server
    config.outputTokenLimit = 512
    let url = try OllamaClient.baseURL(config.server).appendingPathComponent("api/ps")
    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 3))
    struct Running: Decodable { let models: [OllamaModel] }
    let running = try JSONDecoder().decode(Running.self, from: data)
    let canonical = config.model.contains(":") ? config.model : config.model + ":latest"
    let preserveLoadedModel = running.models.contains { $0.name == config.model || $0.name == canonical }
    let client = try LiveRecoveryOllama(server: config.server, preserveLoadedModel: preserveLoadedModel)
    let states = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "utt_7a91b6c2-0eda-4ac1-b12a-e292a4f3c051", source: .remote, startTime: 0, endTime: 15,
        text: "Согласовали бюджет проекта: 47 миллионов рублей. Решили перенести релиз на понедельник. Анна подготовит документацию к четвергу. Борис проверит резервное копирование к среде. Срок выдачи доступов пока не определён. Лицензии сервера продлеваем на восемь месяцев. Екатерина подготовит демо ко вторнику. Интеграцию с CRM отключаем до релиза."))
    engine.journal.close()
    let began = ContinuousClock.now
    let watchdog = Task {
        do { try await Task.sleep(for: .seconds(35)) } catch { return }
        await engine.cancel()
    }
    await engine.run()
    watchdog.cancel()
    let state = try #require(states.withLock { $0.last })
    let directory = URL(fileURLWithPath: ".build/validation/context-recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(state).write(to: directory.appendingPathComponent("state.json"))
    let records = await client.records
    try encoder.encode(records).write(to: directory.appendingPathComponent("responses.json"))
    #expect(records.contains { $0.doneReason == "length" && $0.evaluationCount == 512 })
    #expect(records.contains { $0.page } && records.contains { $0.overview })
    #expect(state.phase == .completed && state.processedEvents == 1 && state.error == nil)
    #expect(!state.briefing.summary.isEmpty && !state.briefing.entries.isEmpty)
    let facts = state.briefing.entries.map { $0.text + " " + $0.owner + " " + $0.deadline }.joined(separator: " ").lowercased()
    for value in ["47", "понедельник", "анна", "четверг", "борис", "сред", "доступ", "лиценз", "екатерин", "вторник", "crm"] { #expect(facts.contains(value)) }
    #expect(state.briefing.entries.allSatisfy { $0.sourceIDs == ["utt_7a91b6c2-0eda-4ac1-b12a-e292a4f3c051"] })
    print("Live briefing recovery: \(records.count) JSON requests at 512 tokens; \(state.briefing.entries.count) entries; \(began.duration(to: .now)); preserve resident model: \(preserveLoadedModel)")
}

private actor LiveRecoveryOllama: OllamaServing {
    struct Record: Codable, Sendable {
        let page: Bool
        let overview: Bool
        let doneReason: String?
        let evaluationCount: Int?
        let text: String
    }
    let client: OllamaClient
    let preserveLoadedModel: Bool
    var records: [Record] = []
    init(server: String, preserveLoadedModel: Bool) throws {
        client = try OllamaClient(server: server); self.preserveLoadedModel = preserveLoadedModel
    }
    func models() async throws -> [OllamaModel] { try await client.models() }
    func unload(model: String) async throws {
        if !preserveLoadedModel { try await client.unload(model: model) }
    }
    func chat(_ request: OllamaChatRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> OllamaChatResponse {
        guard let schema = request.format else { return OllamaChatResponse(text: "Проверка восстановления справки завершена.") }
        let schemaJSON = try String(decoding: JSONEncoder().encode(schema), as: UTF8.self)
        let directory = URL(fileURLWithPath: ".build/validation/context-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = records.count + 1
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("request-\(index).json"))
        let partialURL = directory.appendingPathComponent("partial-\(index).txt")
        let response = try await client.chat(request) { text in
            try? text.write(to: partialURL, atomically: true, encoding: .utf8)
            await onText(text)
        }
        records.append(Record(page: schemaJSON.contains("hasMore"), overview: !schemaJSON.contains("updates"),
            doneReason: response.doneReason, evaluationCount: response.evaluationCount, text: response.text))
        return response
    }
}
