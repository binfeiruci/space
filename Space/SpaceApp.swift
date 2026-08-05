import AppKit
import SwiftUI

@MainActor
final class SpaceAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var applicationShortcutMonitor: Any?
    private var terminationCheckTask: Task<Void, Never>?

    func installApplicationHandlers(for model: AppModel) {
        self.model = model
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
        model?.saveWorkspace()
        model?.stopTerminalRuntimeMonitoring()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model?.saveWorkspace()
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
        await model.refreshTerminalProcessStates()
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
    @State private var model: AppModel

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        _model = State(initialValue: Self.makeAppModel())
    }

    private static func makeAppModel() -> AppModel {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let suiteName = environment["SPACE_UI_TEST_DEFAULTS_SUITE"] {
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            return AppModel(defaults: defaults)
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
                    .environment(model)
                    .onAppear {
                        model.startTerminalRuntimeMonitoring()
                        appDelegate.installApplicationHandlers(
                            for: model
                        )
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            ApplicationSettingsCommands(settings: model.settings)

            CommandGroup(replacing: .appTermination) {
                Button("Quit Space") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    model.openNewTerminal()
                }
                .keyboardShortcut("t", modifiers: .command)

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
            }

            CommandGroup(replacing: .saveItem) { }

            CommandGroup(after: .pasteboard) {
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
                .disabled(model.terminalTabs.isEmpty)
            }

            CommandGroup(before: .windowArrangement) {
                Button("Previous Tab") {
                    _ = model.selectAdjacentTab(offset: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.terminalTabs.count < 2)

                Button("Next Tab") {
                    _ = model.selectAdjacentTab(offset: 1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.terminalTabs.count < 2)

                Divider()

                Button("Select Split Left") {
                    _ = model.selectSplit(in: .left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!model.canSelectSplit(in: .left))

                Button("Select Split Right") {
                    _ = model.selectSplit(in: .right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!model.canSelectSplit(in: .right))

                Button("Select Split Above") {
                    _ = model.selectSplit(in: .up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!model.canSelectSplit(in: .up))

                Button("Select Split Below") {
                    _ = model.selectSplit(in: .down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!model.canSelectSplit(in: .down))
            }
        }
    }
}

private struct ApplicationSettingsCommands: Commands {
    @ObservedObject var settings: AppSettings

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Menu("Appearance") {
                ForEach(AppearancePreference.allCases) { appearance in
                    Button {
                        settings.appearance = appearance
                    } label: {
                        if settings.appearance == appearance {
                            Label(appearance.title, systemImage: "checkmark")
                        } else {
                            Text(appearance.title)
                        }
                    }
                }
            }

            Divider()

            Button("Settings…") {
                GhosttyConfigurationFile.system.open()
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(!GhosttyConfigurationFile.system.isAvailable)
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
