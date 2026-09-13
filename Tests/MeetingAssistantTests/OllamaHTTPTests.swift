import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore

private final class TokenLimitOllamaProtocol: URLProtocol, @unchecked Sendable {
    static let bodies = Mutex<[String: Data]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.bodies.withLock { $0[request.url!.path] = body }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":{"content":"Ответ до токенного предела"},"done":true,"done_reason":"length","eval_count":768}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@Test func outputTokenLimitReachesHTTPBodyAndFinalContentIsPublished() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TokenLimitOllamaProtocol.self]
    let client = try OllamaClient(server: "http://test.invalid/tokens", session: URLSession(configuration: configuration))
    let frames = Mutex<[String]>([])
    let request = OllamaChatRequest(model: "test", messages: [.init(role: "user", content: "Ответь")], options: .init(num_ctx: 32768, num_predict: 768))
    let result = try await client.chat(request) { text in frames.withLock { $0.append(text) } }
    let data = try #require(TokenLimitOllamaProtocol.bodies.withLock { $0["/tokens/api/chat"] })
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let options = try #require(body["options"] as? [String: Any])
    #expect(options["num_predict"] as? Int == 768 && options["num_ctx"] as? Int == 32768)
    #expect(body["stream"] as? Bool == true && body["think"] as? Bool == false)
    #expect(result.tokenLimitReached && result.evaluationCount == 768)
    #expect(frames.withLock { $0.last } == result.text)
}

private final class StalledOllamaProtocol: URLProtocol, @unchecked Sendable {
    static let cancelledPaths = Mutex<Set<String>>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url!.path.hasSuffix("chat") {
            client?.urlProtocol(self, didLoad: Data("{\"message\":{\"content\":\"Начало\"},\"done\":false}\n".utf8))
        }
        // Deliberately keep the response open, simulating a stalled server.
    }
    override func stopLoading() { Self.cancelledPaths.withLock { _ = $0.insert(request.url!.path) } }
}

private func stalledClient(_ path: String) throws -> OllamaClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StalledOllamaProtocol.self]
    return try OllamaClient(server: "http://test.invalid/\(path)", session: URLSession(configuration: configuration))
}

@Test func cancellingHTTPStreamCancelsUnderlyingTaskAfterHeaders() async throws {
    let client = try stalledClient("cancel")
    let request = OllamaChatRequest(model: "test", messages: [], options: .init(num_ctx: 16384, num_predict: 100))
    let task = Task { try await client.chat(request) { _ in } }
    try await Task.sleep(for: .milliseconds(200))
    let began = ContinuousClock.now
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(ContinuousClock.now - began < .seconds(2))
    #expect(StalledOllamaProtocol.cancelledPaths.withLock { $0.contains("/cancel/api/chat") })
}

@Test func modelDiscoveryHasHardDeadlineEvenAfterHeadersArrive() async throws {
    let client = try stalledClient("deadline")
    let began = ContinuousClock.now
    await #expect(throws: (any Error).self) { try await client.models() }
    #expect(ContinuousClock.now - began < .seconds(7))
    #expect(StalledOllamaProtocol.cancelledPaths.withLock { $0.contains("/deadline/api/tags") })
}
