import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class SpaceAppDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private var applicationShortcutMonitor: Any?
    private var terminationCheckTask: Task<Void, Never>?

    func installApplicationShortcutMonitor(for model: AppModel) {
        self.model = model
        UNUserNotificationCenter.current().delegate = self
        model.agentAttentionHandler = {
            [weak self] terminalID, folderURL, notification in
            self?.deliverAgentAttentionNotification(
                terminalID: terminalID,
                folderURL: folderURL,
                notification: notification
            )
        }
        model.agentAttentionClearedHandler = { terminalID in
            let center = UNUserNotificationCenter.current()
            let identifier = Self.agentAttentionIdentifier(
                for: terminalID
            )
            center.removePendingNotificationRequests(
                withIdentifiers: [identifier]
            )
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
        guard applicationShortcutMonitor == nil else { return }

        applicationShortcutMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return event }

            // TerminalView checks its own bindings before AppKit reaches the
            // main menu. Give Space's declared menu shortcuts first refusal.
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return nil
            }

            if let index = TerminalTabSelectionShortcut.index(for: event),
               let model = self?.model {
                let selected = index == 8
                    ? model.selectLastTab()
                    : model.selectTab(at: index)
                if selected { return nil }
            }

            // Keep a physical-key fallback for shifted brackets because their
            // characters vary with the active keyboard layout.
            guard let offset = AdjacentTabShortcut.offset(for: event),
                  self?.model?.selectAdjacentTab(offset: offset) == true
            else { return event }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let applicationShortcutMonitor {
            NSEvent.removeMonitor(applicationShortcutMonitor)
        }
        applicationShortcutMonitor = nil
        terminationCheckTask?.cancel()
        terminationCheckTask = nil
        model?.stopTerminalRuntimeMonitoring()
        model?.agentAttentionHandler = nil
        model?.agentAttentionClearedHandler = nil
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.clearVisibleAgentAttention()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            model?.ensureTerminalTab()
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let value = response.notification.request.content.userInfo[
            "terminalID"
        ] as? String,
            let terminalID = UUID(uuidString: value)
        else { return }

        model?.selectTerminal(terminalID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func deliverAgentAttentionNotification(
        terminalID: UUID,
        folderURL: URL,
        notification: AgentAttentionNotification
    ) {
        guard !NSApp.isActive else { return }

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let isAuthorized: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                isAuthorized = true
            case .notDetermined:
                isAuthorized = (try? await center.requestAuthorization(
                    options: [.alert, .sound]
                )) == true
            case .denied, .ephemeral:
                isAuthorized = false
            @unknown default:
                isAuthorized = false
            }
            guard isAuthorized,
                  model?.agentAttentionByTerminalID[terminalID]?.id
                    == notification.id else { return }

            let content = UNMutableNotificationContent()
            let title = notification.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let body = notification.body.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            content.title = title.isEmpty ? "Agent needs attention" : title
            content.body = body.isEmpty
                ? Folder(url: folderURL).displayName
                : body
            content.sound = .default
            content.userInfo = ["terminalID": terminalID.uuidString]

            let identifier = Self.agentAttentionIdentifier(for: terminalID)
            center.removePendingNotificationRequests(
                withIdentifiers: [identifier]
            )
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            try? await center.add(UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            ))
        }
    }

    private static func agentAttentionIdentifier(for terminalID: UUID) -> String {
        "space.agent-attention.\(terminalID.uuidString)"
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let model else {
            return .terminateNow
        }
        guard terminationCheckTask == nil else {
            return .terminateLater
        }

        terminationCheckTask = Task { [weak self] in
            let prompt = await ApplicationTerminationCheck.prompt(for: model)
            guard !Task.isCancelled else { return }
            let shouldTerminate = self?.confirmApplicationTermination(
                prompt
            ) ?? true
            self?.terminationCheckTask = nil
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    private func confirmApplicationTermination(
        _ prompt: ApplicationTerminationPrompt
    ) -> Bool {
        guard prompt.requiresConfirmation else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Processes Are Still Running"
        alert.informativeText = prompt.informativeText
        alert.addButton(withTitle: "Quit Space")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum ApplicationTerminationCheck {
    static func prompt(for model: AppModel) async -> ApplicationTerminationPrompt {
        await model.refreshTerminalProcessNames()
        return ApplicationTerminationPrompt(
            runningProgramNames: model.terminalSessions.compactMap(
                \.runningForegroundProcessName
            )
        )
    }
}

struct ApplicationTerminationPrompt {
    let runningProgramNames: [String]

    var requiresConfirmation: Bool {
        !runningProgramNames.isEmpty
    }

    var informativeText: String {
        guard requiresConfirmation else { return "" }

        let names = Array(Set(runningProgramNames)).sorted().joined(separator: ", ")
        let subject = runningProgramNames.count == 1
            ? "Running process in 1 terminal"
            : "Running processes in \(runningProgramNames.count) terminals"
        let object = runningProgramNames.count == 1 ? "it" : "them"
        return "\(subject): \(names)."
            + "\nQuitting Space will terminate \(object)."
    }
}

enum AdjacentTabShortcut {
    private static let leftBracketKeyCode: UInt16 = 33
    private static let rightBracketKeyCode: UInt16 = 30
    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command, .shift, .control, .option,
    ]

    static func offset(for event: NSEvent) -> Int? {
        offset(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        )
    }

    static func offset(
        keyCode: UInt16,
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Int? {
        guard modifierFlags.intersection(relevantModifiers)
            == [.command, .shift] else { return nil }

        switch keyCode {
        case leftBracketKeyCode:
            return -1
        case rightBracketKeyCode:
            return 1
        default:
            switch characters {
            case "[", "{":
                return -1
            case "]", "}":
                return 1
            default:
                return nil
            }
        }
    }
}

enum TerminalTabSelectionShortcut {
    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command, .shift, .control, .option,
    ]

    static func index(for event: NSEvent) -> Int? {
        index(
            characters: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        )
    }

    static func index(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Int? {
        guard modifierFlags.intersection(relevantModifiers) == .command,
              let characters,
              characters.count == 1,
              let digit = Int(characters),
              (1 ... 9).contains(digit) else { return nil }
        return digit - 1
    }
}

@main
struct SpaceApp: App {
    @NSApplicationDelegateAdaptor(SpaceAppDelegate.self)
    private var appDelegate
    @StateObject private var model: AppModel

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        _model = StateObject(wrappedValue: Self.makeAppModel())
    }

    private static func makeAppModel() -> AppModel {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let pathsValue = environment["SPACE_UI_TEST_FOLDER_PATHS"] {
            let paths = pathsValue.split(separator: "\n").map(String.init)
            let suiteName = environment["SPACE_UI_TEST_DEFAULTS_SUITE"]
                ?? "SpaceUITests"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            let model = AppModel(
                defaults: defaults,
                initialFolderURL: paths.first.map(URL.init(fileURLWithPath:))
            )
            for path in paths.dropFirst() {
                model.addFolder(
                    URL(fileURLWithPath: path),
                    activate: false
                )
            }
            return model
        }
        #endif
        return AppModel()
    }

    var body: some Scene {
        WindowGroup {
            PreferredAppearanceView(
                settings: model.settings
            ) {
                ContentView()
                    .environmentObject(model)
                    .onAppear {
                        model.startTerminalRuntimeMonitoring()
                        appDelegate.installApplicationShortcutMonitor(
                            for: model
                        )
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Space") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    model.openNewTerminalInActiveContext()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("New Standalone Tab") {
                    model.openNewStandaloneTerminal()
                }

                Button("Add Folder…") {
                    model.chooseFolder()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Split Right") {
                    model.splitActiveTerminal(direction: .right)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.activeTerminalSession == nil)

                Button("Split Left") {
                    model.splitActiveTerminal(direction: .left)
                }
                .disabled(model.activeTerminalSession == nil)

                Button("Split Down") {
                    model.splitActiveTerminal(direction: .down)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.activeTerminalSession == nil)

                Button("Split Up") {
                    model.splitActiveTerminal(direction: .up)
                }
                .disabled(model.activeTerminalSession == nil)

                Divider()

                Button("Close Terminal") {
                    model.requestCloseActiveTerminal()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.activeTerminalSession == nil)

                Button("Reopen Closed Terminal") {
                    model.restoreLastClosedTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!model.canRestoreClosedTerminal)
            }

            CommandGroup(replacing: .saveItem) { }

            CommandGroup(after: .pasteboard) {
                Button("Append Selection to .memo") {
                    model.sendActiveSelectionToMemo()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.activeTerminalSession == nil)

                Divider()

                Button("Find…") {
                    model.activeTerminalSession?.presentSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.activeTerminalSession == nil)

                Button("Find Next") {
                    model.activeTerminalSession?.navigateSearch(forward: true)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.activeTerminalSession == nil)

                Button("Find Previous") {
                    model.activeTerminalSession?.navigateSearch(forward: false)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.activeTerminalSession == nil)
            }

            CommandGroup(replacing: .sidebar) {
                Button(model.isSidebarVisible
                    ? "Hide Sidebar"
                    : "Show Sidebar") {
                    model.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.folders.isEmpty && model.terminalTabs.isEmpty)

                Divider()

                Button("Rename Tab…") {
                    guard let tabID = model.activeTerminalTab?.id else {
                        return
                    }
                    model.promptRenameTab(tabID)
                }
                .disabled(model.activeTerminalTab == nil)
            }

            CommandGroup(before: .windowArrangement) {
                Button("Previous Tab Group") {
                    model.selectAdjacentTabGroup(offset: -1)
                }
                .keyboardShortcut(
                    .leftArrow,
                    modifiers: [.command, .shift]
                )
                .disabled(model.tabGroupCount < 2)

                Button("Next Tab Group") {
                    model.selectAdjacentTabGroup(offset: 1)
                }
                .keyboardShortcut(
                    .rightArrow,
                    modifiers: [.command, .shift]
                )
                .disabled(model.tabGroupCount < 2)

                Divider()

                Button("Previous Tab") {
                    model.selectAdjacentTab(offset: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.activeScopeTabs.count < 2)

                Button("Next Tab") {
                    model.selectAdjacentTab(offset: 1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.activeScopeTabs.count < 2)

                Divider()

                Button("Select Split Left") {
                    model.selectSplit(in: .left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!model.canSelectSplit(in: .left))

                Button("Select Split Right") {
                    model.selectSplit(in: .right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!model.canSelectSplit(in: .right))

                Button("Select Split Above") {
                    model.selectSplit(in: .up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!model.canSelectSplit(in: .up))

                Button("Select Split Below") {
                    model.selectSplit(in: .down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!model.canSelectSplit(in: .down))
            }
        }

        Settings {
            SettingsView(settings: model.settings)
        }
    }
}

private struct PreferredAppearanceView<Content: View>: View {
    @ObservedObject var settings: AppSettings
    let content: Content

    init(
        settings: AppSettings,
        @ViewBuilder content: () -> Content
    ) {
        self.settings = settings
        self.content = content()
    }

    var body: some View {
        content.preferredColorScheme(
            settings.appearance.colorScheme
        )
    }
}
