import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class SpaceAppDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate {
    weak var workspace: AppModel?
    private var applicationShortcutMonitor: Any?

    func installApplicationShortcutMonitor(for workspace: AppModel) {
        self.workspace = workspace
        UNUserNotificationCenter.current().delegate = self
        workspace.agentAttentionHandler = {
            [weak self] terminalID, directory, notification in
            self?.deliverAgentAttentionNotification(
                terminalID: terminalID,
                directory: directory,
                notification: notification
            )
        }
        workspace.agentAttentionClearedHandler = { terminalID in
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
               let workspace = self?.workspace {
                let selected = index == 8
                    ? workspace.selectLastTerminal()
                    : workspace.selectTerminal(at: index)
                if selected { return nil }
            }

            // Keep a physical-key fallback for shifted brackets because their
            // characters vary with the active keyboard layout.
            guard let offset = TerminalNavigationShortcut.offset(for: event),
                  self?.workspace?.selectAdjacentTerminal(offset: offset) == true
            else { return event }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let applicationShortcutMonitor {
            NSEvent.removeMonitor(applicationShortcutMonitor)
        }
        applicationShortcutMonitor = nil
        workspace?.agentAttentionHandler = nil
        workspace?.agentAttentionClearedHandler = nil
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        workspace?.clearVisibleAgentAttention()
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

        workspace?.selectTerminal(terminalID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func deliverAgentAttentionNotification(
        terminalID: UUID,
        directory: URL,
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
                  workspace?.agentAttentionByTerminalID[terminalID]?.id
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
                ? directory.lastPathComponent
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
        guard let workspace else {
            return .terminateNow
        }

        let runningPrograms = workspace.terminalSessions.compactMap { session in
            session.isRunningForegroundProgram ? session.currentProcessName : nil
        }
        let prompt = ApplicationTerminationPrompt(
            runningProgramNames: runningPrograms
        )
        guard prompt.requiresConfirmation else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "有命令正在运行"
        alert.informativeText = prompt.informativeText
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")

        return alert.runModal() == .alertFirstButtonReturn
            ? .terminateNow
            : .terminateCancel
    }
}

struct ApplicationTerminationPrompt {
    let runningProgramNames: [String]

    var requiresConfirmation: Bool {
        !runningProgramNames.isEmpty
    }

    var informativeText: String {
        guard requiresConfirmation else { return "" }

        let names = Array(Set(runningProgramNames)).sorted().joined(separator: "、")
        return "\(runningProgramNames.count) 个终端正在运行命令：\(names)。"
            + "\n退出会结束这些程序。"
    }
}

enum TerminalNavigationShortcut {
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
    @StateObject private var workspace: AppModel

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        _workspace = StateObject(wrappedValue: Self.makeWorkspace())
    }

    private static func makeWorkspace() -> AppModel {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let pathsValue = environment["SPACE_UI_TEST_ROOT_PATHS"] {
            let paths = pathsValue.split(separator: "\n").map(String.init)
            if let firstPath = paths.first {
                let suiteName = environment["SPACE_UI_TEST_DEFAULTS_SUITE"]
                    ?? "SpaceUITests"
                let defaults = UserDefaults(suiteName: suiteName) ?? .standard
                defaults.removePersistentDomain(forName: suiteName)
                let workspace = AppModel(
                    defaults: defaults,
                    initialRootURL: URL(fileURLWithPath: firstPath),
                    defaultRootURL: nil
                )
                for path in paths.dropFirst() {
                    workspace.addRootDirectory(
                        URL(fileURLWithPath: path),
                        activate: false
                    )
                }
                return workspace
            }
        }
        #endif
        return AppModel()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 820, minHeight: 540)
                .onAppear {
                    appDelegate.installApplicationShortcutMonitor(for: workspace)
                }
        }
        .defaultSize(width: 1_220, height: 780)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Space") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Terminal") {
                    if let directory = workspace.activeDirectory {
                        workspace.openNewTerminal(for: directory)
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(workspace.activeDirectory == nil)

                Button("Add Folder…") {
                    workspace.chooseRootDirectory()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Split Right") {
                    workspace.splitActiveTerminal(direction: .right)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(workspace.activeTerminalSession == nil)

                Button("Split Left") {
                    workspace.splitActiveTerminal(direction: .left)
                }
                .disabled(workspace.activeTerminalSession == nil)

                Button("Split Down") {
                    workspace.splitActiveTerminal(direction: .down)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace.activeTerminalSession == nil)

                Button("Split Up") {
                    workspace.splitActiveTerminal(direction: .up)
                }
                .disabled(workspace.activeTerminalSession == nil)

                Divider()

                Button("Close Terminal") {
                    workspace.requestCloseActiveTerminal()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(workspace.activeTerminalSession == nil)

                Button("Reopen Closed Terminal") {
                    workspace.restoreLastClosedTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!workspace.canRestoreClosedTerminal)
            }

            CommandGroup(replacing: .saveItem) { }

            CommandGroup(after: .pasteboard) {
                Button("Find…") {
                    workspace.activeTerminalSession?.presentSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workspace.activeTerminalSession == nil)

                Button("Find Next") {
                    workspace.activeTerminalSession?.navigateSearch(forward: true)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(workspace.activeTerminalSession == nil)

                Button("Find Previous") {
                    workspace.activeTerminalSession?.navigateSearch(forward: false)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(workspace.activeTerminalSession == nil)
            }

            CommandGroup(replacing: .sidebar) {
                Button(workspace.isSidebarVisible
                    ? "Hide Folder List"
                    : "Show Folder List") {
                    workspace.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(workspace.folders.isEmpty)

                Divider()

                Button("Rename Tab…") {
                    guard let terminalID = workspace.activeTerminalID else {
                        return
                    }
                    workspace.promptRenameTerminal(terminalID)
                }
                .disabled(workspace.activeTerminalID == nil)
            }

            CommandGroup(before: .windowArrangement) {
                Button("Previous Tab") {
                    workspace.selectAdjacentTerminal(offset: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(workspace.activeDirectoryTabs.count < 2)

                Button("Next Tab") {
                    workspace.selectAdjacentTerminal(offset: 1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(workspace.activeDirectoryTabs.count < 2)

                Divider()

                Button("Select Split Left") {
                    workspace.selectSplit(in: .left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!workspace.canNavigateSplit)

                Button("Select Split Right") {
                    workspace.selectSplit(in: .right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!workspace.canNavigateSplit)

                Button("Select Split Above") {
                    workspace.selectSplit(in: .up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!workspace.canNavigateSplit)

                Button("Select Split Below") {
                    workspace.selectSplit(in: .down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!workspace.canNavigateSplit)
            }
        }

        Settings {
            TerminalSettingsView(preferences: workspace.terminalPreferences)
        }
    }
}
