import Foundation
import Synchronization

struct ContextInputEvent: Codable, Sendable, Equatable {
    let id: String
    let source: String
    let startTime: Double
    let endTime: Double
    let text: String
    let kind: String
    let speakerIDs: [String]?
    init(_ event: TranscriptEvent) {
        id = event.id; source = event.source.rawValue; startTime = event.startTime
        endTime = event.endTime; text = event.text; kind = "transcript"
        speakerIDs = event.speakerIDs
    }
    init(_ message: ContextMessage) {
        id = message.id; source = "USER_NOTE"; startTime = message.time
        endTime = message.time; text = message.text; kind = "userNote"
        speakerIDs = nil
    }
}

/// Synchronous, bounded intake from TranscriptTimeline, never awaiting HTTP.
/// Keeping the journal separate from the actor prevents a slow server backing up ASR.
final class MeetingEventJournal: Sendable {
    struct Storage: Sendable {
        var events: [ContextInputEvent] = []
        var ids: Set<String> = []
        var bytes = 0
        var closed = false
        var failure: String?
    }
    private let storage = Mutex(Storage())

    func append(_ event: TranscriptEvent) {
        append(ContextInputEvent(event))
    }

    func append(_ event: ContextInputEvent) {
        storage.withLock { state in
            guard !state.closed, state.failure == nil, !state.ids.contains(event.id) else { return }
            guard state.events.count < 12_000, state.bytes + event.text.utf8.count <= 16_777_216 else {
                state.failure = "AI достиг ограничения журнала встречи. Транскрипция продолжается; справка может быть неполной."
                return
            }
            state.events.append(event)
            state.ids.insert(event.id)
            state.bytes += event.text.utf8.count
        }
    }

    func appendMessage(_ message: ContextMessage) throws {
        try storage.withLock { state in
            guard !state.closed, state.failure == nil else { throw MeetingError("Приём сообщений в контекст уже завершён.") }
            guard state.events.count < 12_000, state.bytes + message.text.utf8.count <= 16_777_216 else {
                throw MeetingError("Достигнут лимит журнала AI. Сообщение не отправлено.")
            }
            state.events.append(ContextInputEvent(message))
            state.ids.insert(message.id)
            state.bytes += message.text.utf8.count
        }
    }

    func close() { storage.withLock { $0.closed = true } }
    func snapshot() -> Storage { storage.withLock { $0 } }
}

struct ContextDelta: Codable, Sendable {
    let topic: String
    let summary: String
    let updates: [ContextEntry]
}

struct ContextMemory: Sendable {
    private(set) var briefing = ContextBriefing()
    private var nextID = 1

