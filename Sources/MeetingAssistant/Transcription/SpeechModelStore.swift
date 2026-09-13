import ArgmaxCore
import Foundation
@preconcurrency import WhisperKit

public struct SpeechModelSettings: Codable, Sendable {
    public var modelPath: String
    public var tokenizerPath: String
    public init(modelPath: String = "", tokenizerPath: String = "") {
        self.modelPath = modelPath; self.tokenizerPath = tokenizerPath
    }
    public static var fileURL: URL { AISettingsStore().directory.appendingPathComponent("speech-models.json") }
    public static func load(from url: URL = fileURL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Explicit installation of the supported large-v3 variant and its matching tokenizer.
/// Downloads never happen as a side effect of starting audio or opening settings.
public actor SpeechModelStore {
    public static let shared = SpeechModelStore()
    public static var directory: URL {
        AISettingsStore().directory.appendingPathComponent("models/whisper/large-v3-626MB", isDirectory: true)
    }
    private var installation: Task<ModelPaths, Error>?

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> ModelPaths {
        if let installation { return try await installation.value }
        let task = Task.detached {
            let manager = FileManager.default
            let target = Self.directory
            if let paths = try? ModelPaths(model: target.appendingPathComponent("model").path, tokenizer: target.appendingPathComponent("tokenizer").path) {
                progress(1, "Модель уже загружена")
                return paths
            }
            let staging = target.deletingLastPathComponent().appendingPathComponent(".download-" + UUID().uuidString)
            defer { try? manager.removeItem(at: staging) }
            let cache = staging.appendingPathComponent("cache")
            progress(0, "Загрузка Whisper large-v3 · 626 MB")
            let model = try await WhisperKit.download(variant: "openai_whisper-large-v3-v20240930_626MB", downloadBase: cache) {
                progress(min(0.94, $0.fractionCompleted * 0.94), "Загрузка Whisper large-v3")
            }
            try Task.checkCancellation()
            let tokenizer = try await HubApiWrapper(downloadBase: cache).snapshot(from: .init(id: "openai/whisper-large-v3"),
                matching: ["tokenizer.json", "tokenizer_config.json", "config.json"]) {
                    progress(0.94 + min(0.04, $0.fractionCompleted * 0.04), "Загрузка словаря")
                }
            _ = try ModelPaths(model: model.path, tokenizer: tokenizer.path)
            _ = try await LocalWhisperTokenizer(folder: tokenizer)
            try Task.checkCancellation()
            progress(0.99, "Установка файлов")
            let ready = staging.appendingPathComponent("ready")
            try manager.createDirectory(at: ready, withIntermediateDirectories: true)
            try manager.moveItem(at: model, to: ready.appendingPathComponent("model"))
            try manager.moveItem(at: tokenizer, to: ready.appendingPathComponent("tokenizer"))
            let previous = staging.appendingPathComponent("previous")
            let hadPrevious = manager.fileExists(atPath: target.path)
            if hadPrevious { try manager.moveItem(at: target, to: previous) }
            do { try manager.moveItem(at: ready, to: target) }
            catch {
                if hadPrevious { try? manager.moveItem(at: previous, to: target) }
                throw error
            }
            progress(1, "Модель и словарь готовы")
            return try ModelPaths(model: target.appendingPathComponent("model").path, tokenizer: target.appendingPathComponent("tokenizer").path)
        }
        installation = task
        defer { installation = nil }
        return try await task.value
    }

    public func cancel() { installation?.cancel() }
}
