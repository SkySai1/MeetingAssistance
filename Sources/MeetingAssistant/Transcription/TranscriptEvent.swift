import Foundation

public struct TranscriptEvent: Codable, Sendable, Equatable {
    public let source: AudioSource
    public let startTime: Double
    public let endTime: Double
    public let text: String
}

// A source frontier is the earliest time at which it can still produce an event.
// Holding events behind BOTH frontiers guarantees chronological output even when
// one decoder is slower or one source stays silent. Full transcript is never retained.
actor TranscriptTimeline {
    private var frontiers: [AudioSource: Double]
    private var pending: [TranscriptEvent] = []
    private var lastEmitted = -Double.infinity
    private let output: @Sendable (TranscriptEvent) throws -> Void
    private(set) var emittedCount = 0

    init(sources: [AudioSource], output: @escaping @Sendable (TranscriptEvent) throws -> Void) {
        frontiers = Dictionary(uniqueKeysWithValues: sources.map { ($0, 0) })
        self.output = output
    }

    func update(source: AudioSource, events: [TranscriptEvent] = [], frontier: Double) throws {
        guard let previous = frontiers[source], frontier >= previous else { throw MeetingError("\(source.rawValue): transcript frontier moved backwards") }
        for event in events {
            guard event.source == source, event.startTime.isFinite, event.endTime.isFinite,
                  event.startTime >= previous - 0.001, event.endTime >= event.startTime else {
                throw MeetingError("Invalid transcript event or event behind committed frontier")
            }
        }
        pending.append(contentsOf: events)
        guard pending.count <= 1024 else { throw MeetingError("Transcript ordering buffer exceeded 1024 events; a source is stalled") }
        frontiers[source] = frontier
        let safeTime = frontiers.values.min() ?? .infinity
        pending.sort { $0.startTime == $1.startTime ? $0.source.rawValue < $1.source.rawValue : $0.startTime < $1.startTime }
        while let event = pending.first, event.startTime < safeTime {
            guard event.startTime >= lastEmitted else { throw MeetingError("Transcript chronology violation") }
            try output(event)
            lastEmitted = event.startTime
            emittedCount += 1
            pending.removeFirst()
        }
    }
}
