import Foundation

public struct OllamaModel: Codable, Sendable, Identifiable, Equatable {
    public let name: String
    public let size: Int64?
    public let digest: String?
    public let capabilities: [String]?
    public var id: String { name }
    public var supportsCompletion: Bool { capabilities?.contains("completion") ?? true }
}

struct OllamaMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct OllamaChatRequest: Encodable, Sendable {
    let model: String
    let messages: [OllamaMessage]
    var format: OllamaSchema?
    let stream = true
    let think = false
    let keep_alive = "5m"
    let options: Options
    struct Options: Encodable, Sendable {
        let num_ctx: Int
        let num_predict: Int
        var temperature = 0.0
    }
}

/// Ollama's structured output grammar constrains identifiers and required fields;
/// semantic checks and source validation still run before committing the response.
indirect enum OllamaSchema: Encodable, Sendable {
    case string([String]? = nil, maximum: Int? = nil)
    case object([String: OllamaSchema])
    case array(OllamaSchema, Int, minimum: Int = 0)
    case alternatives([OllamaSchema])

    private enum Keys: String, CodingKey { case type, properties, required, additionalProperties, items, maxItems, minItems, maxLength, oneOf, `enum` }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        switch self {
        case .string(let allowed, let maximum):
            try values.encode("string", forKey: .type)
            try values.encodeIfPresent(allowed, forKey: .enum)
            try values.encodeIfPresent(maximum, forKey: .maxLength)
        case .object(let properties):
            try values.encode("object", forKey: .type)
            try values.encode(properties, forKey: .properties)
            try values.encode(properties.keys.sorted(), forKey: .required)
            try values.encode(false, forKey: .additionalProperties)
        case .array(let item, let maximum, let minimum):
            try values.encode("array", forKey: .type)
            try values.encode(item, forKey: .items)
            try values.encode(maximum, forKey: .maxItems)
            try values.encode(minimum, forKey: .minItems)
        case .alternatives(let variants):
            try values.encode(variants, forKey: .oneOf)
        }
    }

    static func context(entries: [ContextEntry], eventIDs: [String], summaryLimit: Int = 500) -> Self {
        .object(["topic": .string(), "summary": .string(maximum: summaryLimit), "updates": .array(.alternatives(ContextKind.allCases.map { kind in
            .object([
                "id": .string([""] + entries.filter { $0.kind == kind }.map(\.id)), "kind": .string([kind.rawValue]),
                "text": .string(), "sourceIDs": .array(.string(eventIDs), 32, minimum: 1),
                "status": .string(["active", "resolved", "superseded"]),
                "owner": .string(), "deadline": .string(),
            ])
        }), 32)])
    }
}

protocol OllamaServing: Sendable {
    func models() async throws -> [OllamaModel]
    func chat(_ request: OllamaChatRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> String
    func unload(model: String) async throws
}

// Stateful framing survives arbitrary HTTP chunks, including a split UTF-8 scalar.
struct OllamaStreamDecoder {
    var byteLimit = 262_144
    init(byteLimit: Int = 262_144) { self.byteLimit = byteLimit }
    private var line = Data()
    private(set) var text = ""
    private(set) var done = false
    private struct Frame: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let done: Bool?
        let done_reason: String?
        let error: String?
    }

    mutating func append(_ byte: UInt8) throws -> Bool {
        guard !done else { return false }
        if byte != 10 {
            guard line.count < 1_048_576 else { throw MeetingError("Слишком большой фрагмент ответа Ollama.") }
            line.append(byte)
            return false
        }
        return try consumeLine()
    }

    private mutating func consumeLine() throws -> Bool {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else { return false }
        let frame = try JSONDecoder().decode(Frame.self, from: line)
        if let error = frame.error { throw MeetingError("Ollama: \(error)") }
        if frame.done_reason == "length" { throw MeetingError("Ответ модели достиг ограничения длины. Обновление не применено.") }
        let content = frame.message?.content ?? ""
        guard text.utf8.count + content.utf8.count <= byteLimit else { throw MeetingError("Ответ модели превысил ограничение размера.") }
        text += content
        done = frame.done == true
        return !content.isEmpty || done
    }

