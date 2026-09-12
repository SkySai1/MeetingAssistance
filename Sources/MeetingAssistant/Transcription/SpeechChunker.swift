import Foundation

struct SpeechChunk: Sendable {
    let samples: [Float]
    let start: Double
    let isFinal: Bool
    var end: Double { start + Double(samples.count) / 16000 }
}

// Energy endpointing on 20 ms frames; this is a configurable speech gate, not diarization.
// Long speech uses 12 s windows with 2 s context overlap. The decoder confirms only
// words ending at least 1 s before a non-final window's edge.
struct SpeechChunker: Sendable {
    let threshold: Float
    private var remainder: [Float] = []
    private var remainderStart = 0.0
    private var audio: [Float] = []
    private var audioStart = 0.0
    private var active = false
    private var silenceFrames = 0
    private var voiceFrames = 0
    private(set) var endTime = 0.0
    private let frameSize = 320
    private let preRoll = 4800
    private let maxSamples = 192000
    private let overlap = 32000

    init(thresholdDB: Double) { threshold = Float(pow(10, thresholdDB / 20)) }
    var frontier: Double { audio.isEmpty ? (remainder.isEmpty ? endTime : remainderStart) : audioStart }

    mutating func append(_ samples: [Float], start: Double) -> [SpeechChunk] {
        guard !samples.isEmpty else { return [] }
        if remainder.isEmpty { remainderStart = start }
        remainder.append(contentsOf: samples)
        endTime = start + Double(samples.count) / 16000
        var chunks: [SpeechChunk] = []
        var offset = 0
        while remainder.count - offset >= frameSize {
            let frame = remainder[offset..<(offset + frameSize)]
            let time = remainderStart + Double(offset) / 16000
            let rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frameSize))
            let voiced = rms >= threshold
            if audio.isEmpty { audioStart = time }
            audio.append(contentsOf: frame)
            if voiced { active = true; silenceFrames = 0; voiceFrames += 1 }
            else if active { silenceFrames += 1 }

            if active && silenceFrames >= 35 {
                if voiceFrames >= 10 { chunks.append(SpeechChunk(samples: audio, start: audioStart, isFinal: true)) }
                audio.removeAll(keepingCapacity: true)
                active = false; silenceFrames = 0; voiceFrames = 0
            } else if active && audio.count >= maxSamples {
                chunks.append(SpeechChunk(samples: audio, start: audioStart, isFinal: false))
                audioStart += Double(audio.count - overlap) / 16000
                audio = Array(audio.suffix(overlap))
                voiceFrames = 10
            } else if !active && audio.count > preRoll {
                let remove = audio.count - preRoll
                audio.removeFirst(remove)
                audioStart += Double(remove) / 16000
            }
            offset += frameSize
        }
        remainder.removeFirst(offset)
        remainderStart += Double(offset) / 16000
        return chunks
    }

    mutating func finish() -> SpeechChunk? {
        audio.append(contentsOf: remainder)
        let result = active && voiceFrames >= 10 ? SpeechChunk(samples: audio, start: audioStart, isFinal: true) : nil
        audio.removeAll(); remainder.removeAll(); active = false
        return result
    }
}
