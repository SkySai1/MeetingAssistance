import MeetingAssistantCore
import SwiftUI

struct AIContextView: View {
    @ObservedObject var model: MeetingViewModel
    @State private var showProtocol = false
    private var state: AIState { model.aiState }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Контекст встречи").font(.headline)
                Spacer()
                if [.updating, .finalizing, .unloading].contains(state.phase) { ProgressView().controlSize(.small) }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
            Text("AI: \(state.model) · \(state.server)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
            ScrollView {
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
                                Text(kind.title).font(.headline)
                                ForEach(entries) { entry in
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
                                                }
                                            }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        if state.briefing.summary.isEmpty && state.draftSummary.isEmpty {
                            Text("Справка появится после первых подтверждённых фраз.").foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
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

    private var status: String {
        switch state.phase {
        case .disabled: "AI не включён"
        case .waiting: "Ожидаем подтверждённые фразы"
        case .updating: "Обновляем справку · обработано \(state.processedEvents) из \(state.totalEvents) фраз"
        case .ready: "Справка обновлена · \(state.processedEvents) фраз"
        case .finalizing: "Готовим итоговый протокол"
        case .unloading: state.protocolComplete ? "Протокол получен · освобождаем модель" : "Освобождаем модель"
        case .completed: state.releaseStatus == .unloaded ? "Готово · модель выгружена" : "Обработка завершена"
        case .cancelled: state.releaseStatus == .unloaded ? "AI отменён · модель выгружена" : "AI отменён"
        case .failed: "Анализ недоступен · транскрипт сохранён"
        }
    }
}
