import Combine
import Foundation
import MeetingAssistantCore

@MainActor
final class AISettingsViewModel: ObservableObject {
    @Published var enabled: Bool { didSet { preferences.set(enabled, forKey: "aiEnabled") } }
    @Published var configuration: AIConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(configuration) { preferences.set(data, forKey: "aiConfiguration") }
            if configuration.server != oldValue.server {
                refreshTask?.cancel()
                models = []
                refreshTask = Task {
                    do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                    await refresh()
                }
            }
        }
    }
    @Published private(set) var models: [OllamaModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var connectionError: String?
    private let preferences: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()

    init(preferences: UserDefaults) {
        self.preferences = preferences
        enabled = preferences.bool(forKey: "aiEnabled")
        configuration = preferences.data(forKey: "aiConfiguration").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } ?? AIConfiguration()
    }

    var selectedModelAvailable: Bool { models.contains { $0.name == configuration.model && $0.supportsCompletion } }

    func refresh() async {
        let id = UUID()
        let server = configuration.server
        refreshID = id
        isLoading = true
        connectionError = nil
        defer { if refreshID == id { isLoading = false } }
        do {
            let result = try await OllamaClient(server: server).models()
            guard !Task.isCancelled, refreshID == id, configuration.server == server else { return }
            models = result
        } catch {
            guard !Task.isCancelled, refreshID == id, configuration.server == server else { return }
            models = []
            connectionError = "Не удалось подключиться: \(error.localizedDescription)"
        }
    }
}
