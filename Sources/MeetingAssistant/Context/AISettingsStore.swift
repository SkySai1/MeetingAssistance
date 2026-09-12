import Foundation

public struct AISettingsDocument: Codable, Sendable {
    public var enabled: Bool
    public var configuration: AIConfiguration
    public init(enabled: Bool = false, configuration: AIConfiguration = AIConfiguration()) {
        self.enabled = enabled; self.configuration = configuration
    }
}

/// Human-editable files in the user's private directory. The prompt is a separate
/// UTF-8 file; JSON stores the connection, model, and limits without a second copy.
public struct AISettingsStore: Sendable {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".meetingassistant", isDirectory: true)) {
        self.directory = directory
    }
    public func load() throws -> AISettingsDocument? {
        let path = directory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        guard data.count <= 65536 else { throw MeetingError("Файл настроек превышает 64 КиБ.") }
        var result = try JSONDecoder().decode(AISettingsDocument.self, from: data)
        let prompt = directory.appendingPathComponent("system-prompt.txt")
        if FileManager.default.fileExists(atPath: prompt.path) {
            let data = try Data(contentsOf: prompt)
            guard data.count <= 4000, let text = String(data: data, encoding: .utf8) else { throw MeetingError("Системный промпт должен быть UTF-8, не более 4000 байт.") }
            result.configuration.systemPrompt = text
        }
        return result
    }
    public func save(_ document: AISettingsDocument) throws {
        guard document.configuration.systemPrompt.utf8.count <= 4000 else { throw MeetingError("Системный промпт слишком длинный; сократите его перед сохранением.") }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any]
        var configuration = object["configuration"] as! [String: Any]
        configuration.removeValue(forKey: "systemPrompt")
        object["configuration"] = configuration
        let settings = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        for (name, data) in [("system-prompt.txt", Data(document.configuration.systemPrompt.utf8)), ("settings.json", settings)] {
            let file = directory.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
