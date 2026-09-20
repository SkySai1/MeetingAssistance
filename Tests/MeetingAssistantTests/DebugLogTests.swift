import Foundation
import Synchronization
import Testing
@testable import MeetingAssistantCore
@testable import MeetingAssistant

private func debugTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDebugTests-" + UUID().uuidString)
}

@Test func debugLogSerializesConcurrentRecordsAndFlushesAllLevels() async throws {
    let directory = debugTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let errors = Mutex<[String]>([])
    let log = MeetingDebugLog(directory: directory) { message in errors.withLock { $0.append(message) } }
    log.start()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<120 {
            group.addTask { log.record(LogLevel.allCases[index % 4], "record=\(index) Тест\nвторая строка") }
        }
    }
    log.record(.debug, String(repeating: "Я", count: 10000))
    await log.close()
    log.record(.error, "after-close")
    let text = try String(contentsOf: log.fileURL, encoding: .utf8)
    let lines = text.split(separator: "\n")
    #expect(lines.count == 122)
    #expect(lines.last?.contains("[truncated]") == true)
    #expect((lines.last?.count ?? 0) < 8300)
    for index in 0..<120 { #expect(lines.filter { $0.contains("record=\(index) ") }.count == 1) }
    for level in LogLevel.allCases { #expect(text.contains("[\(level.rawValue)]")) }
    #expect(text.contains("Тест\\nвторая строка"))
    #expect(!text.contains("after-close"))
    #expect(lines.allSatisfy { $0.contains("Z +") && $0.contains("s [") })
    #expect(errors.withLock { $0.isEmpty })
    let attributes = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func debugSessionFailureIsFlushedAndDisabledModeCreatesNothing() async throws {
    let directory = debugTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var configuration = MeetingConfiguration(selected: [:])
    configuration.debugLogDirectory = directory
    let disabled = MeetingSession(configuration: configuration)
    await #expect(throws: MeetingError.self) { try await disabled.run() }
    #expect(disabled.debugLogURL == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    configuration.debugEnabled = true
    let enabled = MeetingSession(configuration: configuration)
    await #expect(throws: MeetingError.self) { try await enabled.run() }
    let url = try #require(enabled.debugLogURL)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("[ERROR] Meeting failed:"))
    #expect(text.contains("No selected input device"))
    #expect(text.contains("[DEBUG] Configuration:"))
    #expect(text.contains("Meeting phase: failed"))
    let next = MeetingSession(configuration: configuration)
    #expect(next.debugLogURL != enabled.debugLogURL)
}

@Test func debugLogOpenFailureDoesNotStopSession() async throws {
    let directory = debugTestDirectory()
    try Data("not a directory".utf8).write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    var configuration = MeetingConfiguration(selected: [
        .remote: AudioDevice(id: 1002, name: "Test remote", inputChannels: 2, sampleRate: 48000)
    ])
    configuration.remoteOnly = true
    configuration.debugEnabled = true
    configuration.debugLogDirectory = directory
    let diagnostics = Mutex<[String]>([])
    let phases = Mutex<[MeetingPhase]>([])
    let session = MeetingSession(configuration: configuration, callbacks: MeetingCallbacks(
        phase: { phase in phases.withLock { $0.append(phase) } },
        diagnostic: { message in diagnostics.withLock { $0.append(message) } }
    ))
    session.requestStop()
    try await session.run()
    #expect(phases.withLock { $0.last } == .stopped)
    #expect(diagnostics.withLock { $0.contains { $0.contains("[ERROR] Debug-журнал недоступен") } })
}

@Test func debugTaskLocalWorkersKeepSessionFilesSeparate() async throws {
    let directory = debugTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = MeetingDebugLog(directory: directory, reportError: { _ in })
    let second = MeetingDebugLog(directory: directory, reportError: { _ in })
    first.start(); second.start()
    await withTaskGroup(of: Void.self) { group in
        for (log, name) in [(first, "FIRST"), (second, "SECOND")] {
            group.addTask {
                await MeetingAssistantCore.Log.$file.withValue(log) {
                    let child = Task { MeetingAssistantCore.Log.debug(name) }
                    await child.value
                }
            }
        }
    }
    await first.close(); await second.close()
    let firstText = try String(contentsOf: first.fileURL, encoding: .utf8)
    let secondText = try String(contentsOf: second.fileURL, encoding: .utf8)
    #expect(firstText.contains("FIRST") && !firstText.contains("SECOND"))
    #expect(secondText.contains("SECOND") && !secondText.contains("FIRST"))
}

@Test func debugCLIIsOptInAndIndependentOfAudioDump() throws {
    #expect(try Options(arguments: []).debugEnabled == false)
    let options = try Options(arguments: ["--debug", "--json"])
    #expect(options.debugEnabled && options.json)
    #expect(options.debugAudioDirectory == nil)
    #expect(options.configuration(selected: [:]).debugEnabled)
}
