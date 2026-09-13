import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore

/// Two real API calls with explicit output limits; total generation budget 35 s.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_TEST_OLLAMA_MODEL"] != nil), .timeLimit(.minutes(1)))
func liveOllamaHonorsOutputTokenLimit() async throws {
    let environment = ProcessInfo.processInfo.environment
    let model = try #require(environment["MEETING_TEST_OLLAMA_MODEL"])
    let client = try OllamaClient(server: environment["MEETING_TEST_OLLAMA_SERVER"] ?? "http://127.0.0.1:11434")
    struct Result: Codable, Sendable { let limit: Int; let tokens: Int?; let reason: String?; let characters: Int; let text: String }
    let began = ContinuousClock.now
    do {
        let results = try await withThrowingTaskGroup(of: [Result].self) { group in
            group.addTask {
                var results: [Result] = []
                for limit in [512, 768] {
                    let request = OllamaChatRequest(model: model, messages: [.init(role: "user", content: "Напиши список из 1000 разных советов по организации встреч. Для каждого пункта напиши отдельное предложение. Не сокращай список и не добавляй заключение.")], options: .init(num_ctx: 16384, num_predict: limit))
                    let response = try await client.chat(request) { _ in }
                    results.append(Result(limit: limit, tokens: response.evaluationCount, reason: response.doneReason, characters: response.text.count, text: response.text))
                }
                return results
            }
            group.addTask { try await Task.sleep(for: .seconds(35)); throw MeetingError("Token-limit test exceeded short generation budget") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let directory = URL(fileURLWithPath: ".build/validation/ollama-token-limit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: directory.appendingPathComponent("results.json"))
        for result in results {
            #expect(result.tokens == result.limit)
            #expect(result.reason == "length" && result.characters > 500)
            print("num_predict=\(result.limit): eval_count=\(result.tokens ?? 0), done_reason=\(result.reason ?? ""), \(result.characters) characters retained")
        }
        try await client.unload(model: model)
        #expect(try await !client.models().isEmpty)
        print("Token-limit live test and unload: \(began.duration(to: .now))")
    } catch { try? await client.unload(model: model); throw error }
}

/// Explicit opt-in; the ordinary test suite never loads a model or needs a server.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_TEST_OLLAMA_MODEL"] != nil))
func liveOllamaRetainsEarlyDecisionAndFinalTail() async throws {
    let environment = ProcessInfo.processInfo.environment
    var config = AIConfiguration()
    config.model = try #require(environment["MEETING_TEST_OLLAMA_MODEL"])
    config.server = environment["MEETING_TEST_OLLAMA_SERVER"] ?? config.server
    config.updateInterval = 2
    let states = Mutex<[AIState]>([])
    let client = try RecordingOllama(server: config.server)
    let engine = ContextEngine(configuration: config, client: client) { state in states.withLock { $0.append(state) } }
    func phrase(_ id: String, _ text: String) -> TranscriptEvent {
        TranscriptEvent(id: id, source: .remote, startTime: 0, endTime: 1, text: text)
    }
    engine.journal.append(phrase("early", "Бюджет проекта — 47 миллионов рублей. Решили выпустить релиз в пятницу."))
    let run = Task { await engine.run() }
    do {
        for (target, next) in [(1, phrase("middle", "Анна подготовит инструкцию к четвергу. Открытый вопрос: кто проверит тестовую среду?")),
                               (2, phrase("late", "Отменяем решение о релизе в пятницу. Переносим релиз на понедельник. Последнее поручение: Борис проверит резервную копию к среде."))] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(150))
            while states.withLock({ ($0.last?.processedEvents ?? 0) < target }) {
                if ContinuousClock.now > deadline { throw MeetingError("Live context did not advance: \(states.withLock { $0.last?.error ?? "no error" })") }
                try await Task.sleep(for: .milliseconds(100))
            }
            engine.journal.append(next)
        }
        try await engine.addMessage("Контекст: это встреча команды разработки по планированию релиза. Справка нужна для технического руководителя.", time: 2)
        engine.journal.close()
        await run.value
    } catch {
        await engine.cancel(); await run.value
        throw error
    }
    let result = try #require(states.withLock { $0.last })
    let directory = URL(fileURLWithPath: ".build/validation/ollama-context", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(states.withLock { $0 }).write(to: directory.appendingPathComponent("states.json"))
    try result.protocolText.write(to: directory.appendingPathComponent("protocol.md"), atomically: true, encoding: .utf8)
    #expect(result.protocolComplete && result.processedEvents == 4 && result.updates >= 3)
    #expect(result.releaseStatus == .unloaded)
    #expect(result.error == nil)
    #expect(result.messages.count == 1)
    #expect(states.withLock { $0.allSatisfy { $0.briefing.entries.filter { $0.kind == .fact }.count <= config.factLimit } })
    #expect(result.briefing.entries.contains { $0.sourceIDs.contains("early") && $0.text.contains("47") })
    #expect(result.briefing.entries.contains { $0.sourceIDs.contains("late") && $0.text.lowercased().contains("резервн") })
    #expect(result.briefing.entries.contains { $0.status == "superseded" && $0.sourceIDs.contains("early") && $0.sourceIDs.contains("late") })
    #expect(result.protocolText.contains("47") && result.protocolText.lowercased().contains("понедельник") && result.protocolText.lowercased().contains("резервн"))
    #expect(states.withLock { $0.contains { !$0.draftSummary.isEmpty && $0.phase == .updating } })
    #expect(states.withLock { $0.contains { !$0.protocolText.isEmpty && !$0.protocolComplete } })
}

private actor RecordingOllama: OllamaServing {
    let client: OllamaClient
    var index = 0
    init(server: String) throws { client = try OllamaClient(server: server) }
    func models() async throws -> [OllamaModel] { try await client.models() }
    func unload(model: String) async throws { try await client.unload(model: model) }
    func chat(_ request: OllamaChatRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> OllamaChatResponse {
        index += 1
        let directory = URL(fileURLWithPath: ".build/validation/ollama-context", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("request-\(index).json"))
        let text = try await client.chat(request, onText: onText)
        try text.text.write(to: directory.appendingPathComponent("response-\(index).txt"), atomically: true, encoding: .utf8)
        return text
    }
}
