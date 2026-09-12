import AppKit
import SwiftUI

@main
struct MeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(MeetingAppDelegate.self) private var delegate
    @StateObject private var model = MeetingViewModel()

    var body: some Scene {
        Window("MeetingAssistant", id: "meeting") {
            MeetingRootView(model: model)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { delegate.model = model }
                .task { await GUIValidation.runIfRequested(model) }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Встреча") {
                Button("Начать встречу") { model.start() }
                    .disabled(!model.canStart || model.hasMeeting)
                Button("Остановить") { model.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!model.canStop)
            }
        }
    }
}

@MainActor
final class MeetingAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MeetingViewModel?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        let window = sender.keyWindow ?? sender.windows.first
        if model.aiWasEnabled && !model.aiState.protocolComplete && ![.cancelled, .disabled].contains(model.aiState.phase) {
            let alert = NSAlert()
            alert.messageText = "Завершить встречу и подготовить протокол?"
            alert.informativeText = "Можно остановить встречу и оставить окно с результатом для копирования либо завершить без AI. После закрытия текст не сохраняется."
            alert.addButton(withTitle: "Дождаться и показать")
            alert.addButton(withTitle: "Завершить без AI")
            if alert.runModal() == .alertFirstButtonReturn {
                Task {
                    await model.stopAndWait()
                    sender.reply(toApplicationShouldTerminate: false)
                    self.terminationPending = false
                    window?.makeKeyAndOrderFront(nil)
                    sender.activate(ignoringOtherApps: true)
                }
                return .terminateLater
            }
            model.cancelAnalysis()
        }
        Task {
            await model.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
