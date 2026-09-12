import AVFoundation

// Owned by one capture-consumer task. A converter is kept for the entire stream,
// preserving filter state and fractional sample counts across native-rate callbacks.
final class AudioResampler {
    // AVAudioConverter invokes its pull callback synchronously during convert().
    // This owner is confined to that one conversion; its PCM buffer is immutable.
    private final class InputPacket: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let channels: Int
    private var origin: Double?
    private var outputSamples = 0
    private var inputFrames = 0

    init(device: AudioDevice) throws {
        channels = device.inputChannels
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: device.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw MeetingError("Cannot create 16 kHz PCM converter for \(device.name)")
        }
        inputFormat = input; outputFormat = output; self.converter = converter
        converter.primeMethod = .none
    }

    func convert(_ packet: CapturedAudio, time: Double) throws -> (samples: [Float], start: Double) {
        if origin == nil { origin = time }
        let expectedTime = origin! + Double(inputFrames) / inputFormat.sampleRate
        guard abs(expectedTime - time) < 0.1 else { throw MeetingError("Audio clock drift/discontinuity exceeds 100 ms") }
        inputFrames += packet.frames
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: UInt32(packet.frames)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                frameCapacity: UInt32(ceil(Double(packet.frames) * 16000 / inputFormat.sampleRate)) + 128) else {
            throw MeetingError("Cannot allocate PCM conversion buffer")
        }
        input.frameLength = UInt32(packet.frames)
        let mono = input.floatChannelData![0]
        for frame in 0..<packet.frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += packet.samples[frame * channels + channel] }
            mono[frame] = sum / Float(channels)
        }
        // WhisperKit's resampleBuffer helper can return the same buffer more than once
        // to the converter. Streaming must supply each packet exactly once and use
        // inputRanDry (not endOfStream) between callbacks, hence this native conversion.
        let packetInput = InputPacket(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if packetInput.supplied { status.pointee = .noDataNow; return nil }
            packetInput.supplied = true
            status.pointee = .haveData
            return packetInput.buffer
        }
        if status == .error { throw MeetingError("PCM resampling failed: \(error?.localizedDescription ?? "unknown error")") }
        let start = origin! + Double(outputSamples) / 16000
        outputSamples += Int(output.frameLength)
        return (Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))), start)
    }
}
