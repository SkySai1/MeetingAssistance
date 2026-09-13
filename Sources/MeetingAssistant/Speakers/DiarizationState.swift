import Foundation
import FluidAudio
import CoreML

public enum DiarizationModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case lsEENDDIHARD3 = "ls-eend-dihard3"
    case lsEENDAMI = "ls-eend-ami"
    case sortformer = "sortformer-v2.1"
    public var id: Self { self }
    public var title: String {
        switch self {
        case .lsEENDDIHARD3: "LS-EEND · DIHARD3 (до 10 голосов)"
        case .lsEENDAMI: "LS-EEND · AMI (до 4 голосов)"
        case .sortformer: "Sortformer v2.1 · встречи (до 4 голосов)"
        }
    }
    public var details: String {
        self == .sortformer
            ? "Память голосов обновляется по ходу встречи. Модель хранит представления ранних голосов и недавней речи."
            : "Непрерывное состояние голосов сохраняется до конца встречи. DIHARD3 рассчитана на разнообразные записи, AMI — на встречи."
    }
    var variant: LSEENDVariant? {
        switch self { case .lsEENDDIHARD3: .dihard3; case .lsEENDAMI: .ami; case .sortformer: nil }
    }
    static var sortformerConfig: SortformerConfig { .balancedV2_1 }
}

public struct DiarizationConfiguration: Codable, Sendable, Equatable {
    public var remoteEnabled = false
    public var microphoneEnabled = false
    public var model: DiarizationModel = .lsEENDDIHARD3
    public var customModelPaths: [String: String] = [:]
    public var customModelPath: String {
        get { customModelPaths[model.rawValue] ?? "" }
        set { customModelPaths[model.rawValue] = newValue.isEmpty ? nil : newValue }
    }
    public var resolvedModelURL: URL {
        customModelPath.isEmpty ? DiarizationModels.modelURL(for: model)
            : URL(fileURLWithPath: (customModelPath as NSString).expandingTildeInPath)
    }
    public var modelIsReady: Bool { DiarizationModels.isReady(at: resolvedModelURL) }
    public init() { }
    private enum CodingKeys: String, CodingKey { case remoteEnabled, microphoneEnabled, model, customModelPaths }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        remoteEnabled = try values.decodeIfPresent(Bool.self, forKey: .remoteEnabled) ?? false
        microphoneEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? false
        model = try values.decodeIfPresent(DiarizationModel.self, forKey: .model) ?? .lsEENDDIHARD3
        customModelPaths = try values.decodeIfPresent([String: String].self, forKey: .customModelPaths) ?? [:]
    }
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
    public init(speakerID: String, startTime: Double, endTime: Double) {
        self.speakerID = speakerID; self.startTime = startTime; self.endTime = endTime
    }
}

public struct DiarizationState: Sendable, Equatable {
    public enum Phase: String, Sendable { case loading, ready, running, completed, failed }
    public let source: AudioSource
    public var phase: Phase
    public var processedThrough = 0.0
    public var detectedSpeakers = 0
    public var error: String?
    public var model: DiarizationModel = .lsEENDDIHARD3
    public var participants: [MeetingParticipant] = []
    public var voiceMemoryFrames: Int?
}

public enum DiarizationModels {
    private static let preparation = DiarizationModelPreparation()
    public static var cacheDirectory: URL { AISettingsStore().directory.appendingPathComponent("models/diarization", isDirectory: true) }
    public static var modelURL: URL {
        modelURL(for: .lsEENDDIHARD3)
    }
    public static func modelURL(for selection: DiarizationModel, in directory: URL = cacheDirectory) -> URL {
        if let variant = selection.variant {
            let repo = variant.repo
            let path = variant.fileName(forStep: .step500ms)
            return directory.appendingPathComponent(repo.folderName).appendingPathComponent(repo.subPath.map { $0 + "/" + path } ?? path)
        }
        return directory.appendingPathComponent(Repo.sortformer.folderName)
            // This fixed, pinned preset always has a bundled Core ML export.
            .appendingPathComponent(ModelNames.Sortformer.bundle(for: DiarizationModel.sortformerConfig)!)
    }
    public static var isReady: Bool { isReady(at: modelURL) }
    public static func isReady(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
    }
    /// Explicit user action; starting a meeting never downloads a model.
    public static func prepare(_ selection: DiarizationModel = .lsEENDDIHARD3) async throws {
        try await preparation.prepare(selection)
    }

