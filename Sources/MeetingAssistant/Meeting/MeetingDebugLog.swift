import Foundation
import Synchronization

enum LogLevel: String, Sendable, CaseIterable {
    case debug = "DEBUG", info = "INFO", warning = "WARNING", error = "ERROR"
}

/// A per-session writer. No audio callback calls this logger. The bounded queue
/// never makes capture/ASR wait for disk; overflow is reported in the log.
final class MeetingDebugLog: @unchecked Sendable {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".meetingassistant/logs", isDirectory: true)
    let fileURL: URL
    private let queue = DispatchQueue(label: "MeetingAssistant.debugLog", qos: .utility)
    private struct Gate { var accepting = false; var pending = 0; var dropped = 0 }
    private let gate = Mutex(Gate())
    // Accessed only on queue after start(), before accepting any records.
    private var handle: FileHandle?
    private let began = ProcessInfo.processInfo.systemUptime
    private let reportError: @Sendable (String) -> Void

    init(directory: URL = MeetingDebugLog.directory, reportError: @escaping @Sendable (String) -> Void) {
        let date = Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        fileURL = directory.appendingPathComponent("meeting-\(date)-\(UUID().uuidString).log")
        self.reportError = reportError
    }

    @discardableResult
    func start() -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw MeetingError("Не удалось создать \(fileURL.path)")
            }
            handle = try FileHandle(forWritingTo: fileURL)
            gate.withLock { $0.accepting = true }
            record(.info, "Debug logging started; format=2; appVersion=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"); OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
            return true
        } catch {
            reportError("[ERROR] Debug-журнал недоступен: \(error). Встреча продолжится без записи журнала.")
            return false
        }
    }

    func record(_ level: LogLevel, _ message: String) {
        let date = Date()
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        gate.withLock { state in
            guard state.accepting else { return }
            guard state.pending < 256 else { state.dropped += 1; return }
            state.pending += 1
            // Bound individual records as well as the number of queued writes.
            let limited = String(message.prefix(8192)) + (message.count > 8192 ? " [truncated]" : "")
            queue.async {
                self.write(level, limited, date: date, elapsed: elapsed)
                let dropped = self.gate.withLock { state in
                    state.pending -= 1
                    let count = state.dropped; state.dropped = 0
                    return count
                }
                if dropped > 0 { self.write(.warning, "Debug log queue full: dropped \(dropped) records") }
            }
        }
    }

    private func write(_ level: LogLevel, _ message: String, date: Date = Date(), elapsed: Double? = nil) {
        guard let handle else { return }
        let singleLine = message.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        let line = "\(date.ISO8601Format(.init(includingFractionalSeconds: true, timeZone: .gmt))) "
            + String(format: "+%.3fs", elapsed ?? (ProcessInfo.processInfo.systemUptime - began))
            + " [\(level.rawValue)] \(singleLine)\n"
        do { try handle.write(contentsOf: Data(line.utf8)) }
        catch {
            try? handle.close(); self.handle = nil
            gate.withLock { $0.accepting = false }
            reportError("[ERROR] Запись debug-журнала прекращена: \(error). Встреча продолжается.")
        }
    }

    /// Finishes all accepted writes, including the final AI/unload status.
    func close() async {
        await withCheckedContinuation { continuation in
            gate.withLock { state in
                state.accepting = false
                queue.async {
                    if let handle = self.handle {
                        do { try handle.synchronize(); try handle.close() }
                        catch { self.reportError("[ERROR] Не удалось закрыть debug-журнал: \(error)"); try? handle.close() }
                        self.handle = nil
                    }
                    continuation.resume()
                }
            }
        }
    }
}
