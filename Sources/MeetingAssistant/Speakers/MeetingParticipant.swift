import Foundation

/// Anonymous, source-local voices observed in this meeting, not identity profiles.
public struct MeetingParticipant: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let source: AudioSource
    public var firstHeard: Double
    public var lastHeard: Double
    public var speechDuration: Double
}

public struct MeetingParticipantLedger: Sendable {
    private var entries: [String: MeetingParticipant] = [:]
    public init() { }
    public var participants: [MeetingParticipant] {
        entries.values.sorted { $0.firstHeard == $1.firstHeard ? $0.id < $1.id : $0.firstHeard < $1.firstHeard }
    }
    /// Input is chronological committed activity; repeated frames do not add duration.
    public mutating func record(id: String, source: AudioSource, start: Double, end: Double) {
        guard start.isFinite, end.isFinite, end > start else { return }
        var entry = entries[id] ?? MeetingParticipant(id: id, source: source, firstHeard: start, lastHeard: start, speechDuration: 0)
        entry.speechDuration += max(0, end - max(start, entry.lastHeard))
        entry.firstHeard = min(entry.firstHeard, start)
        entry.lastHeard = max(entry.lastHeard, end)
        entries[id] = entry
    }
    /// GUI mailboxes may coalesce cumulative snapshots; never add them twice.
    public mutating func merge(_ snapshot: [MeetingParticipant]) {
        for var entry in snapshot {
            if let old = entries[entry.id] {
                entry.firstHeard = min(old.firstHeard, entry.firstHeard)
                entry.lastHeard = max(old.lastHeard, entry.lastHeard)
                entry.speechDuration = max(old.speechDuration, entry.speechDuration)
            }
            entries[entry.id] = entry
        }
    }
}
