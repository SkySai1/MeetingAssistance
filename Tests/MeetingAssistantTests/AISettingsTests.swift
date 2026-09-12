import Foundation
import Testing
@testable import MeetingAssistantCore
@testable import MeetingAssistantApp

@Test func settingsAndPromptRoundTripThroughPrivateUserDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISettingsStore(directory: directory)
    #expect(try store.load() == nil)
    var configuration = AIConfiguration()
    configuration.model = "test:latest"
    configuration.summaryCharacterLimit = 250
    configuration.factLimit = 7
    configuration.systemPrompt = "Кратко, с акцентом на решения."
    try store.save(AISettingsDocument(enabled: true, configuration: configuration))
    let loaded = try #require(try store.load())
    #expect(loaded.enabled && loaded.configuration == configuration)
    let settings = try String(contentsOf: directory.appendingPathComponent("settings.json"), encoding: .utf8)
    #expect(!settings.contains("systemPrompt") && settings.contains("summaryCharacterLimit"))
    try "Промпт изменён в файле".write(to: directory.appendingPathComponent("system-prompt.txt"), atomically: true, encoding: .utf8)
    #expect(try store.load()?.configuration.systemPrompt == "Промпт изменён в файле")
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("settings.json").path)[.posixPermissions] as? Int == 0o600)
}

@Test @MainActor func settingsMigrationPreservesCustomPromptAndReloadsNewLimits() throws {
    let suite = UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    var old = AIConfiguration(); old.systemPrompt = "Мой прежний промпт"; old.model = "test"
    preferences.set(try JSONEncoder().encode(old), forKey: "aiConfiguration")
    preferences.set(true, forKey: "aiEnabled")
    let store = AISettingsStore(directory: directory)
    let first = AISettingsViewModel(preferences: preferences, store: store)
    #expect(first.enabled && first.configuration.systemPrompt == old.systemPrompt)
    first.configuration.summaryCharacterLimit = 300
    first.configuration.factLimit = 4
    let restarted = AISettingsViewModel(preferences: preferences, store: store)
    #expect(restarted.configuration.summaryCharacterLimit == 300 && restarted.configuration.factLimit == 4)
    #expect(restarted.storageError == nil)
}
