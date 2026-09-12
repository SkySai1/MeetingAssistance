import Foundation

struct RecognizedWord: Sendable {
    let text: String
    let start: Double
    let end: Double
    var normalized: String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
}

struct TranscriptFinalizer: Sendable {
    let source: AudioSource
    private var history: [RecognizedWord] = [] // At most 64 words, with meeting-relative times.
    private var confirmedEnd = -Double.infinity

    init(source: AudioSource) { self.source = source }

    mutating func finalize(_ segments: [[RecognizedWord]], chunk: SpeechChunk) throws -> [TranscriptEvent] {
        let words = segments.enumerated().flatMap { segment, words in words.map { (segment, $0) } }
        guard words.allSatisfy({ _, word in word.start.isFinite && word.end.isFinite && word.start >= 0 && word.end >= word.start }) else {
            throw MeetingError("\(source.rawValue): WhisperKit returned invalid word timestamps")
        }
        var skip = 0
        var bestMatch = 0
        var bestDistance = Double.infinity
        if chunk.start < confirmedEnd, !words.isEmpty {
            // Alignment can move a boundary word by several hundred milliseconds.
            // Match already confirmed context before applying a time cutoff; merely
            // discarding everything before the previous end loses adjacent new words.
            for prefixEnd in 1...min(words.count, 32) {
                let distance = abs(chunk.start + words[prefixEnd - 1].1.end - confirmedEnd)
                guard distance < 1.2 else { continue }
                for length in stride(from: min(prefixEnd, history.count), through: 1, by: -1) {
                    let candidate = words[(prefixEnd - length)..<prefixEnd].map { $0.1.normalized }
                    guard !candidate.contains(""), candidate == history.suffix(length).map(\.normalized),
                          chunk.start + words[prefixEnd - length].1.start < confirmedEnd else { continue }
                    if length > bestMatch || (length == bestMatch && distance < bestDistance) {
                        bestMatch = length; bestDistance = distance; skip = prefixEnd
                    }
                    break
                }
            }
            if bestMatch == 0 {
                skip = words.prefix { chunk.start + $0.1.end <= confirmedEnd }.count
            }
        }
        let safeEnd = chunk.isFinal ? chunk.end : chunk.end - 1
        var accepted: [(Int, RecognizedWord)] = []
        for (segment, word) in words.dropFirst(skip) {
            let start = chunk.start + word.start
            let end = chunk.start + word.end
            // Confirm a prefix only. The remaining trailing words belong to the
            // next overlapping window, where they have sufficient right context.
            if end > safeEnd + 0.001 || start > safeEnd { break }
            accepted.append((segment, RecognizedWord(text: word.text, start: start, end: end)))
        }
        var events: [TranscriptEvent] = []
        var offset = 0
        while offset < accepted.count {
            let segment = accepted[offset].0
            let group = accepted[offset...].prefix { $0.0 == segment }.map(\.1)
            offset += group.count
            let text = group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let first = group.first, let last = group.last else { continue }
            let start = max(0, confirmedEnd, first.start)
            let end = max(start, min(chunk.end, last.end))
            events.append(TranscriptEvent(source: source, startTime: start, endTime: end, text: text))
            confirmedEnd = end
            history.append(contentsOf: group.filter { !$0.normalized.isEmpty })
            history = Array(history.suffix(64))
        }
        return events
    }
}
