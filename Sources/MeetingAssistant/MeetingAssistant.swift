import Foundation
import AVFoundation
import Synchronization
import MeetingAssistantCore

@main
struct MeetingAssistant {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.prepareSpeech {
                let paths = try await SpeechModelStore.shared.prepare()
                Log.info("Whisper ready: \(paths.model.path)\nTokenizer: \(paths.tokenizer.path)")
                return
            }
            if options.prepareDiarization {
                Log.info("Preparing local diarization model...")
                try await DiarizationModels.prepare(options.diarization.model)
                Log.info("Diarization model ready: \(DiarizationModels.modelURL(for: options.diarization.model).path)")
                return
            }
            Log.info("MeetingAssistant starting...\n\nAudio devices:")
            let devices = try AudioDeviceManager.devices()
            for device in devices {
                Log.info("[\(device.id)] \(device.name) — \(device.inputChannels) input channels, \(Int(device.sampleRate)) Hz")
            }
            let defaults = try AudioDeviceManager.defaultDeviceIDs()
            Log.info("System defaults (read only): input [\(defaults.input)], output [\(defaults.output)]")
            Log.info("\nSelected:")
            var selected: [AudioSource: AudioDevice] = [:]
            for source in AudioSource.allCases {
                let device = try AudioDeviceManager.select(devices, name: source == .you ? options.microphone : options.remote, source: source)
                selected[source] = device
                Log.info("\(source.rawValue) -> \(device.name) [\(device.id)]")
            }
            guard selected[.you]?.id != selected[.remote]?.id else { throw MeetingError("YOU and REMOTE must use different input devices") }
            if options.devicesOnly { return }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MeetingError("Microphone permission denied. Enable microphone access for the launching terminal/application in System Settings > Privacy & Security > Microphone.")
            }
            let session = MeetingSession(configuration: options.configuration(selected: selected), callbacks: MeetingCallbacks(
                diagnostic: { Log.info($0) },
                transcript: { event in
                    let data: Data
                    if options.json {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                        data = try encoder.encode(event) + Data([10])
                    } else { data = Data((event.terminalLine + "\n").utf8) }
                    try FileHandle.standardOutput.write(contentsOf: data)
                },
                analysis: { state in
                    if let path = options.aiOutput {
                        do {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            try encoder.encode(state).write(to: URL(fileURLWithPath: path), options: .atomic)
                        } catch { Log.info("AI output could not be saved: \(error)") }
                    }
                    if [.completed, .cancelled].contains(state.phase) {
                        Log.info("AI \(state.phase.rawValue): \(state.processedEvents)/\(state.totalEvents) events; model \(state.releaseStatus.rawValue)")
                    }
                },
                diarization: { state in
                    if state.phase != .running {
                        Log.info("Diarization \(state.source.rawValue): \(state.phase.rawValue) — \(state.detectedSpeakers) voices\(state.error.map { ": " + $0 } ?? "")")
                    }
                }
            ))
            let stop = StopSignal()
            let signalMonitor = Task {
                while !Task.isCancelled {
                    if stop.requested { session.requestStop(); return }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
            }
            defer { signalMonitor.cancel() }
            try await session.run()
            let finalDefaults = try AudioDeviceManager.defaultDeviceIDs()
            Log.info("System defaults after capture: input [\(finalDefaults.input)], output [\(finalDefaults.output)]")
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }
}

final class StopSignal: Sendable {
    private let flag = Atomic<Bool>(false)
    private let interrupt: DispatchSourceSignal
    private let terminate: DispatchSourceSignal
    var requested: Bool { flag.load(ordering: .acquiring) }
    init() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { [weak self] in self?.flag.store(true, ordering: .releasing) }
        terminate.setEventHandler { [weak self] in self?.flag.store(true, ordering: .releasing) }
        interrupt.resume()
        terminate.resume()
    }
    deinit { interrupt.cancel(); terminate.cancel() }
}
