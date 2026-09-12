import MeetingAssistantCore
import SwiftUI

struct AISettingsView: View {
    @ObservedObject var settings: AISettingsViewModel
    let meetingActive: Bool

    var body: some View {
        Form {
            Section("Контекст и протокол встречи") {
                if let error = settings.storageError { Text(error).foregroundStyle(.orange) }
                Toggle("Использовать Ollama", isOn: $settings.enabled)
                Text("Подтверждённый текст отправляется на выбранный сервер. Микрофон и распознавание работают на этом Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                if meetingActive { Text("Изменения настроек применятся к следующей встрече.").foregroundStyle(.secondary) }
            }
            Section("Сервер и модель") {
                TextField("Адрес сервера", text: $settings.configuration.server, prompt: Text("http://127.0.0.1:11434"))
                HStack {
                    if settings.isLoading { ProgressView().controlSize(.small) }
                    Button("Проверить и обновить модели") { Task { await settings.refresh() } }.disabled(settings.isLoading)
                }
                if let error = settings.connectionError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if !settings.isLoading {
                    Text(settings.models.isEmpty ? "На сервере нет доступных моделей." : "Сервер доступен · моделей: \(settings.models.count)")
                        .foregroundStyle(.secondary)
                }
                Picker("Модель для встречи", selection: $settings.configuration.model) {
                    Text("Выберите модель").tag("")
                    if !settings.configuration.model.isEmpty && !settings.selectedModelAvailable {
                        Text("\(settings.configuration.model) · недоступна").tag(settings.configuration.model)
                    }
                    ForEach(settings.models.filter(\.supportsCompletion)) { model in
                        Text(model.name).tag(model.name)
                    }
                }
                Text("Модель загружается при первом запросе справки и выгружается после получения протокола. При недоступности AI транскрипция продолжает работать.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Системный промпт") {
                TextEditor(text: $settings.configuration.systemPrompt).font(.body).frame(minHeight: 180)
                Button("Восстановить исходный промпт") { settings.configuration.systemPrompt = AIConfiguration.defaultPrompt }
                Text("Общий промпт применяется к справке и итоговому протоколу. Формат результата задаётся приложением.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Обновление справки") {
                Stepper("Summary: до \(settings.configuration.summaryCharacterLimit) символов", value: $settings.configuration.summaryCharacterLimit, in: 100...1500, step: 50)
                Stepper("Фактов в справке: до \(settings.configuration.factLimit)", value: $settings.configuration.factLimit, in: 1...100)
                Text("Summary остаётся коротким. Остальные факты сохраняются в памяти встречи и учитываются в протоколе.").font(.caption).foregroundStyle(.secondary)
                Stepper("Интервал: \(Int(settings.configuration.updateInterval)) с", value: $settings.configuration.updateInterval, in: 2...120, step: 2)
                Picker("Контекст модели", selection: $settings.configuration.contextTokens) {
                    Text("16 384 токена").tag(16384)
                    Text("32 768 токенов").tag(32768)
                }
                Text("Больший контекст позволяет учитывать больше данных за один запрос и требует больше памяти сервера. Новые фразы объединяются; параллельные обновления одной встречи не запускаются.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Файлы настроек") {
                Text(settings.store.directory.path).textSelection(.enabled)
                Text("settings.json · system-prompt.txt. Файлы загружаются при запуске приложения.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await settings.refresh() }
    }
}

struct AIReadinessView: View {
    @ObservedObject var settings: AISettingsViewModel
    var body: some View {
        HStack {
            Image(systemName: settings.enabled && settings.selectedModelAvailable ? "checkmark.circle.fill" : "sparkles")
                .foregroundStyle(settings.enabled && settings.selectedModelAvailable ? .green : .secondary).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Контекст и протокол · Ollama").font(.headline)
                Text(settings.enabled ? (settings.selectedModelAvailable ? settings.configuration.model : "Выберите доступную модель в настройках AI") : "Выключено · можно включить в настройках AI")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
