import AVFoundation

struct MeetingClock: Sendable {
    private let origin = mach_absolute_time()
    func seconds(at hostTime: UInt64) -> Double {
        hostTime >= origin ? AVAudioTime.seconds(forHostTime: hostTime - origin) : -AVAudioTime.seconds(forHostTime: origin - hostTime)
    }
    var now: Double { seconds(at: mach_absolute_time()) }
}
