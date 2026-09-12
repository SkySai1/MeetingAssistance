import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore

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
