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
                TextEditor(text: $settings.configuration.systemPrompt).font(.body).frame(height: 180)
                Button("Восстановить исходный промпт") { settings.configuration.systemPrompt = AIConfiguration.defaultPrompt }
                Text("Общий промпт применяется к справке и итоговому протоколу. Формат результата задаётся приложением.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Обновление справки") {
                integerSlider("Символов до сворачивания текста", value: $settings.configuration.responsePreviewCharacters, range: 100...10_000, step: 100)
                integerSlider("Фактов в справке", value: $settings.configuration.factLimit, range: 1...100)
                Text("Длинные блоки показываются сокращённо с кнопкой раскрытия. Полный текст сохраняется и копируется целиком. Порог отображения не ограничивает ответ модели; промпт по-прежнему просит краткую справку.").font(.caption).foregroundStyle(.secondary)
                secondsSlider("Интервал обновлений", value: $settings.configuration.updateInterval, range: 2...120, step: 2)
                integerSlider("Контекст модели, токенов", value: $settings.configuration.contextTokens, range: 16384...65536, step: 4096)
                integerSlider("Максимум токенов ответа", value: $settings.configuration.outputTokenLimit, range: 512...8192, step: 256)
                Text("Ограничение передаётся Ollama для каждого запроса справки и протокола. При его достижении генерация останавливается; ответ может закончиться посреди предложения.").font(.caption).foregroundStyle(.secondary)
                Text("Больший контекст позволяет учитывать больше данных за один запрос и требует больше памяти сервера. Новые фразы объединяются; параллельные обновления одной встречи не запускаются.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ожидание ответа") {
                secondsSlider("Предупреждать об ожидании ответа через", value: $settings.configuration.responseWarningSeconds, range: 5...600, step: 5)
                secondsSlider("Предупреждать об ожидании протокола через", value: $settings.configuration.protocolWarningSeconds, range: 5...1800, step: 5)
                Text("Это мягкие лимиты: по истечении времени появится предложение дождаться ответа. Запрос продолжает выполняться, пока вы сами не отмените AI. Сетевые ошибки и недоступность сервера показываются отдельно.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Дополнительные параметры") {
                VStack(alignment: .leading) {
                    Text("Вариативность ответа: \(settings.configuration.temperature, specifier: "%.2f")")
                    Slider(value: $settings.configuration.temperature, in: 0...1, step: 0.05)
                        .accessibilityLabel("Вариативность ответа")
                }
                integerSlider("Новых фраз в одном запросе", value: $settings.configuration.batchEventLimit, range: 1...24)
                integerSlider("Допустимое отставание AI, фраз", value: $settings.configuration.pendingEventLimit, range: 64...2048, step: 64)
                integerSlider("Пунктов в памяти справки", value: $settings.configuration.memoryEntryLimit, range: 128...2048, step: 128)
                Text("Лимиты количества пунктов ограничивают память справки и очередь запросов. При достижении лимита памяти полученный транскрипт и последняя справка сохраняются.")
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

    private func integerSlider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(title): \(value.wrappedValue)")
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step)).accessibilityLabel(title)
        }
    }

    private func secondsSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(title): \(Int(value.wrappedValue)) с")
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
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