    mutating func apply(_ delta: ContextDelta, newEvents: [ContextInputEvent], knownIDs: Set<String>, entryLimit: Int = 512) throws {
        guard delta.topic.utf8.count <= 1000, delta.summary.utf8.count <= 6000, delta.updates.count <= 32 else {
            throw MeetingError("Справка превысила допустимый размер обновления.")
        }
        var updated = briefing
        var next = nextID
        let newIDs = Set(newEvents.map(\.id))
        for change in delta.updates {
            guard !change.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  change.text.utf8.count <= 2400, change.owner.utf8.count <= 300, change.deadline.utf8.count <= 300,
                  ["active", "resolved", "superseded"].contains(change.status),
                  !change.sourceIDs.isEmpty, change.sourceIDs.count <= 32,
                  Set(change.sourceIDs).isSubset(of: knownIDs) else {
                throw MeetingError("Модель вернула некорректный пункт или ссылку на отсутствующую фразу. Обновление не применено.")
            }
            if !change.id.isEmpty {
                guard let index = updated.entries.firstIndex(where: { $0.id == change.id }),
                      updated.entries[index].kind == change.kind else { throw MeetingError("Модель изменила неизвестный пункт справки.") }
                let previous = updated.entries[index]
                if previous.text != change.text || previous.status != change.status || previous.owner != change.owner || previous.deadline != change.deadline {
                    guard !newIDs.isDisjoint(with: change.sourceIDs) else { throw MeetingError("Изменение решения не ссылается на новые события.") }
                }
                var item = change
                item.sourceIDs = Array(Set(previous.sourceIDs + change.sourceIDs)).sorted()
                if previous.kind == .decision && previous.status == "active" && change.status == "active" && previous.text != change.text {
                    // A model may express a changed decision as a replacement
                    // instead of emitting a separate superseded item. Keep the
                    // original wording in the ledger and create a new revision.
                    var historical = previous
                    historical.status = "superseded"
                    historical.sourceIDs = item.sourceIDs
                    updated.entries[index] = historical
                    item.id = "item_\(next)"
                    next += 1
                    updated.entries.append(item)
                } else {
                    if previous.kind == .decision && change.status == "superseded" { item.text = previous.text }
                    updated.entries[index] = item
                }
            } else {
                // Retries and copied context must not duplicate already committed items.
                if updated.entries.contains(where: { $0.kind == change.kind && $0.text == change.text && $0.status == change.status }) { continue }
                guard !newIDs.isDisjoint(with: change.sourceIDs) else { throw MeetingError("Новый пункт не ссылается на новые события.") }
                var item = change
                item.id = "item_\(next)"
                next += 1
                updated.entries.append(item)
            }
        }
        guard updated.entries.count <= entryLimit else { throw MeetingError("Достигнут лимит \(entryLimit) пунктов AI-справки. Последнее корректное состояние сохранено.") }
        updated.topic = delta.topic
        updated.summary = delta.summary
        briefing = updated
        nextID = next
    }

    /// Keep every committed entry in memory. Select relevant entries for a bounded
    /// request; absence from a model update never deletes older facts/decisions.
    func promptContext(for events: [ContextInputEvent], byteLimit: Int) throws -> String {
        let words = Self.keywords(events.map(\.text).joined(separator: " "))
        let ranked = briefing.entries.enumerated().sorted { a, b in
            func score(_ value: (offset: Int, element: ContextEntry)) -> Int {
                Self.keywords(value.element.text).intersection(words).count * 1000
                + (value.element.status == "active" ? 100 : 0) + value.offset
            }
            return score(a) > score(b)
        }
        var subset = ContextBriefing()
        subset.topic = briefing.topic
        subset.summary = briefing.summary
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // The narrative has an explicit bound; the complete ledger is retained.
        if try encoder.encode(subset).count > byteLimit { subset.summary = "" }
        if try encoder.encode(subset).count > byteLimit { subset.topic = "" }
        for (_, entry) in ranked {
            var candidate = subset
            candidate.entries.append(entry)
            if try encoder.encode(candidate).count <= byteLimit { subset = candidate }
        }
        return String(decoding: try encoder.encode(subset), as: UTF8.self)
    }

    private static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 4 }.map(String.init))
    }

    /// Only expose a fully received JSON string field, never raw partial JSON.
    static func draftSummary(from json: String) -> String {
        guard let key = json.range(of: #""summary""#), let colon = json[key.upperBound...].firstIndex(of: ":") else { return "" }
        let suffix = json[json.index(after: colon)...].drop(while: \.isWhitespace)
        guard suffix.first == "\"" else { return "" }
        var escaped = false
        for index in suffix.indices.dropFirst() {
            let character = suffix[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" {
                return (try? JSONDecoder().decode(String.self, from: Data(suffix[...index].utf8))) ?? ""
            }
        }
        return ""
    }
}

/// An application-wide lease prevents old-session cleanup unloading a new run.
/// This does not claim ownership of requests made by other clients of the server.
actor OllamaModelLease {
    static let shared = OllamaModelLease()
    private var owners: [String: UUID] = [:]
    func acquire(_ key: String, owner: UUID) throws {
        guard owners[key] == nil else { throw MeetingError("Предыдущая сессия ещё использует эту модель. Дождитесь её завершения.") }
        owners[key] = owner
    }
    func release(_ key: String, owner: UUID) {
        if owners[key] == owner { owners[key] = nil }
    }
}
