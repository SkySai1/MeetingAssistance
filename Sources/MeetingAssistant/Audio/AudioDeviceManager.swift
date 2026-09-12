import CoreAudio
import Foundation

struct MeetingError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw MeetingError("\(operation): OSStatus \(status)") }
}

struct AudioDevice: Sendable {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let sampleRate: Double
}

enum AudioDeviceManager {
    static func defaultDeviceIDs() throws -> (input: AudioDeviceID, output: AudioDeviceID) {
        func read(_ selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
            var property = address(selector)
            var id: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            try checkAudio(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id), "Read system default device")
            return id
        }
        return try (read(kAudioHardwarePropertyDefaultInputDevice), read(kAudioHardwarePropertyDefaultOutputDevice))
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func devices() throws -> [AudioDevice] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try checkAudio(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size), "Enumerate audio devices")
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try checkAudio(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &ids), "Read audio device IDs")
        return try ids.map { id in
            var name: CFString = "" as CFString
            property = address(kAudioObjectPropertyName)
            size = UInt32(MemoryLayout<CFString>.size)
            try withUnsafeMutablePointer(to: &name) { pointer in
                try checkAudio(AudioObjectGetPropertyData(id, &property, 0, nil, &size, pointer), "Read device name [\(id)]")
            }
            property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
            try checkAudio(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read input configuration [\(id)]")
            let storage = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            try checkAudio(AudioObjectGetPropertyData(id, &property, 0, nil, &size, storage), "Read input channels [\(id)]")
            let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
            var rate: Float64 = 0
            property = address(kAudioDevicePropertyNominalSampleRate)
            size = UInt32(MemoryLayout<Float64>.size)
            try checkAudio(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &rate), "Read sample rate [\(id)]")
            return AudioDevice(id: id, name: name as String, inputChannels: channels, sampleRate: rate)
        }
    }

    static func select(_ devices: [AudioDevice], name: String?, source: AudioSource) throws -> AudioDevice {
        let inputs = devices.filter { $0.inputChannels > 0 }
        let matches = inputs.filter { device in
            if let name { return device.name == name }
            switch source {
            case .remote: return device.name == "BlackHole 2ch"
            // Input channels already exclude speakers; the microphone name is localized by macOS.
            case .you: return device.name.contains("MacBook")
            }
        }
        guard matches.count == 1, let device = matches.first else {
            let requested = name ?? (source == .remote ? "BlackHole 2ch" : "MacBook microphone")
            throw MeetingError("Required input device '\(requested)' \(matches.isEmpty ? "was not found" : "is ambiguous"). Available inputs:\n" + inputs.map { "- \($0.name) [\($0.id)]" }.joined(separator: "\n"))
        }
        return device
    }
}
