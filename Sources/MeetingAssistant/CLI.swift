import Foundation

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

    init(arguments: [String]) throws {
        var index = 0
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
            case "--model-path": modelPath = try value()
            case "--tokenizer-path": tokenizerPath = try value()
            case "--json": json = true
            case "--debug-audio-dir": debugAudioDirectory = try value()
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
    }

    static let help = """
    Usage: swift run MeetingAssistant [options]
      --devices                 List and resolve audio devices, then exit
      --capture-only            Show independent input levels without ASR
      --remote-only             Transcribe only REMOTE (single-stream validation)
      --model-path PATH         Folder containing the local .mlmodelc models
      --tokenizer-path PATH     Folder containing local tokenizer JSON files
      --speech-threshold DB     Speech gate in dBFS (default: -42)
      --json                    Emit finalized events as JSON Lines on stdout
      --debug-audio-dir PATH     Explicitly save ASR input WAVs and raw result JSON locally
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
