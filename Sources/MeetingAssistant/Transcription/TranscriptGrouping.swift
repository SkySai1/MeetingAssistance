import Foundation

public struct TranscriptDisplayConfiguration: Codable, Sendable, Equatable {
    public var enabled = true
    public var maximumPause = 1.2
    public var maximumDuration = 30.0
    public init() { }

    public func validate() throws {
        guard maximumPause.isFinite, (0.2...3).contains(maximumPause),
              maximumDuration.isFinite, (5...120).contains(maximumDuration) else {
            throw MeetingError("Пауза объединения должна быть от 0,2 до 3 с, интервал карточки — от 5 до 120 с.")
        }
    }
}

/// A display projection. Every original event, ID and timestamp stays available.
public struct TranscriptGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let source: AudioSource
    public let speakerLabel: String
    public let startTime: Double
    public private(set) var endTime: Double
    public private(set) var events: [TranscriptEvent]
    public private(set) var text: String

    fileprivate init(_ event: TranscriptEvent) {
        id = event.id; source = event.source; speakerLabel = event.speakerLabel
        startTime = event.startTime; endTime = event.endTime
        events = [event]; text = event.text
    }

    fileprivate mutating func append(_ event: TranscriptEvent) {
        // Only insert whitespace at the boundary. Never remove repeated words or
        // edit the original fragments to make them look like a single ASR event.
        if !text.isEmpty, !event.text.isEmpty, text.last?.isWhitespace != true, event.text.first?.isWhitespace != true { text += " " }
        text += event.text
        events.append(event)
        endTime = max(endTime, event.endTime)
    }
}

/// Incremental grouping of the already ordered, annotated transcript. The first
/// event is published immediately; no wall-clock timer or additional ASR buffer.
public struct TranscriptGrouping: Sendable {
    public let configuration: TranscriptDisplayConfiguration
    public private(set) var groups: [TranscriptGroup] = []
    private var eventGroups: [String: String] = [:]

    public init(configuration: TranscriptDisplayConfiguration = TranscriptDisplayConfiguration()) {
        self.configuration = configuration
    }

    public func groupID(for eventID: String) -> String? { eventGroups[eventID] }

    /// Duplicate delivery is ignored by identity, never by text similarity.
    @discardableResult public mutating func append(_ event: TranscriptEvent) -> Bool {
        guard eventGroups[event.id] == nil else { return false }
        if let last = groups.last, canAppend(event, to: last) {
            eventGroups[event.id] = last.id
            groups[groups.count - 1].append(event)
        } else {
            eventGroups[event.id] = event.id
            groups.append(TranscriptGroup(event))
        }
        return true
    }

    private enum SpeakerKey: Equatable { case localMicrophone, diarized(String) }
    private func speakerKey(_ event: TranscriptEvent) -> SpeakerKey? {
        guard let speakers = event.speakerIDs else {
            return event.source == .you ? .localMicrophone : nil
        }
        guard speakers.count == 1 else { return nil }
        return .diarized(speakers[0])
    }

    private func canAppend(_ event: TranscriptEvent, to group: TranscriptGroup) -> Bool {
        guard configuration.enabled, event.source == group.source,
              let previous = group.events.last, let speaker = speakerKey(event), speaker == speakerKey(previous),
              event.startTime.isFinite, event.endTime.isFinite,
              event.startTime >= previous.startTime, event.endTime >= event.startTime else { return false }
        let gap = event.startTime - previous.endTime
        return gap >= -0.001 && gap <= configuration.maximumPause + 0.001
            && event.endTime - group.startTime <= configuration.maximumDuration + 0.001
    }
}