    mutating func finish() throws -> String {
        if !line.isEmpty && !done { _ = try consumeLine() }
        guard done else { throw MeetingError("Поток Ollama оборвался до завершения ответа. Последняя справка сохранена.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingError("Ollama вернул пустой ответ.") }
        return text
    }
}

/// Native Ollama HTTP API, verified against docs.ollama.com and /api/version.
/// The session is ephemeral: no cookies, credentials, or response disk cache.
public final class OllamaClient: Sendable, OllamaServing {
    private let base: URL
    private let session: URLSession
    private let responseByteLimit: Int
    // The user-facing timers only warn. A finite Foundation transport ceiling
    // avoids resetting a live HTTP stream at the former 45/120-second deadlines.
    private static let streamingTransportTimeout = TimeInterval(Int32.max)

    public init(server: String, responseByteLimit: Int = 262_144) throws {
        base = try Self.baseURL(server)
        self.responseByteLimit = responseByteLimit
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.streamingTransportTimeout
        configuration.timeoutIntervalForResource = Self.streamingTransportTimeout
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    init(server: String, session: URLSession) throws {
        base = try Self.baseURL(server)
        self.session = session
        responseByteLimit = 262_144
    }

    deinit { session.invalidateAndCancel() }

    static func baseURL(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw MeetingError("Укажите адрес сервера с http:// или https://, без логина, параметров и фрагмента URL.")
        }
        return url
    }

    public func models() async throws -> [OllamaModel] {
        struct Response: Decodable { let models: [OllamaModel] }
        let data = try await data(path: "api/tags")
        return try JSONDecoder().decode(Response.self, from: data).models.sorted { $0.name < $1.name }
    }

    func chat(_ request: OllamaChatRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        var http = URLRequest(url: base.appendingPathComponent("api/chat"), timeoutInterval: Self.streamingTransportTimeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        http.httpBody = try encoder.encode(request)
        let (bytes, response) = try await session.bytes(for: http)
        return try await withTaskCancellationHandler {
            defer { bytes.task.cancel() }
            try Self.check(response)
            var decoder = OllamaStreamDecoder(byteLimit: responseByteLimit)
            var lastPublished = ContinuousClock.now
            for try await byte in bytes {
                try Task.checkCancellation()
                if try decoder.append(byte) {
                    let now = ContinuousClock.now
                    if decoder.done || now - lastPublished >= .milliseconds(100) {
                        await onText(decoder.text)
                        lastPublished = now
                    }
                    if decoder.done { break }
                }
            }
            let result = try decoder.finish()
            await onText(result)
            return result
        } onCancel: { bytes.task.cancel() }
    }

    func unload(model: String) async throws {
        struct Unload: Encodable { let model: String; let keep_alive = 0; let stream = false }
        _ = try await data(path: "api/generate", body: JSONEncoder().encode(Unload(model: model)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while true {
            struct Running: Decodable { let models: [OllamaModel] }
            let response = try await data(path: "api/ps")
            let names = try JSONDecoder().decode(Running.self, from: response).models.map(\.name)
            let canonical = model.contains(":") ? model : model + ":latest"
            if !names.contains(where: { $0 == model || $0 == canonical }) { return }
            guard ContinuousClock.now < deadline else { throw MeetingError("Сервер не подтвердил выгрузку модели. Возможно, её использует другой клиент.") }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func data(path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 5)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let http = request
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.boundedData(for: http) }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw MeetingError("Сервер Ollama не ответил за 5 секунд.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func boundedData(for request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        return try await withTaskCancellationHandler {
            defer { bytes.task.cancel() }
            try Self.check(response)
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 4_194_304 else { throw MeetingError("Слишком большой ответ Ollama.") }
                data.append(byte)
            }
            struct Failure: Decodable { let error: String }
            if let error = try? JSONDecoder().decode(Failure.self, from: data) { throw MeetingError("Ollama: \(error.error)") }
            return data
        } onCancel: { bytes.task.cancel() }
    }

    private static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw MeetingError("Сервер вернул некорректный HTTP-ответ.") }
        guard (200..<300).contains(response.statusCode) else { throw MeetingError("Ollama: HTTP \(response.statusCode). Проверьте адрес, доступ к серверу и выбранную модель.") }
    }
}
