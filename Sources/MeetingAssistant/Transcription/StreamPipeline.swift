import Foundation

actor StreamPipeline {
    let source: AudioSource
    private let timeline: TranscriptTimeline
    private var chunker: SpeechChunker
    private var queue: [SpeechChunk] = []
    private var inFlight: SpeechChunk?
    private var queuedSamples = 0
    private var finished = false
    private var warned = false
    private var confirmedThrough = 0.0
    private(set) var decodedChunks = 0
    private(set) var maxLag = 0.0

    init(source: AudioSource, thresholdDB: Double, timeline: TranscriptTimeline) {
        self.source = source; self.timeline = timeline
        chunker = SpeechChunker(thresholdDB: thresholdDB)
    }

    private var frontier: Double {
        max(confirmedThrough, min(inFlight?.start ?? .infinity, queue.first?.start ?? .infinity, finished ? .infinity : chunker.frontier))
    }

    func ingest(_ samples: [Float], start: Double) async throws {
        for chunk in chunker.append(samples, start: start) { try enqueue(chunk) }
        try await timeline.update(source: source, frontier: frontier)
    }

    private func enqueue(_ chunk: SpeechChunk) throws {
        queuedSamples += chunk.samples.count
        guard queuedSamples <= 60 * 16000 else { throw MeetingError("\(source.rawValue): ASR backlog exceeded 60 seconds; stopping without silently dropping audio") }
        queue.append(chunk)
        if queuedSamples > 24 * 16000 && !warned {
            Log.warning("\(source.rawValue) ASR queue exceeds 24 seconds")
            warned = true
        }
    }

    func next() -> SpeechChunk? {
        guard inFlight == nil, !queue.isEmpty else { return nil }
        let chunk = queue.removeFirst()
        queuedSamples -= chunk.samples.count
        inFlight = chunk
        if queuedSamples < 12 * 16000 { warned = false }
        return chunk
    }

    func complete(_ events: [TranscriptEvent], lag: Double) async throws {
        guard inFlight != nil else { throw MeetingError("ASR completed without an active chunk") }
        inFlight = nil; decodedChunks += 1; maxLag = max(maxLag, lag)
        // The finalizer never emits before its last confirmed end, even if the
        // next window retains older context. Do not delay output for that overlap.
        confirmedThrough = max(confirmedThrough, events.last?.endTime ?? 0)
        try await timeline.update(source: source, events: events, frontier: frontier)
    }

    func finish() async throws {
        if let tail = chunker.finish() { try enqueue(tail) }
        finished = true
        try await timeline.update(source: source, frontier: frontier)
    }

    var isDrained: Bool { finished && queue.isEmpty && inFlight == nil }
    var backlogSeconds: Double { Double(queuedSamples + (inFlight?.samples.count ?? 0)) / 16000 }
}
