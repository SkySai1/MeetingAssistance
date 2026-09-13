import Foundation

/// Retains only the recent 120 seconds, enough for the bounded ASR backlog.
/// Uses committed model frames; never assigns a real person's name.
struct SpeakerActivityWindow: Sendable {
    let source: AudioSource
    private var spans: [Int: [SpeakerSpan]] = [:]
    private var candidates: [Int: SpeakerSpan] = [:]
    private(set) var processedThrough = 0.0
    private(set) var detected: Set<Int> = []
    private(set) var ledger = MeetingParticipantLedger()
    init(source: AudioSource) { self.source = source }

    mutating func ingest(_ predictions: [Float], frameStart: Int, frameDuration: Double, speakers: Int, origin: Double, audioEnd: Double = .infinity) throws {
        guard speakers > 0, predictions.count % speakers == 0, frameDuration > 0 else { throw MeetingError("Некорректные кадры диаризации.") }
        let frames = predictions.count / speakers
        for speaker in 0..<speakers {
            var track = spans[speaker] ?? []
            for frame in 0..<frames {
                guard predictions[frame * speakers + speaker] >= 0.5 else {
                    candidates[speaker] = nil
                    continue
                }
                let start = origin + Double(frameStart + frame) * frameDuration
                let end = min(start + frameDuration, audioEnd)
                guard end > start else { continue }
                var candidate = candidates[speaker] ?? SpeakerSpan(speakerID: "\(source.rawValue)_speaker_\(speaker + 1)", startTime: start, endTime: start)
                if abs(candidate.endTime - start) >= frameDuration * 0.01 { candidate.startTime = start }
                candidate.endTime = end
                candidates[speaker] = candidate
                // Require sustained activity before confirming a segment. Raw
                // one/two-frame spikes otherwise create phantom participants and
                // overlapping labels. Preserve its original onset when confirmed.
                guard end - candidate.startTime >= 0.25 else { continue }
                ledger.record(id: candidate.speakerID, source: source, start: candidate.startTime, end: end)
                if let previous = track.last, abs(previous.startTime - candidate.startTime) < frameDuration * 0.01 {
                    track[track.count - 1].endTime = end
                } else { track.append(candidate) }
                detected.insert(speaker)
            }
            spans[speaker] = track
        }
        processedThrough = origin + Double(frameStart + frames) * frameDuration
        let cutoff = processedThrough - 120
        for speaker in spans.keys { spans[speaker]?.removeAll { $0.endTime < cutoff } }
    }

    func annotate(_ event: TranscriptEvent) -> TranscriptEvent {
        guard event.source == source, event.startTime >= processedThrough - 120 else {
            return TranscriptEvent(id: event.id, source: event.source, startTime: event.startTime, endTime: event.endTime, text: event.text, speakerSpans: [])
        }
        let minimum = min(0.15, max(0, event.endTime - event.startTime) / 2)
        let relevant = spans.values.flatMap { $0 }.compactMap { span -> SpeakerSpan? in
            let start = max(event.startTime, span.startTime), end = min(event.endTime, span.endTime)
            guard end > start, end - start >= minimum else { return nil }
            return SpeakerSpan(speakerID: span.speakerID, startTime: start, endTime: end)
        }.sorted { $0.startTime == $1.startTime ? $0.speakerID < $1.speakerID : $0.startTime < $1.startTime }
        return TranscriptEvent(id: event.id, source: event.source, startTime: event.startTime, endTime: event.endTime, text: event.text, speakerSpans: relevant)
    }
}
