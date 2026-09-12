import AudioToolbox
import AVFoundation
import Foundation
import Synchronization

struct CapturedAudio: Sendable {
    let samples: [Float] // Native-rate interleaved PCM, retained separately for each source.
    let hostTime: UInt64
    let sampleTime: Double
    let frames: Int
}

// Single producer (AUHAL callback), single consumer (capture task). Slots are published
// with release/acquire ordering. No allocation, locks, logging or inference in the callback.
final class CaptureRing: @unchecked Sendable {
    private struct Slot {
        let samples: UnsafeMutablePointer<Float>
        var hostTime: UInt64 = 0
        var sampleTime: Double = 0
        var frames: Int = 0
    }
    private let slots: UnsafeMutablePointer<Slot>
    private let capacity = 512
    let maxFrames = 4096
    let channels: Int
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)
    let failure = Atomic<Int32>(0)

    init(channels: Int) {
        self.channels = channels
        slots = .allocate(capacity: capacity)
        for index in 0..<capacity {
            slots.advanced(by: index).initialize(to: Slot(samples: .allocate(capacity: maxFrames * channels)))
        }
    }

    deinit {
        for index in 0..<capacity { slots[index].samples.deallocate() }
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    func render(unit: AudioUnit, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timestamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard failure.load(ordering: .relaxed) == 0 else { return noErr }
        guard frames <= maxFrames else { failure.store(-1, ordering: .releasing); return noErr }
        let write = writeIndex.load(ordering: .relaxed)
        guard write - readIndex.load(ordering: .acquiring) < capacity else {
            failure.store(-2, ordering: .releasing)
            return noErr
        }
        guard timestamp.pointee.mFlags.contains(.hostTimeValid), timestamp.pointee.mFlags.contains(.sampleTimeValid) else {
            failure.store(-3, ordering: .releasing)
            return noErr
        }
        let slot = slots.advanced(by: write % capacity)
        var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(channels), mDataByteSize: frames * UInt32(channels * MemoryLayout<Float>.size), mData: slot.pointee.samples))
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, &buffers)
        guard status == noErr else { failure.store(status, ordering: .releasing); return status }
        slot.pointee.hostTime = timestamp.pointee.mHostTime
        slot.pointee.sampleTime = timestamp.pointee.mSampleTime
        slot.pointee.frames = Int(frames)
        writeIndex.store(write + 1, ordering: .releasing)
        return noErr
    }

    func pop() throws -> CapturedAudio? {
        let status = failure.load(ordering: .acquiring)
        guard status == 0 else {
            let detail: String
            switch status {
            case -1: detail = "callback exceeded the preallocated frame limit"
            case -2: detail = "capture buffer overflow; processing cannot keep up"
            case -3: detail = "device did not supply monotonic audio timestamps"
            default: detail = "AudioUnitRender OSStatus \(status)"
            }
            throw MeetingError(detail)
        }
        let read = readIndex.load(ordering: .relaxed)
        guard read < writeIndex.load(ordering: .acquiring) else { return nil }
        let slot = slots[read % capacity]
        let packet = CapturedAudio(samples: Array(UnsafeBufferPointer(start: slot.samples, count: slot.frames * channels)),
                                   hostTime: slot.hostTime, sampleTime: slot.sampleTime, frames: slot.frames)
        readIndex.store(read + 1, ordering: .releasing)
        return packet
    }
}

// The session owns start/stop. The callback only accesses the initialized unit and ring;
// stopping AUHAL joins its callback before the instance and ring may be destroyed.
final class AudioCapture: @unchecked Sendable {
    let source: AudioSource
    let device: AudioDevice
    let ring: CaptureRing
    private var unit: AudioUnit?

    init(source: AudioSource, device: AudioDevice) throws {
        self.source = source
        self.device = device
        ring = CaptureRing(channels: device.inputChannels)
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw MeetingError("AUHAL is unavailable") }
        var instance: AudioUnit?
        try checkAudio(AudioComponentInstanceNew(component, &instance), "Create AUHAL for \(source.rawValue)")
        guard let instance else { throw MeetingError("AUHAL did not return an instance") }
        unit = instance
        do {
            var enabled: UInt32 = 1
            var disabled: UInt32 = 0
            try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, bus: 1, value: &enabled)
            try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, bus: 0, value: &disabled)
            var deviceID = device.id
            try set(kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, bus: 0, value: &deviceID)
            // AUHAL performs only PCM format conversion. Hardware sample rate is never changed.
            var format = AudioStreamBasicDescription(mSampleRate: device.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * device.inputChannels), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * device.inputChannels), mChannelsPerFrame: UInt32(device.inputChannels),
                mBitsPerChannel: 32, mReserved: 0)
            try set(kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, bus: 1, value: &format)
            var maxFrames = UInt32(ring.maxFrames)
            try set(kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, bus: 0, value: &maxFrames)
            var callback = AURenderCallbackStruct(inputProc: { context, flags, time, _, frames, _ in
                let capture = Unmanaged<AudioCapture>.fromOpaque(context).takeUnretainedValue()
                guard let unit = capture.unit else { return noErr }
                return capture.ring.render(unit: unit, flags: flags, timestamp: time, frames: frames)
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try set(kAudioOutputUnitProperty_SetInputCallback, scope: kAudioUnitScope_Global, bus: 0, value: &callback)
            try checkAudio(AudioUnitInitialize(instance), "Initialize \(source.rawValue)")
        } catch {
            AudioComponentInstanceDispose(instance)
            unit = nil
            throw error
        }
    }

    private func set<T>(_ property: AudioUnitPropertyID, scope: AudioUnitScope, bus: AudioUnitElement, value: inout T) throws {
        guard let unit else { throw MeetingError("Audio unit is closed") }
        try withUnsafePointer(to: &value) { pointer in
            try checkAudio(AudioUnitSetProperty(unit, property, scope, bus, pointer, UInt32(MemoryLayout<T>.size)),
                           "\(source.rawValue) set audio property \(property)")
        }
    }

    func start() throws {
        guard let unit else { throw MeetingError("Audio unit is closed") }
        try checkAudio(AudioOutputUnitStart(unit), "Start \(source.rawValue)")
    }

    func stop() { if let unit { AudioOutputUnitStop(unit) } }

    deinit {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }
}
