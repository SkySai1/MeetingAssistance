import Foundation
import AVFoundation
import Synchronization

@main
struct MeetingAssistant {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
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
            try await MeetingSession(options: options, selected: selected).run()
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
