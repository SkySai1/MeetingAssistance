import Foundation
import MeetingAssistantCore

struct Options: Sendable {
    var devicesOnly = false
    var captureOnly = false
    var duration: Double?
    var microphone: String?
    var remote: String?
    var remoteOnly = false
    var modelPath: String?
    var tokenizerPath: String?
    var thresholdDB = -42.0
    var json = false
    var debugAudioDirectory: String?
    var ai = AIConfiguration()
    var aiEnabled = false
    var aiOutput: String?
    var diarization = DiarizationConfiguration()
    var prepareDiarization = false
    var prepareSpeech = false

    init(arguments: [String]) throws {
        var index = 0
        var customDiarizationPath: String?
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                index += 1
                guard index < arguments.count else { throw MeetingError("Missing value for \(argument)") }
                return arguments[index]
            }
            switch argument {
            case "--devices": devicesOnly = true
            case "--capture-only": captureOnly = true
            case "--remote-only": remoteOnly = true
            case "--diarization": diarization.remoteEnabled = true
            case "--microphone-diarization": diarization.microphoneEnabled = true
            case "--prepare-diarization": prepareDiarization = true
            case "--prepare-speech": prepareSpeech = true
            case "--diarization-model":
                guard let model = DiarizationModel(rawValue: try value()) else { throw MeetingError("Supported diarizers: ls-eend-dihard3, ls-eend-ami, sortformer-v2.1") }
                diarization.model = model
            case "--diarization-model-path": customDiarizationPath = try value()
            case "--model-path": modelPath = try value()
            case "--tokenizer-path": tokenizerPath = try value()
            case "--json": json = true
            case "--debug-audio-dir": debugAudioDirectory = try value()
            case "--ollama-server": ai.server = try value()
            case "--ollama-model": ai.model = try value(); aiEnabled = true
            case "--ai-output": aiOutput = try value()
            case "--system-prompt-file": ai.systemPrompt = try String(contentsOfFile: value(), encoding: .utf8)
            case "--context-interval":
                guard let interval = Double(try value()), interval.isFinite, (2...120).contains(interval) else { throw MeetingError("--context-interval must be 2...120 seconds") }
                ai.updateInterval = interval
            case "--speech-threshold":
                guard let db = Double(try value()), db.isFinite, (-90 ... -5).contains(db) else { throw MeetingError("--speech-threshold must be between -90 and -5 dBFS") }
                thresholdDB = db
            case "--duration":
                guard let seconds = Double(try value()), seconds.isFinite, seconds > 0 else { throw MeetingError("--duration must be positive seconds") }
                duration = seconds
            case "--microphone": microphone = try value()
            case "--remote-device": remote = try value()
            case "--help", "-h": print(Self.help); exit(0)
            default: throw MeetingError("Unknown option: \(argument)\n\(Self.help)")
            }
            index += 1
        }
        if let customDiarizationPath { diarization.customModelPath = customDiarizationPath }
    }

    static let help = """
    Usage: swift run MeetingAssistant [options]
      --devices                 List and resolve audio devices, then exit
      --capture-only            Show independent input levels without ASR
      --remote-only             Transcribe only REMOTE (single-stream validation)
      --prepare-diarization     Download and check the local diarization model, then exit
      --prepare-speech          Download Whisper large-v3 and tokenizer into ~/.meetingassistant, then exit
      --diarization-model NAME  ls-eend-dihard3 (default), ls-eend-ami, sortformer-v2.1
      --diarization-model-path PATH  Custom .mlmodelc for the selected diarizer
      --diarization             Separate anonymous voices in REMOTE
      --microphone-diarization  Also separate microphone voices (default: off / YOU)
      --model-path PATH         Folder containing the local .mlmodelc models
      --tokenizer-path PATH     Folder containing local tokenizer JSON files
      --speech-threshold DB     Speech gate in dBFS (default: -42)
      --json                    Emit finalized events as JSON Lines on stdout
      --debug-audio-dir PATH     Explicitly save ASR input WAVs and raw result JSON locally
      --ollama-server URL        AI server (default: http://127.0.0.1:11434)
      --ollama-model NAME        Enable AI with this explicitly selected model
      --system-prompt-file PATH  UTF-8 system prompt for context and protocol
      --context-interval SEC    Coalesce finalized phrases (2...120, default: 10)
      --ai-output PATH          Write latest AI state as JSON, including final protocol
      --duration SECONDS        Stop automatically after this capture duration
      --microphone NAME         Exact microphone device name
      --remote-device NAME      Exact remote input name (default: BlackHole 2ch)
      --help                    Show this help
    """
}

enum Log {
    static func info(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

extension Options {
    func configuration(selected: [AudioSource: AudioDevice]) -> MeetingConfiguration {
        var configuration = MeetingConfiguration(selected: selected)
        configuration.captureOnly = captureOnly
        configuration.remoteOnly = remoteOnly
        configuration.duration = duration
        configuration.modelPath = modelPath
        configuration.tokenizerPath = tokenizerPath
        configuration.thresholdDB = thresholdDB
        configuration.debugAudioDirectory = debugAudioDirectory
        configuration.ai = aiEnabled ? ai : nil
        configuration.diarization = diarization
        return configuration
    }
}

extension TranscriptEvent {
    var terminalLine: String {
        let milliseconds = Int((max(0, startTime) * 1000).rounded())
        return String(format: "[%02d:%02d.%03d] [%@] %@", milliseconds / 60000,
                      (milliseconds / 1000) % 60, milliseconds % 1000, speakerLabel, text)
    }
}
