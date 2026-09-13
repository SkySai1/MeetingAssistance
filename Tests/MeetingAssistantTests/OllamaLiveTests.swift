import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore

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
    #expect(states.withLock { $0.allSatisfy { $0.briefing.summary.count <= config.summaryCharacterLimit && $0.briefing.entries.filter { $0.kind == .fact }.count <= config.factLimit } })
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
    func chat(_ request: OllamaChatRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        index += 1
        let directory = URL(fileURLWithPath: ".build/validation/ollama-context", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("request-\(index).json"))
        let text = try await client.chat(request, onText: onText)
        try text.write(to: directory.appendingPathComponent("response-\(index).txt"), atomically: true, encoding: .utf8)
        return text
    }
}
