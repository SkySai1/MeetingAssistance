import MeetingAssistantCore
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case home = "Подготовка", audio = "Настройки аудио", ai = "Настройки AI", meeting = "Встреча"
    var id: Self { self }
    var icon: String {
        switch self {
        case .home: "checkmark.circle"
        case .audio: "waveform"
        case .ai: "sparkles"
        case .meeting: "text.bubble"
        }
    }
}

struct MeetingRootView: View {
    @ObservedObject var model: MeetingViewModel
    @State private var confirmNewMeeting = false
    @State private var participantsExpanded = true

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $model.selectedScreen) { screen in
                Label(screen.rawValue, systemImage: screen.icon).tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Аудио на этом Mac", systemImage: "lock.shield")
                    Text("Без облачной транскрипции").font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if let error = model.errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        if !model.errorDetails.isEmpty {
                            DisclosureGroup("Технические подробности") {
                                Text(model.errorDetails).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.07))
                }
                switch model.selectedScreen ?? .home {
                case .home: home
                case .audio: audioSettings
                case .ai: AISettingsView(settings: model.aiSettings, meetingActive: model.isBusy)
                case .meeting: liveMeeting
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle((model.selectedScreen ?? .home).rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if model.isBusy {
                        Button("Остановить", systemImage: "stop.fill", role: .destructive) { model.stop() }
                            .disabled(!model.canStop)
                    } else {
                        Button(model.hasMeeting ? "Новая встреча" : "Начать встречу", systemImage: "record.circle") { startMeeting() }
                            .disabled(!model.canStart)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .layoutProbe("root")
        .onPreferenceChange(LayoutFramesKey.self) { model.layoutFrames = $0 }
        .confirmationDialog("Начать новую встречу?", isPresented: $confirmNewMeeting, titleVisibility: .visible) {
            Button("Начать новую встречу", role: .destructive) { model.start(); model.selectedScreen = .meeting }
        } message: {
            Text("Текст текущей встречи хранится только в этом окне и будет очищен. При необходимости сначала скопируйте его.")
        }
        .task {
            if !ProcessInfo.processInfo.arguments.contains("--validate-layout") { await model.aiSettings.refresh() }
        }
        .onChange(of: model.hasMeeting) { _, hasMeeting in if hasMeeting { model.selectedScreen = .meeting } }
    }

    private func startMeeting() {
        if model.hasMeeting { confirmNewMeeting = true }
        else { model.start(); model.selectedScreen = .meeting }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Всё для разговора").font(.largeTitle.bold())
                    Text("Ваш голос и звук собеседников распознаются раздельно. Подтверждённый текст появится во время встречи.")
                        .foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(spacing: 18) {
                        readiness("Микрофон · YOU", detail: model.deviceName(.you), ready: model.microphoneID != nil)
                        Divider()
                        readiness("Собеседники · REMOTE", detail: model.deviceName(.remote), ready: model.remoteID != nil)
                        Divider()
                        readiness("Распознавание речи", detail: model.modelReady ? "Локальная модель найдена · русский язык" : "Нужна локальная модель", ready: model.modelReady)
                        Divider()
                        AIReadinessView(settings: model.aiSettings)
                    }.padding(12)
                }
                if !model.inputsReady {
                    Text("Выберите два разных входа в настройках аудио. Для звука конференции нужен BlackHole 2ch.")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Настроить звук") { model.selectedScreen = .audio }
                    Button("Настроить AI") { model.selectedScreen = .ai }
                    Spacer()
                    Button(model.hasMeeting ? "Новая встреча" : "Начать встречу", systemImage: "record.circle") { startMeeting() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
                }
                Text(model.statusText).foregroundStyle(.secondary)
                Text("В этой версии текст хранится до закрытия окна или начала новой встречи. После остановки его можно скопировать.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(28)
        }
    }

    private func readiness(_ title: String, detail: String, ready: Bool) -> some View {
        HStack {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ready ? .green : .orange).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var audioSettings: some View {
        Form {
            Section("Источники звука") {
                Picker("Ваш микрофон · YOU", selection: $model.microphoneID) {
                    Text("Выберите микрофон").tag(nil as UInt32?)
                    ForEach(model.devices) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(model.isBusy)
                Picker("Собеседники · REMOTE", selection: $model.remoteID) {
                    Text("Выберите источник").tag(nil as UInt32?)
                    ForEach(model.devices) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(model.isBusy)
                Button("Обновить устройства", systemImage: "arrow.clockwise") { model.refresh() }.disabled(model.isBusy)
                if !model.inputsReady {
                    Text("Для запуска выберите два разных доступных входа.").foregroundStyle(.orange)
                }
                Text("Чтобы слышать и распознавать собеседников, выберите в macOS многовыходное устройство с наушниками и BlackHole 2ch.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Проверка уровней") {
                meter(.you)
                meter(.remote)
                if model.isBusy {
                    Text(model.statusText).foregroundStyle(.secondary)
                    if model.isAudioTest { Button("Завершить проверку") { model.stop() }.disabled(!model.canStop) }
                } else {
                    Button("Проверить звук") { model.start(audioTest: true) }.disabled(!model.inputsReady)
                }
                Text("Во время проверки микрофон и звук собеседников захватываются только для уровней: текст и аудиофайлы не сохраняются.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Распознавание речи · Whisper") {
                LabeledContent("Статус", value: model.modelReady ? "Файлы найдены" : "Файлы не найдены")
                folderRow("Модель", path: model.modelPath, tokenizer: false)
                folderRow("Словарь", path: model.tokenizerPath, tokenizer: true)
                HStack {
                    Button("Загрузить Whisper large-v3 · 626 MB") { Task { await model.downloadSpeechModel() } }
                        .disabled(model.isBusy || model.isDownloadingSpeechModel)
                    if model.isDownloadingSpeechModel {
                        Button("Отменить") { model.cancelSpeechDownload() }
                    }
                }
                if model.isDownloadingSpeechModel { ProgressView(value: model.speechDownloadProgress) }
                if !model.speechDownloadStatus.isEmpty { Text(model.speechDownloadStatus).font(.caption) }
                Text("Приложение загружает модель и словарь в ~/.meetingassistant/models/whisper. Готовые файлы можно выбрать выше; поддерживается Whisper large-v3 для WhisperKit.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Whisper large-v3 · русский язык. Загрузка модели в память выполняется при старте встречи.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Отображение транскрипта") {
                Toggle("Объединять последовательные реплики", isOn: $model.transcriptDisplayConfiguration.enabled)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Пауза между частями реплики: \(model.transcriptDisplayConfiguration.maximumPause, specifier: "%.1f") с")
                    Slider(value: $model.transcriptDisplayConfiguration.maximumPause, in: 0.2...3, step: 0.1)
                        .accessibilityLabel("Пауза между частями реплики")
                    Text("Максимальный интервал одной карточки: \(Int(model.transcriptDisplayConfiguration.maximumDuration)) с")
                    Slider(value: $model.transcriptDisplayConfiguration.maximumDuration, in: 5...120, step: 5)
                        .accessibilityLabel("Максимальный интервал одной карточки")
                }.disabled(!model.transcriptDisplayConfiguration.enabled)
                Text("Части речи одного спикера дополняют карточку сразу после распознавания. При смене голоса, большой паузе или достижении интервала начинается новая карточка. Отдельная исходная фраза всегда сохраняется целиком.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Настройки меняют отображение текущей встречи и сохраняются между запусками. Скорость распознавания и обработка AI от этих ползунков не зависят.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.diarizationConfiguration.remoteEnabled {
                    Text("Для объединения реплик собеседников включите разделение голосов REMOTE. Без него приложение не может отличить смену говорящего от продолжения речи.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.transcriptDisplayError { Text(error).foregroundStyle(.orange) }
            }
            Section("Разделение голосов · диаризация") {
                Toggle("Различать собеседников в REMOTE", isOn: $model.diarizationConfiguration.remoteEnabled)
                Toggle("Различать голоса у микрофона", isOn: $model.diarizationConfiguration.microphoneEnabled)
                Text("Опция микрофона нужна, если рядом говорят несколько человек. При её выключении весь микрофон остаётся YOU. Источники обрабатываются раздельно; реальные имена пока не определяются.").font(.caption).foregroundStyle(.secondary)
                Picker("Модель разделения голосов", selection: $model.diarizationConfiguration.model) {
                    ForEach(DiarizationModel.allCases) { Text($0.title).tag($0) }
                }.disabled(model.isBusy || model.isPreparingDiarization)
                Text(model.diarizationConfiguration.model.details).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Статус", value: model.diarizationModelReady ? "Файлы найдены" : "Требуется загрузка или выбор папки")
                LabeledContent("Папка модели") {
                    Text(model.diarizationConfiguration.resolvedModelURL.path).lineLimit(1).truncationMode(.middle)
                        .help(model.diarizationConfiguration.resolvedModelURL.path)
                    Button("Выбрать…") { model.chooseDiarizationFolder() }.disabled(model.isBusy || model.isPreparingDiarization)
                }
                HStack {
                    Button("Загрузить выбранную модель") { Task { await model.prepareDiarization() } }
                        .disabled(model.isBusy || model.isPreparingDiarization)
                    if !model.diarizationConfiguration.customModelPath.isEmpty {
                        Button("Использовать папку приложения") { model.diarizationConfiguration.customModelPath = "" }
                            .disabled(model.isBusy || model.isPreparingDiarization)
                    }
                    if model.isPreparingDiarization { ProgressView().controlSize(.small) }
                }
                Text("Первичная подготовка загружает модель на этот Mac. Во время встречи аудио обрабатывается локально. Изменения переключателей применяются к следующей встрече.").font(.caption).foregroundStyle(.secondary)
                if let error = model.diarizationError { Text(error).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped)
    }

    private func folderRow(_ title: String, path: String, tokenizer: Bool) -> some View {
        LabeledContent(title) {
            Text(path.isEmpty ? "Стандартная папка" : path).lineLimit(1).truncationMode(.middle).help(path)
            Button("Выбрать…") { model.chooseModelFolder(tokenizer: tokenizer) }.disabled(model.isBusy || model.isDownloadingSpeechModel)
        }
    }

    private func meter(_ source: AudioSource) -> some View {
        let db = model.metrics[source]?.levelDB ?? -120
        return HStack(spacing: 12) {
            Text(source.rawValue).font(.caption.monospaced().bold()).frame(width: 64, alignment: .leading)
            ProgressView(value: min(1, max(0, (db + 60) / 60)))
                .tint(source == .you ? .blue : .teal)
                .accessibilityLabel("Уровень \(source.rawValue)")
            Text(model.metrics[source] == nil ? "—" : "\(Int(db)) dB")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64)
        }
    }

    private var liveMeeting: some View {
        GeometryReader { available in
        VStack(spacing: 0) {
            HStack {
                Circle().fill(model.phase == .running && !model.isAudioTest ? .red : .secondary).frame(width: 9, height: 9)
                Text(model.statusText)
                Spacer()
                Text(MeetingViewModel.timestamp(model.elapsed)).font(.title2.monospacedDigit())
                Button("Скопировать", systemImage: "doc.on.doc") { model.copyTranscript() }.disabled(model.transcript.isEmpty)
            }.padding(20).layoutProbe("meeting-controls")
            Divider()
            if model.aiWasEnabled {
                // A nested AppKit split view retains an oversized intrinsic width
                // across NavigationSplitView tab changes. Size both panes from the
                // actual available detail area so neither can push content offscreen.
                GeometryReader { geometry in
                    let contextWidth = min(520, geometry.size.width * 0.46)
                    HStack(spacing: 0) {
                        transcriptPane.frame(width: max(0, geometry.size.width - contextWidth - 1), height: geometry.size.height)
                            .layoutProbe("transcript")
                        Divider().frame(width: 1)
                        AIContextView(model: model).frame(width: contextWidth, height: geometry.size.height)
                            .layoutProbe("context")
                    }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }.frame(minHeight: 160, maxHeight: .infinity).layoutPriority(1)
            } else {
                transcriptPane.frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity).layoutPriority(1).layoutProbe("transcript")
            }
            Divider()
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup("Участники встречи · \(model.participants.count)", isExpanded: $participantsExpanded) {
                    if model.participants.isEmpty {
                        Text("Обнаруженные голоса появятся здесь. Включите разделение голосов в настройках аудио.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Table(model.participants) {
                            TableColumn("Участник", value: \.id)
                            TableColumn("Источник") { Text($0.source.rawValue) }.width(80)
                            TableColumn("Впервые") { Text(MeetingViewModel.timestamp($0.firstHeard)) }.width(80)
                            TableColumn("Последняя речь") { Text(MeetingViewModel.timestamp($0.lastHeard)) }.width(110)
                            TableColumn("Время речи") { Text(MeetingViewModel.timestamp($0.speechDuration)) }.width(85)
                        }.frame(height: min(130, 30 + Double(model.participants.count) * 24))
                    }
                }
                meter(.you)
                meter(.remote)
                ForEach(AudioSource.allCases, id: \.self) { source in
                    if let state = model.diarizationStates[source] {
                        Text(diarizationStatus(state)).font(.caption).foregroundStyle(state.phase == .failed ? .orange : .secondary)
                    }
                }
                if model.metrics.values.contains(where: { $0.backlogSeconds > 24 }) {
                    Label("Распознавание отстаёт от разговора", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                DisclosureGroup("Диагностика · последние 100 сообщений") {
                    ScrollView {
                        Text(model.diagnostics.joined(separator: "\n")).font(.caption.monospaced())
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 120)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            }.frame(height: min(260, available.size.height * 0.38)).layoutProbe("meeting-footer")
        }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutProbe("meeting")
        }
    }
    private func diarizationStatus(_ state: DiarizationState) -> String {
        let prefix = "Диаризация \(state.source.rawValue): "
        switch state.phase {
        case .loading: return prefix + "загрузка модели"
        case .ready: return prefix + "готова"
        case .running: return prefix + "различено голосов: \(state.detectedSpeakers)"
        case .completed: return prefix + "завершена · голосов: \(state.detectedSpeakers)"
        case .failed: return prefix + (state.error ?? "недоступна")
        }
    }
    @ViewBuilder
    private var transcriptPane: some View {
            if model.transcript.isEmpty {
                ContentUnavailableView {
                    Label(model.isBusy ? "Слушаем встречу" : "Здесь будет транскрипт", systemImage: "waveform")
                } description: {
                    Text(model.isBusy ? "Подтверждённые фразы появляются после небольшой паузы в речи." : "Начните встречу, чтобы увидеть текст с временными метками.")
                }.frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(model.transcriptGroups) { group in
                                TranscriptGroupRow(group: group, focusedEventID: model.focusedEventID)
                                    .id(group.id)
                            }
                        }.padding(24)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: model.focusedEventID, initial: true) { _, _ in
                        if let id = model.focusedTranscriptGroupID { proxy.scrollTo(id, anchor: .top) }
                    }
                    .onChange(of: model.transcriptRevision) { _, _ in
                        if let id = model.focusedTranscriptGroupID { proxy.scrollTo(id, anchor: .top) }
                        else if let last = model.transcriptGroups.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if model.focusedEventID != nil {
                            Button("К новым репликам", systemImage: "arrow.down") {
                                model.focusedEventID = nil
                                if let last = model.transcriptGroups.last { proxy.scrollTo(last.id, anchor: .bottom) }
                            }.padding(8)
                        }
                    }
                }
            }
    }
}

private struct TranscriptGroupRow: View {
    let group: TranscriptGroup
    let focusedEventID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group.speakerLabel).font(.caption.bold()).foregroundStyle(group.source == .you ? .blue : .teal)
                Text("\(MeetingViewModel.timestamp(group.startTime))–\(MeetingViewModel.timestamp(group.endTime))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let focused = group.events.first(where: { $0.id == focusedEventID }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Исходный фрагмент · \(MeetingViewModel.timestamp(focused.startTime))")
                        .font(.caption.bold())
                    Text(focused.text).textSelection(.enabled)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .layoutProbe("transcript-focused-fragment")
            }
            Text(group.text).font(.body).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
