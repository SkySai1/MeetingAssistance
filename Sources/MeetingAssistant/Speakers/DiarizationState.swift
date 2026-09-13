import Foundation
import FluidAudio

public struct DiarizationConfiguration: Codable, Sendable, Equatable {
    public var remoteEnabled = false
    public var microphoneEnabled = false
    public init() { }
    public func enabled(for source: AudioSource) -> Bool { source == .remote ? remoteEnabled : microphoneEnabled }
    public static var settingsURL: URL { AISettingsStore().directory.appendingPathComponent("diarization.json") }
    public static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: settingsURL))
    }
    public func save() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: Self.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.settingsURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.settingsURL.path)
    }
}

public struct SpeakerSpan: Codable, Sendable, Equatable {
    public let speakerID: String
    public var startTime: Double
    public var endTime: Double
}

public struct DiarizationState: Sendable, Equatable {
    public enum Phase: String, Sendable { case loading, ready, running, completed, failed }
    public let source: AudioSource
    public var phase: Phase
    public var processedThrough = 0.0
    public var detectedSpeakers = 0
    public var error: String?
}

public enum DiarizationModels {
    private static let preparation = DiarizationModelPreparation()
    public static var cacheDirectory: URL { AISettingsStore().directory.appendingPathComponent("models/diarization", isDirectory: true) }
    public static var modelURL: URL {
        modelURL(in: cacheDirectory)
    }
    static func modelURL(in directory: URL) -> URL {
        let variant = LSEENDVariant.dihard3
        let repo = variant.repo
        let path = variant.fileName(forStep: .step500ms)
        return directory.appendingPathComponent(repo.folderName).appendingPathComponent(repo.subPath.map { $0 + "/" + path } ?? path)
    }
    public static var isReady: Bool { FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("coremldata.bin").path) }
    /// Explicit user action; starting a meeting never downloads a model.
    public static func prepare() async throws {
        try await preparation.prepare()
    }
}

/// Publish only a fully downloaded, loadable model. An interrupted download cannot
/// become the cache that FluidAudio would mistake for an already prepared model.
private actor DiarizationModelPreparation {
    private var task: Task<Void, Error>?
    func prepare() async throws {
        if let task { return try await task.value }
        let task = Task.detached {
            let manager = FileManager.default
            if DiarizationModels.isReady {
                _ = try LSEENDModel(modelURL: DiarizationModels.modelURL, computeUnits: .cpuOnly)
                return
            }
            let staging = DiarizationModels.cacheDirectory.appendingPathComponent(".download-" + UUID().uuidString)
            defer { try? manager.removeItem(at: staging) }
            _ = try await LSEENDModel.loadFromHuggingFace(variant: .dihard3, stepSize: .step500ms, cacheDirectory: staging, computeUnits: .cpuOnly)
            try Task.checkCancellation()
            let destination = DiarizationModels.modelURL
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Preserve an incomplete old cache until installation succeeds.
            let previous = staging.appendingPathComponent("previous.mlmodelc")
            let hadPrevious = manager.fileExists(atPath: destination.path)
            if hadPrevious { try manager.moveItem(at: destination, to: previous) }
            do { try manager.moveItem(at: DiarizationModels.modelURL(in: staging), to: destination) }
            catch {
                if hadPrevious { try? manager.moveItem(at: previous, to: destination) }
                throw error
            }
        }
        self.task = task
        defer { self.task = nil }
        try await task.value
    }
}
