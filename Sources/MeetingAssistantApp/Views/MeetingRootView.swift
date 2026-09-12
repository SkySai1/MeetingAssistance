import MeetingAssistantCore
import SwiftUI

private enum Screen: String, CaseIterable, Identifiable {
    case home = "Подготовка", audio = "Настройки аудио", meeting = "Встреча"
    var id: Self { self }
    var icon: String {
        switch self {
        case .home: "checkmark.circle"
        case .audio: "waveform"
        case .meeting: "text.bubble"
        }
    }
}

struct MeetingRootView: View {
    @ObservedObject var model: MeetingViewModel
    @State private var screen: Screen? = .home
    @State private var confirmNewMeeting = false

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { screen in
                Label(screen.rawValue, systemImage: screen.icon).tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Обработка на Mac", systemImage: "lock.shield")
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
                switch screen ?? .home {
                case .home: home
                case .audio: audioSettings
                case .meeting: liveMeeting
                }
            }
            .navigationTitle((screen ?? .home).rawValue)
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
        .confirmationDialog("Начать новую встречу?", isPresented: $confirmNewMeeting, titleVisibility: .visible) {
            Button("Начать новую встречу", role: .destructive) { model.start(); screen = .meeting }
        } message: {
            Text("Текст текущей встречи хранится только в этом окне и будет очищен. При необходимости сначала скопируйте его.")
        }
        .onChange(of: model.hasMeeting) { _, hasMeeting in if hasMeeting { screen = .meeting } }
    }

    private func startMeeting() {
        if model.hasMeeting { confirmNewMeeting = true }
        else { model.start(); screen = .meeting }
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
                    }.padding(12)
                }
                if !model.inputsReady {
                    Text("Выберите два разных входа в настройках аудио. Для звука конференции нужен BlackHole 2ch.")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Настроить и проверить звук") { screen = .audio }
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
            Section("Локальная модель") {
                LabeledContent("Статус", value: model.modelReady ? "Файлы найдены" : "Файлы не найдены")
                folderRow("Модель", path: model.modelPath, tokenizer: false)
                folderRow("Словарь", path: model.tokenizerPath, tokenizer: true)
                Text("Whisper large-v3 · русский язык. Загрузка модели в память выполняется при старте встречи.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func folderRow(_ title: String, path: String, tokenizer: Bool) -> some View {
        LabeledContent(title) {
            Text(path.isEmpty ? "Стандартная папка" : path).lineLimit(1).truncationMode(.middle).help(path)
            Button("Выбрать…") { model.chooseModelFolder(tokenizer: tokenizer) }.disabled(model.isBusy)
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
        VStack(spacing: 0) {
            HStack {
                Circle().fill(model.phase == .running && !model.isAudioTest ? .red : .secondary).frame(width: 9, height: 9)
                Text(model.statusText)
                Spacer()
                Text(MeetingViewModel.timestamp(model.elapsed)).font(.title2.monospacedDigit())
                Button("Скопировать", systemImage: "doc.on.doc") { model.copyTranscript() }.disabled(model.transcript.isEmpty)
            }.padding(20)
            Divider()
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
                            ForEach(Array(model.transcript.enumerated()), id: \.offset) { index, event in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(event.source == .you ? "YOU · Вы" : "REMOTE · Собеседники")
                                            .font(.caption.bold()).foregroundStyle(event.source == .you ? .blue : .teal)
                                        Text(MeetingViewModel.timestamp(event.startTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Text(event.text).font(.body).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(index)
                            }
                        }.padding(24)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: model.transcript.count) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                meter(.you)
                meter(.remote)
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
        }
    }
}