    static func makeDiarizer(_ selection: DiarizationModel, at url: URL) throws -> any Diarizer {
        let timeline = DiarizerTimelineConfig(maxStoredFrames: 0, storeSegments: false)
        if let variant = selection.variant {
            let model = try LSEENDModel(modelURL: url, computeUnits: .cpuOnly)
            guard model.metadata.maxSpeakers == (variant == .ami ? 4 : 10) else {
                throw MeetingError("Папка модели не соответствует выбранному варианту LS-EEND.")
            }
            return try LSEENDDiarizer(model: model, timelineConfig: timeline)
        }
        let config = DiarizationModel.sortformerConfig
        let mlConfiguration = MLModelConfiguration(); mlConfiguration.computeUnits = .cpuAndNeuralEngine
        let models = try SortformerModels(config: config, main: MLModel(contentsOf: url, configuration: mlConfiguration))
        guard let shape = models.embeddedConfig, shape.chunkLen == config.chunkLen,
              shape.chunkLeftContext == config.chunkLeftContext, shape.chunkRightContext == config.chunkRightContext,
              shape.fifoLen == config.fifoLen, shape.spkcacheLen == config.spkcacheLen else {
            throw MeetingError("Нужна модель Sortformer v2.1 Balanced с совместимыми метаданными. Выберите её папку .mlmodelc или загрузите через приложение.")
        }
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timeline)
        diarizer.initialize(models: models)
        return diarizer
    }
}

/// Publish only a fully downloaded, loadable model. An interrupted download cannot
/// become the cache that FluidAudio would mistake for an already prepared model.
private actor DiarizationModelPreparation {
    private var tasks: [DiarizationModel: Task<Void, Error>] = [:]
    func prepare(_ selection: DiarizationModel) async throws {
        if let task = tasks[selection] { return try await task.value }
        let task = Task.detached {
            let manager = FileManager.default
            let destination = DiarizationModels.modelURL(for: selection)
            if DiarizationModels.isReady(at: destination) {
                _ = try DiarizationModels.makeDiarizer(selection, at: destination)
                return
            }
            let staging = DiarizationModels.cacheDirectory.appendingPathComponent(".download-" + UUID().uuidString)
            defer { try? manager.removeItem(at: staging) }
            if let variant = selection.variant {
                _ = try await LSEENDModel.loadFromHuggingFace(variant: variant, stepSize: .step500ms, cacheDirectory: staging, computeUnits: .cpuOnly)
            } else {
                _ = try await SortformerModels.loadFromHuggingFace(config: DiarizationModel.sortformerConfig, cacheDirectory: staging, computeUnits: .cpuAndNeuralEngine)
            }
            try Task.checkCancellation()
            let prepared = DiarizationModels.modelURL(for: selection, in: staging)
            _ = try DiarizationModels.makeDiarizer(selection, at: prepared)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Preserve an incomplete old cache until installation succeeds.
            let previous = staging.appendingPathComponent("previous.mlmodelc")
            let hadPrevious = manager.fileExists(atPath: destination.path)
            if hadPrevious { try manager.moveItem(at: destination, to: previous) }
            do { try manager.moveItem(at: prepared, to: destination) }
            catch {
                if hadPrevious { try? manager.moveItem(at: previous, to: destination) }
                throw error
            }
        }
        tasks[selection] = task
        defer { tasks[selection] = nil }
        try await task.value
    }
}
