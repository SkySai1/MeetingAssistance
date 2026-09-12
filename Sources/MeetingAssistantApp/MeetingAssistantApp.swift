import AppKit
import SwiftUI

@main
struct MeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(MeetingAppDelegate.self) private var delegate
    @StateObject private var model = MeetingViewModel()

    var body: some Scene {
        Window("MeetingAssistant", id: "meeting") {
            MeetingRootView(model: model)
                .frame(minWidth: 860, minHeight: 620)
                .onAppear { delegate.model = model }
                .task { await GUIValidation.runIfRequested(model) }
        }
        .defaultSize(width: 1080, height: 760)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        Task {
            await model.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
