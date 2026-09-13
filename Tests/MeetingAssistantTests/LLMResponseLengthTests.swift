import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore
@testable import MeetingAssistantApp

@Test func longNDJSONResponseRetainsUnicodeAndAcceptsTokenLimitFinish() throws {
    let text = String(repeating: "Полный текст 👩🏽‍💻\n", count: 40_000) + "КОНЕЦ"
    let data = try JSONSerialization.data(withJSONObject: ["message": ["content": text], "done": true, "done_reason": "length", "eval_count": 512])
    #expect(data.count > 1_048_576)
    var decoder = OllamaStreamDecoder()
    for byte in data { _ = try decoder.append(byte) }
    #expect(try decoder.finish() == text)
    #expect(decoder.doneReason == "length" && decoder.evaluationCount == 512)
}

@Test func displayPreviewExpandsWithoutChangingCompleteTextOrSplittingCharacters() {
    let text = "А👩🏽‍💻е\u{301}Б" + String(repeating: "длинный текст ", count: 100)
    let collapsed = AITextPreview(text, limit: 3, expanded: false)
    #expect(collapsed.text == "А👩🏽‍💻е\u{301}…" && collapsed.isTruncated)
    #expect(AITextPreview(text, limit: 3, expanded: true).text == text)
    #expect(AITextPreview("Ровно", limit: 5, expanded: false).text == "Ровно")
    #expect(!AITextPreview("Ровно", limit: 5, expanded: false).isTruncated)
}

private actor LongAnswerOllama: OllamaServing {
    let name = UUID().uuidString
    var requests: [OllamaChatRequest] = []
    var unloaded = false
    let invalidJSON: Bool
    let largeEntry: Bool
    let summary = String(repeating: "Подробная справка о встрече. ", count: 150)
    let protocolText = String(repeating: "Полученный протокол встречи.\n", count: 1000) + "Последняя строка"
    init(invalidJSON: Bool = false, largeEntry: Bool = false) { self.invalidJSON = invalidJSON; self.largeEntry = largeEntry }
    func models() -> [OllamaModel] { [OllamaModel(name: name, size: nil, digest: nil, capabilities: nil)] }
    func unload(model: String) { unloaded = true }
    func chat(_ request: OllamaChatRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> OllamaChatResponse {
        requests.append(request)
        let text: String
        if request.format == nil { text = protocolText }
        else if invalidJSON { text = #"{"topic":"Тема","summary":"Оборван"# }
        else {
            let entry = ContextEntry(id: "", kind: .decision, text: largeEntry ? protocolText : "Сохранить решение", sourceIDs: ["source"], status: "active", owner: "", deadline: "")
            text = String(decoding: try JSONEncoder().encode(ContextDelta(topic: "Встреча", summary: summary, updates: [entry])), as: UTF8.self)
        }
        await onText(text)
        return OllamaChatResponse(text: text, doneReason: "length", evaluationCount: request.options.num_predict)
    }
}

@Test func longSummaryAndTokenLimitedProtocolAreDeliveredWithoutCharacterRejection() async throws {
    let client = LongAnswerOllama()
    var config = AIConfiguration(); config.model = client.name
    config.responsePreviewCharacters = 100; config.outputTokenLimit = 768; config.contextTokens = 65536
    let snapshots = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in snapshots.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "source", source: .remote, startTime: 0, endTime: 1, text: "Согласовали решение"))
    engine.journal.close()
    await engine.run()
    let state = try #require(snapshots.withLock { $0.last })
    #expect(state.phase == .completed && state.error == nil && state.processedEvents == 1)
    #expect(state.briefing.summary == client.summary)
    #expect(snapshots.withLock { $0.contains { $0.draftSummary == client.summary } })
    #expect(state.protocolComplete && state.protocolText == client.protocolText && state.protocolTruncated == true)
    #expect(state.generationNotice != nil && state.releaseStatus == .unloaded)
    #expect(await client.requests.count == 2)
    #expect(await client.requests.allSatisfy { $0.options.num_predict == 768 })
    let requests = await client.requests
    let schema = try JSONEncoder().encode(try #require(requests.first?.format))
    #expect(!String(decoding: schema, as: UTF8.self).contains("maxLength"))
    #expect(!requests[0].messages.last!.content.contains("максимум 100 символов"))
}

@Test func tokenCutIncompleteJSONNeverCommitsOrConsumesPendingEvents() async throws {
    let client = LongAnswerOllama(invalidJSON: true)
    var config = AIConfiguration(); config.model = client.name
    let snapshots = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in snapshots.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "source", source: .remote, startTime: 0, endTime: 1, text: "Сохранить"))
    engine.journal.close()
    await engine.run()
    let state = try #require(snapshots.withLock { $0.last })
    #expect(state.phase == .failed && state.processedEvents == 0 && !state.protocolComplete)
    #expect(state.briefing.summary.isEmpty && engine.journal.snapshot().events.count == 1)
    #expect(state.error?.contains("токенов") == true && state.releaseStatus == .unloaded)
}

@Test func acceptedLongEntrySurvivesSmallerFinalPromptBudget() async throws {
    let client = LongAnswerOllama(largeEntry: true)
    var config = AIConfiguration(); config.model = client.name
    let snapshots = Mutex<[AIState]>([])
    let engine = ContextEngine(configuration: config, client: client) { state in snapshots.withLock { $0.append(state) } }
    engine.journal.append(TranscriptEvent(id: "source", source: .remote, startTime: 0, endTime: 1, text: "Сохранить"))
    engine.journal.close()
    await engine.run()
    let state = try #require(snapshots.withLock { $0.last })
    #expect(state.protocolComplete && state.protocolText.contains(client.protocolText))
    #expect(state.protocolText.contains("[source]") && state.error == nil)
}

@Test func legacyLengthSettingsMigrateToPreviewAndOnlyOldDefaultPromptChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = Data(#"{"enabled":true,"configuration":{"model":"test","summaryCharacterLimit":350,"responseByteLimit":1}}"#.utf8)
    try data.write(to: directory.appendingPathComponent("settings.json"))
    try AIConfiguration.previousDefaultPrompt.write(to: directory.appendingPathComponent("system-prompt.txt"), atomically: true, encoding: .utf8)
    let store = AISettingsStore(directory: directory)
    let migrated = try #require(try store.load())
    try migrated.configuration.validate()
    #expect(migrated.configuration.responsePreviewCharacters == 350)
    #expect(migrated.configuration.systemPrompt == AIConfiguration.defaultPrompt)
    let encoded = try String(contentsOf: directory.appendingPathComponent("settings.json"), encoding: .utf8)
    #expect(!encoded.contains("responseByteLimit") && !encoded.contains("summaryCharacterLimit"))
    try "Пользовательский промпт: 100 символов".write(to: directory.appendingPathComponent("system-prompt.txt"), atomically: true, encoding: .utf8)
    #expect(try store.load()?.configuration.systemPrompt == "Пользовательский промпт: 100 символов")
}
