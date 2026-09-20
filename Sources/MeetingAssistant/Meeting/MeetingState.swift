import Foundation

public enum MeetingPhase: Sendable, Equatable {
    case idle, preparing, loadingModels, running, stopping, finishingAnalysis, stopped
    case failed(String)
}

public struct AudioMetrics: Sendable {
    public let source: AudioSource
    public let elapsed: Double
    public let levelDB: Double
    public let backlogSeconds: Double
}

/// Frontends choose how to present events. Callbacks run off the audio callback
/// and must return promptly. A throwing transcript sink stops the session.
public struct MeetingCallbacks: Sendable {
    public var phase: @Sendable (MeetingPhase) -> Void
    public var metrics: @Sendable (AudioMetrics) -> Void
    public var diagnostic: @Sendable (String) -> Void
    public var transcript: @Sendable (TranscriptEvent) throws -> Void
    public var analysis: @Sendable (AIState) async -> Void
    public var diarization: @Sendable (DiarizationState) -> Void

    public init(
        phase: @escaping @Sendable (MeetingPhase) -> Void = { _ in },
        metrics: @escaping @Sendable (AudioMetrics) -> Void = { _ in },
        diagnostic: @escaping @Sendable (String) -> Void = { _ in },
        transcript: @escaping @Sendable (TranscriptEvent) throws -> Void = { _ in },
        analysis: @escaping @Sendable (AIState) async -> Void = { _ in },
        diarization: @escaping @Sendable (DiarizationState) -> Void = { _ in }
    ) {
        self.phase = phase; self.metrics = metrics
        self.diagnostic = diagnostic; self.transcript = transcript
        self.analysis = analysis
        self.diarization = diarization
    }
}

public struct MeetingConfiguration: Sendable {
    public var selected: [AudioSource: AudioDevice]
    public var captureOnly = false
    public var remoteOnly = false
    public var duration: Double?
    public var modelPath: String?
    public var tokenizerPath: String?
    public var thresholdDB = -42.0
    public var debugAudioDirectory: String?
    public var debugEnabled = false
    public var debugLogDirectory: URL = MeetingDebugLog.directory
    public var ai: AIConfiguration?
    public var diarization = DiarizationConfiguration()

    public init(selected: [AudioSource: AudioDevice]) { self.selected = selected }

    var sources: [AudioSource] { remoteOnly ? [.remote] : AudioSource.allCases }

    func validate() throws {
        if let duration, !duration.isFinite || duration <= 0 {
            throw MeetingError("Capture duration must be positive finite seconds")
        }
        guard thresholdDB.isFinite, (-90 ... -5).contains(thresholdDB) else {
            throw MeetingError("Speech threshold must be between -90 and -5 dBFS")
        }
        for source in sources {
            guard let device = selected[source], device.inputChannels > 0 else {
                throw MeetingError("No selected input device for \(source.rawValue)")
            }
        }
        if !remoteOnly, selected[.you]?.id == selected[.remote]?.id {
            throw MeetingError("YOU and REMOTE must use different input devices")
        }
    }
}

// Task-local diagnostics propagate to structured workers without global mutable
// logging state or a dependency on stdout, the CLI, AppKit, or SwiftUI.
enum Log {
    @TaskLocal static var sink: @Sendable (String) -> Void = { _ in }
    @TaskLocal static var file: MeetingDebugLog?
    static func debug(_ message: @autoclosure () -> String) { file?.record(.debug, message()) }
    static func info(_ message: String) { file?.record(.info, message); sink(message) }
    static func warning(_ message: String) { file?.record(.warning, message); sink("WARNING: " + message) }
    static func error(_ message: String) { file?.record(.error, message); sink("ERROR: " + message) }
}
