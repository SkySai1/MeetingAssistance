import Foundation

struct SpeechChunk: Sendable {
    let samples: [Float]
    let start: Double
    let isFinal: Bool
    var end: Double { start + Double(samples.count) / 16000 }
}

// Energy endpointing on 20 ms frames; this is a configurable speech gate, not diarization.
// After 4 s, a 200 ms pause ends a phrase before a forced split can cut a word.
// Short utterances retain a 700 ms hangover to keep nearby words together.
// Uninterrupted speech uses 12 s windows with 2 s context overlap. The decoder confirms only
// words ending at least 1 s before a non-final window's edge.
struct SpeechChunker: Sendable {
    let threshold: Float
    private var remainder: [Float] = []
    private var origin: Double?
    private var receivedSamples = 0
    private var audio: [Float] = []
    private var audioStartSample = 0
    private var active = false
    private var silenceFrames = 0
    private var voiceFrames = 0
    var endTime: Double { time(at: receivedSamples) }
    private let frameSize = 320
    private let preRoll = 4800
    private let maxSamples = 192000
    private let overlap = 32000

    init(thresholdDB: Double) { threshold = Float(pow(10, thresholdDB / 20)) }
    // All boundaries use the same origin and integer sample offsets. Adding
    // packet durations to Doubles can otherwise move a silence frontier back by
    // one ULP when the speech gate clears its buffer after a short noise burst.
    private func time(at sample: Int) -> Double { (origin ?? 0) + Double(sample) / 16000 }
    var frontier: Double { time(at: audio.isEmpty ? receivedSamples - remainder.count : audioStartSample) }
    var diagnosticState: String {
        "origin=\(origin ?? 0), receivedSamples=\(receivedSamples), audioStartSample=\(audioStartSample), audioSamples=\(audio.count), remainderSamples=\(remainder.count), active=\(active), voiceFrames=\(voiceFrames), silenceFrames=\(silenceFrames)"
    }

    mutating func append(_ samples: [Float], start: Double) throws -> [SpeechChunk] {
        guard !samples.isEmpty else { return [] }
        guard start.isFinite, origin == nil || abs(start - endTime) < 1.0 / 16000 else {
            throw MeetingError("Chunker input discontinuity: expected=\(endTime), received=\(start), delta=\(start - endTime), samples=\(samples.count)")
        }
        if origin == nil { origin = start }
        receivedSamples += samples.count
        remainder.append(contentsOf: samples)
        let remainderStartSample = receivedSamples - remainder.count
        var chunks: [SpeechChunk] = []
        var offset = 0
        while remainder.count - offset >= frameSize {
            let frame = remainder[offset..<(offset + frameSize)]
            let frameStartSample = remainderStartSample + offset
            let rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frameSize))
            let voiced = rms >= threshold
            if audio.isEmpty { audioStartSample = frameStartSample }
            audio.append(contentsOf: frame)
            if voiced { active = true; silenceFrames = 0; voiceFrames += 1 }
            else if active { silenceFrames += 1 }

            if active && (silenceFrames >= 35 || (audio.count >= 64000 && silenceFrames >= 10)) {
                if voiceFrames >= 10 { chunks.append(SpeechChunk(samples: audio, start: time(at: audioStartSample), isFinal: true)) }
                audio.removeAll(keepingCapacity: true)
                active = false; silenceFrames = 0; voiceFrames = 0
            } else if active && audio.count >= maxSamples {
                chunks.append(SpeechChunk(samples: audio, start: time(at: audioStartSample), isFinal: false))
                audioStartSample += audio.count - overlap
                audio = Array(audio.suffix(overlap))
                voiceFrames = 10
            } else if !active && audio.count > preRoll {
                let remove = audio.count - preRoll
                audio.removeFirst(remove)
                audioStartSample += remove
            }
            offset += frameSize
        }
        remainder.removeFirst(offset)
        return chunks
    }

    mutating func finish() -> SpeechChunk? {
        audio.append(contentsOf: remainder)
        let result = active && voiceFrames >= 10 ? SpeechChunk(samples: audio, start: time(at: audioStartSample), isFinal: true) : nil
        audio.removeAll(); remainder.removeAll(); active = false
        return result
    }
}
