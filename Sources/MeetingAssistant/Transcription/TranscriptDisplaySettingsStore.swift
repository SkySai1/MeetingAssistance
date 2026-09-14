import Foundation

public struct TranscriptDisplaySettingsStore: Sendable {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".meetingassistant", isDirectory: true)) {
        self.directory = directory
    }
    private var file: URL { directory.appendingPathComponent("transcript-display.json") }

    public func load() throws -> TranscriptDisplayConfiguration {
        guard FileManager.default.fileExists(atPath: file.path) else { return TranscriptDisplayConfiguration() }
        let data = try Data(contentsOf: file)
        guard data.count <= 65536 else { throw MeetingError("Файл настроек транскрипта превышает 64 КиБ.") }
        let configuration = try JSONDecoder().decode(TranscriptDisplayConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    public func save(_ configuration: TranscriptDisplayConfiguration) throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
