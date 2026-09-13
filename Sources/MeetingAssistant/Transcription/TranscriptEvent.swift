import Foundation

public struct TranscriptEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let source: AudioSource
    public let startTime: Double
    public let endTime: Double
    public let text: String
    public let speakerSpans: [SpeakerSpan]?
    public var speakerIDs: [String]? { speakerSpans.map { Array(Set($0.map(\.speakerID))).sorted() } }
    public var speakerLabel: String {
        guard let speakerIDs else { return source.rawValue }
        return speakerIDs.isEmpty ? "\(source.rawValue) · Unknown" : speakerIDs.joined(separator: ", ")
    }

    public init(id: String = UUID().uuidString, source: AudioSource, startTime: Double, endTime: Double, text: String, speakerSpans: [SpeakerSpan]? = nil) {
        self.id = id; self.source = source
        self.startTime = startTime; self.endTime = endTime; self.text = text
        self.speakerSpans = speakerSpans
    }

    private enum CodingKeys: String, CodingKey { case id, source, startTime, endTime, text, speakerSpans }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        source = try values.decode(AudioSource.self, forKey: .source)
        startTime = try values.decode(Double.self, forKey: .startTime)
        endTime = try values.decode(Double.self, forKey: .endTime)
        text = try values.decode(String.self, forKey: .text)
        speakerSpans = try values.decodeIfPresent([SpeakerSpan].self, forKey: .speakerSpans)
    }
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
