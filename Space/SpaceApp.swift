import AppKit
import QuickLookUI
import SwiftUI

@MainActor
final class SpaceAppDelegate: NSObject, NSApplicationDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var workspace: WorkspaceModel?
    private var applicationShortcutMonitor: Any?

    func installApplicationShortcutMonitor(for workspace: WorkspaceModel) {
        self.workspace = workspace
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
    }

    override func acceptsPreviewPanelControl(
        _ panel: QLPreviewPanel!
    ) -> Bool {
        workspace?.selectedFileURL != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if let selectedFileURL = workspace?.selectedFileURL {
            refreshPreviewPanel(selecting: selectedFileURL)
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        workspace?.visiblePreviewFileURLs.count ?? 0
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> QLPreviewItem! {
        guard let items = workspace?.visiblePreviewFileURLs,
              items.indices.contains(index) else { return nil }
        return items[index] as NSURL
    }

    func refreshPreviewPanel(selecting url: URL) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return }
        guard let items = workspace?.visiblePreviewFileURLs,
              let index = items.firstIndex(of: url.standardizedFileURL) else {
            return
        }
        panel.currentPreviewItemIndex = index
        panel.refreshCurrentPreviewItem()
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

@main
struct SpaceApp: App {
    @NSApplicationDelegateAdaptor(SpaceAppDelegate.self)
    private var appDelegate
    @StateObject private var workspace = WorkspaceModel()

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
                Button("退出 Space") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("命令面板…") {
                    workspace.isCommandPalettePresented = false
                    workspace.isActionPalettePresented = true
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("快速切换目录…") {
                    workspace.isActionPalettePresented = false
                    workspace.isCommandPalettePresented = true
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(workspace.rootNodes.isEmpty)

                Button("新建终端") {
                    if let directory = workspace.activeDirectory {
                        workspace.openNewTerminal(for: directory)
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(workspace.activeDirectory == nil)

                Button("关闭当前终端") {
                    workspace.requestCloseActiveTerminal()
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("添加文件夹…") {
                    workspace.chooseRootDirectory()
                }
            }

            CommandMenu("终端") {
                Button("向右分屏") {
                    workspace.splitActiveTerminal(direction: .right)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(workspace.activeTerminalSession == nil)

                Button("向下分屏") {
                    workspace.splitActiveTerminal(direction: .down)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace.activeTerminalSession == nil)

                Divider()

                Button("查找终端内容…") {
                    workspace.activeTerminalSession?.presentSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workspace.activeTerminalSession == nil)

                Button("查找下一个") {
                    workspace.activeTerminalSession?.navigateSearch(forward: true)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(workspace.activeTerminalSession == nil)

                Button("查找上一个") {
                    workspace.activeTerminalSession?.navigateSearch(forward: false)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(workspace.activeTerminalSession == nil)

                Divider()

                Button("恢复最近关闭的终端") {
                    workspace.restoreLastClosedTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!workspace.canRestoreClosedTerminal)

                Divider()

                Button("上一个终端") {
                    workspace.selectAdjacentTerminal(offset: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("下一个终端") {
                    workspace.selectAdjacentTerminal(offset: 1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("切换到左侧终端") {
                    workspace.selectSplit(in: .left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!workspace.canNavigateSplit)

                Button("切换到右侧终端") {
                    workspace.selectSplit(in: .right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!workspace.canNavigateSplit)

                Button("切换到上方终端") {
                    workspace.selectSplit(in: .up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!workspace.canNavigateSplit)

                Button("切换到下方终端") {
                    workspace.selectSplit(in: .down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!workspace.canNavigateSplit)

                Divider()

                ForEach(0 ..< 8, id: \.self) { index in
                    Button("切换到终端 \(index + 1)") {
                        workspace.selectTerminal(at: index)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))),
                        modifiers: .command
                    )
                }

                Button("切换到最后一个终端") {
                    workspace.selectLastTerminal()
                }
                .keyboardShortcut("9", modifiers: .command)
            }

        }

        Settings {
            TerminalSettingsView(preferences: workspace.terminalPreferences)
        }
    }
}
