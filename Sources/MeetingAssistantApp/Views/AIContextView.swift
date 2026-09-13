import MeetingAssistantCore
import SwiftUI

struct AIContextView: View {
    @ObservedObject var model: MeetingViewModel
    @State private var showProtocol = false
    @State private var factsExpanded = true
    @State private var questionsExpanded = true
    private var state: AIState { model.aiState }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Контекст встречи").font(.headline)
                Spacer()
                if [.updating, .finalizing, .unloading].contains(state.phase) { ProgressView().controlSize(.small) }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
            Text("AI: \(state.model) · \(state.server)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let warning = state.waitWarning {
                VStack(alignment: .leading, spacing: 8) {
                    Text(warning).font(.callout).foregroundStyle(.orange)
                    Button("Продолжить ждать") { model.continueWaitingForAI() }
                    Text("Ожидание не прерывает транскрипцию. Остановить запрос можно кнопкой отмены AI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = state.error {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                if model.isBusy && model.phase != .finishingAnalysis && state.phase == .failed {
                    Button("Повторить анализ") { model.retryAnalysis() }
                }
            }
            if !state.protocolText.isEmpty {
                Picker("Результат", selection: $showProtocol) {
                    Text("Справка").tag(false)
                    Text("Протокол").tag(true)
                }.pickerStyle(.segmented)
            }
                VStack(alignment: .leading, spacing: 16) {
                    if showProtocol && !state.protocolText.isEmpty {
                        if !state.protocolComplete { Text("Протокол формируется · черновик").font(.caption).foregroundStyle(.secondary) }
                        Text(state.protocolText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        if !state.briefing.topic.isEmpty { Text(state.briefing.topic).font(.title3.bold()) }
                        if !state.draftSummary.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Обновляется · черновик").font(.caption).foregroundStyle(.secondary)
                                Text(state.draftSummary)
                            }.padding(10).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if !state.briefing.summary.isEmpty { Text(state.briefing.summary).textSelection(.enabled) }
                        ForEach(ContextKind.allCases, id: \.self) { kind in
                            let entries = state.briefing.entries.filter { $0.kind == kind }
                            if !entries.isEmpty {
                                if kind == .fact || kind == .question {
                                    DisclosureGroup(isExpanded: kind == .fact ? $factsExpanded : $questionsExpanded) {
                                        ForEach(entries) { entry in entryRow(entry) }
                                    } label: { Text("\(kind.title) (\(entries.count))").font(.headline) }
                                } else {
                                    Text(kind.title).font(.headline)
                                    ForEach(entries) { entry in entryRow(entry) }
                                }
                            }
                        }
                        if state.hiddenFactCount > 0 {
                            Text("Ещё \(state.hiddenFactCount) фактов сохранено для протокола.").font(.caption).foregroundStyle(.secondary)
                        }
                        if !state.messages.isEmpty {
                            DisclosureGroup("Ваши уточнения (\(state.messages.count))") {
                                ForEach(state.messages) { message in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(MeetingViewModel.timestamp(message.time)).font(.caption).foregroundStyle(.secondary)
                                        Text(message.text).textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        if state.briefing.summary.isEmpty && state.draftSummary.isEmpty {
                            Text("Справка появится после первых подтверждённых фраз.").foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.isBusy && model.aiWasEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Уточните тему или контекст встречи", text: $model.contextMessage, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                        .disabled(!model.canSendContextMessage)
                    HStack {
                        Text("Это сообщение для AI, не реплика транскрипта.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Отправить") { Task { await model.sendContextMessage() } }
                            .disabled(!model.canSendContextMessage || model.contextMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let error = model.contextMessageError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            }
            HStack {
                if state.protocolComplete {
                    Button("Скопировать протокол", systemImage: "doc.on.doc") { model.copyProtocol() }
                }
                Spacer()
                if model.isBusy && ![.disabled, .completed, .cancelled, .unloading].contains(state.phase) && !state.protocolComplete {
                    Button(model.phase == .finishingAnalysis ? "Отменить AI" : "Отключить AI") { model.cancelAnalysis() }
                }
            }
        }
        .padding(18)
        .onChange(of: state.protocolComplete) { _, complete in if complete { showProtocol = true } }
    }

    private func entryRow(_ entry: ContextEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text).textSelection(.enabled)
                .foregroundStyle(entry.status == "active" ? .primary : .secondary)
            if entry.status != "active" {
                Text(entry.status == "superseded" ? "Изменено позднее" : "Закрыто").font(.caption).foregroundStyle(.secondary)
            }
            if !entry.owner.isEmpty { Text("Ответственный: \(entry.owner)").font(.caption) }
            if !entry.deadline.isEmpty { Text("Срок: \(entry.deadline)").font(.caption) }
            HStack {
                ForEach(Array(entry.sourceIDs.prefix(3)), id: \.self) { id in
                    if let event = model.transcript.first(where: { $0.id == id }) {
                        Button("\(event.source.rawValue) \(MeetingViewModel.timestamp(event.startTime))") { model.focusedEventID = id }
                            .buttonStyle(.link).font(.caption)
                    } else if let message = state.messages.first(where: { $0.id == id }) {
                        Text("Уточнение \(MeetingViewModel.timestamp(message.time))").font(.caption).foregroundStyle(.secondary).help(message.text)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
        switch state.phase {
        case .disabled: "AI не включён"
        case .waiting: "Ожидаем подтверждённые фразы"
        case .updating: "Обновляем справку · обработано \(state.processedEvents) из \(state.totalEvents) событий"
        case .ready: "Справка обновлена · \(state.processedEvents) событий"
        case .finalizing: "Готовим итоговый протокол"
        case .unloading: state.protocolComplete ? "Протокол получен · освобождаем модель" : "Освобождаем модель"
        case .completed: state.releaseStatus == .unloaded ? "Готово · модель выгружена" : "Обработка завершена"
        case .cancelled: state.releaseStatus == .unloaded ? "AI отменён · модель выгружена" : "AI отменён"
        case .failed: "Анализ недоступен · транскрипт сохранён"
        }
    }
}
