import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Space

private extension AppModel {
    var activeDirectorySessions: [TerminalSession] {
        guard let activeDirectory else { return [] }
        let activePath = activeDirectory.standardizedFileURL.path
        return terminalSessions.filter {
            $0.directory.standardizedFileURL.path == activePath
        }
    }

    func terminalSessionCount(exactlyAt directory: URL) -> Int {
        let path = directory.standardizedFileURL.path
        return terminalSessions.count {
            $0.directory.standardizedFileURL.path == path
        }
    }

    func hasTerminalSession(exactlyAt directory: URL) -> Bool {
        terminalSessionCount(exactlyAt: directory) > 0
    }
}

@Suite(.serialized)
struct SpaceTests {
    private static let isolatedDefaultsSuiteName =
        "SpaceTests.IsolatedDefaults"

    private func isolatedDefaults(workspace _: URL) -> UserDefaults {
        let suiteName = Self.isolatedDefaultsSuiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func removeIsolatedDefaults() {
        UserDefaults.standard.removePersistentDomain(
            forName: Self.isolatedDefaultsSuiteName
        )
    }

    @Test
    func quitPromptOnlyAppearsForRunningPrograms() {
        let idlePrompt = ApplicationTerminationPrompt(runningProgramNames: [])
        let prompt = ApplicationTerminationPrompt(
            runningProgramNames: ["vim", "top", "top"]
        )

        #expect(!idlePrompt.requiresConfirmation)
        #expect(idlePrompt.informativeText.isEmpty)
        #expect(prompt.requiresConfirmation)
        #expect(prompt.informativeText.contains("3 个终端"))
        #expect(prompt.informativeText.contains("top、vim"))
        #expect(prompt.informativeText.contains("退出会结束这些程序"))
    }

    @Test @MainActor
    func terminalNavigationShortcutsRecognizeShiftedBracketKeys() {
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .shift]

        #expect(TerminalNavigationShortcut.offset(
            keyCode: 33,
            characters: "{",
            modifierFlags: shortcutModifiers
        ) == -1)
        #expect(TerminalNavigationShortcut.offset(
            keyCode: 30,
            characters: "}",
            modifierFlags: shortcutModifiers
        ) == 1)
        #expect(TerminalNavigationShortcut.offset(
            keyCode: 33,
            characters: "[",
            modifierFlags: .command
        ) == nil)
        #expect(TerminalNavigationShortcut.offset(
            keyCode: 30,
            characters: "]",
            modifierFlags: [.command, .shift, .option]
        ) == nil)
    }

    @Test @MainActor
    func terminalTabSelectionShortcutsRecognizeCommandDigits() {
        #expect(TerminalTabSelectionShortcut.index(
            characters: "1",
            modifierFlags: .command
        ) == 0)
        #expect(TerminalTabSelectionShortcut.index(
            characters: "9",
            modifierFlags: .command
        ) == 8)
        #expect(TerminalTabSelectionShortcut.index(
            characters: "0",
            modifierFlags: .command
        ) == nil)
        #expect(TerminalTabSelectionShortcut.index(
            characters: "1",
            modifierFlags: [.command, .shift]
        ) == nil)
    }

    @Test
    func terminalSearchActionsUseGhosttyBindingSyntax() {
        #expect(TerminalSearchAction.update(query: "build failed")
            == "search:build failed")
        #expect(TerminalSearchAction.navigate(forward: true)
            == "navigate_search:next")
        #expect(TerminalSearchAction.navigate(forward: false)
            == "navigate_search:previous")
        #expect(TerminalSearchAction.end == "end_search")
    }

    @Test
    func folderMemoFileCreatesAndAppendsSelections() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memoURL = directory.appendingPathComponent(".memo")

        let date = Date(timeIntervalSince1970: 0)
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        try FolderMemoFile.append(
            "first note",
            date: date,
            timeZone: timeZone,
            in: directory
        )
        #expect(try String(contentsOf: memoURL, encoding: .utf8)
            == "---\n1970-01-01 00:00\n\nfirst note\n\n")

        try FolderMemoFile.append(
            "second note\nthird line\n",
            date: date,
            timeZone: timeZone,
            in: directory
        )
        #expect(try String(contentsOf: memoURL, encoding: .utf8)
            == "---\n1970-01-01 00:00\n\nfirst note\n\n"
                + "---\n1970-01-01 00:00\n\n"
                + "second note\nthird line\n\n")
    }

    @Test @MainActor
    func presentingTerminalSearchAlwaysRequestsFieldFocus() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = TerminalPreferences(
            defaults: isolatedDefaults(workspace: directory)
        )
        let session = TerminalSession(
            directory: directory,
            preferences: preferences
        )

        #expect(!session.isSearchPresented)
        #expect(session.searchFocusRequest == 0)

        session.presentSearch()
        #expect(session.isSearchPresented)
        #expect(session.searchFocusRequest == 1)

        session.presentSearch()
        #expect(session.isSearchPresented)
        #expect(session.searchFocusRequest == 2)
    }

    @Test @MainActor
    func agentAttentionAggregatesAndSelectingItsTabClearsIt() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: directory),
            initialRootURL: directory,
            defaultRootURL: nil
        )
        let firstTerminalID = try #require(workspace.activeTerminalID)
        let firstTabID = try #require(workspace.activeTerminalTab?.id)

        workspace.openNewTerminal(for: directory)
        let secondTerminalID = try #require(workspace.activeTerminalID)
        let firstSession = try #require(workspace.terminalSessions.first {
            $0.id == firstTerminalID
        })
        firstSession.terminal.terminalDidRequestDesktopNotification(
            title: "Codex",
            body: "Input required"
        )

        #expect(
            workspace.agentAttentionByTerminalID[firstTerminalID]?.title
                == "Codex"
        )
        #expect(workspace.tabNeedsAgentAttention(firstTabID))
        #expect(workspace.folderNeedsAgentAttention(directory))
        #expect(workspace.activeTerminalID == secondTerminalID)

        workspace.selectTab(firstTabID)

        #expect(workspace.activeTerminalID == firstTerminalID)
        #expect(workspace.agentAttentionByTerminalID[firstTerminalID] == nil)
        #expect(!workspace.tabNeedsAgentAttention(firstTabID))
        #expect(!workspace.folderNeedsAgentAttention(directory))
    }

    @Test @MainActor
    func agentAttentionNavigatesToTheExactSplitAndFolder() throws {
        defer { removeIsolatedDefaults() }
        let container = try temporaryDirectory()
        let firstFolder = container.appendingPathComponent(
            "First",
            isDirectory: true
        )
        let secondFolder = container.appendingPathComponent(
            "Second",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstFolder,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondFolder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: container),
            initialRootURL: firstFolder,
            defaultRootURL: nil
        )
        workspace.addRootDirectory(secondFolder, activate: true)
        let targetTerminalID = try #require(workspace.activeTerminalID)
        workspace.splitActiveTerminal(direction: .right)
        let otherSplitID = try #require(workspace.activeTerminalID)
        #expect(targetTerminalID != otherSplitID)

        workspace.activateTerminal(for: firstFolder)
        workspace.receiveAgentAttention(
            AgentAttentionNotification(title: "Codex", body: "Approval needed"),
            from: targetTerminalID,
            terminalIsFocused: false,
            applicationIsActive: false
        )
        workspace.activateTerminal(for: secondFolder)

        #expect(workspace.activeDirectory == secondFolder.standardizedFileURL)
        #expect(workspace.activeTerminalID == targetTerminalID)
        #expect(workspace.agentAttentionByTerminalID[targetTerminalID] == nil)
    }

    @Test @MainActor
    func visibleAgentNotificationDoesNotCreateAttention() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: directory),
            initialRootURL: directory,
            defaultRootURL: nil
        )
        let terminalID = try #require(workspace.activeTerminalID)
        let notification = AgentAttentionNotification(
            title: "Codex",
            body: "Input required"
        )

        workspace.receiveAgentAttention(
            notification,
            from: terminalID,
            terminalIsFocused: true,
            applicationIsActive: true
        )
        #expect(workspace.agentAttentionByTerminalID.isEmpty)

        workspace.receiveAgentAttention(
            notification,
            from: terminalID,
            terminalIsFocused: true,
            applicationIsActive: false
        )
        #expect(workspace.agentAttentionByTerminalID[terminalID] == notification)
    }

    @Test @MainActor
    func rapidlyRefreshingTerminalTitleMarksItsFolderAsActive() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: directory),
            initialRootURL: directory,
            defaultRootURL: nil
        )
        let session = try #require(workspace.activeTerminalSession)

        session.terminal.terminalDidChangeTitle("⠋ Working")
        #expect(workspace.folderRefreshingTitleFrame(directory) == nil)

        session.terminal.terminalDidChangeTitle("⠙ Working")
        #expect(workspace.folderRefreshingTitleFrame(directory) == "⠙")

        session.terminal.terminalDidChangeTitle("⠹ Working")
        #expect(workspace.folderRefreshingTitleFrame(directory) == "⠹")

        workspace.closeTerminal(session.id)
        #expect(workspace.folderRefreshingTitleFrame(directory) == nil)
    }

    @Test @MainActor
    func folderImporterPresentationIsDrivenByWorkspaceState() {
        defer { removeIsolatedDefaults() }
        let defaults = isolatedDefaults(
            workspace: FileManager.default.temporaryDirectory
        )
        let workspace = AppModel(
            defaults: defaults,
            defaultRootURL: nil
        )

        #expect(!workspace.isFolderImporterPresented)
        workspace.chooseRootDirectory()
        #expect(workspace.isFolderImporterPresented)
        workspace.dismissFolderImporter()
        #expect(!workspace.isFolderImporterPresented)
    }

    @Test @MainActor
    func swiftUIPresentationsCommitRenameAndConfirmedRemoval() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = isolatedDefaults(workspace: folder)
        let workspace = AppModel(
            defaults: defaults,
            initialRootURL: folder,
            defaultRootURL: nil
        )
        let terminalID = try #require(workspace.activeTerminalID)

        workspace.promptRenameTerminal(terminalID)
        let renameRequest = try #require(workspace.renameRequest)
        workspace.saveTerminalRename(renameRequest, title: "  Build  ")
        #expect(workspace.activeTerminalSession?.customTitle == "Build")
        #expect(workspace.renameRequest == nil)

        workspace.requestRemoveRootDirectory(folder)
        let alert = try #require(workspace.alertState)
        #expect(alert.confirmationTitle == "移除并关闭终端")
        workspace.confirmAlert(alert)
        #expect(workspace.rootURLs.isEmpty)
        #expect(workspace.alertState == nil)
    }

    @Test @MainActor
    func workspaceDefaultsToUserHomeDirectory() throws {
        defer { removeIsolatedDefaults() }
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults(workspace: home)

        let workspace = AppModel(
            defaults: defaults,
            defaultRootURL: home
        )

        #expect(workspace.rootURLs == [home])
        #expect(workspace.activeDirectory == home.standardizedFileURL)
        #expect(workspace.terminalSessions.count == 1)
        #expect(workspace.activeTerminalSession?.directory == home.standardizedFileURL)
    }

    @Test @MainActor
    func defaultHomeIsAddedOnceAlongsideSavedDirectories() throws {
        defer { removeIsolatedDefaults() }
        let home = try temporaryDirectory()
        let saved = home.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(
            at: saved,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults(workspace: home)
        defaults.set(
            [saved.path],
            forKey: "workspace.folderPaths.v1"
        )
        defaults.set(
            saved.path,
            forKey: "workspace.activeFolderPath.v1"
        )

        var workspace: AppModel? = AppModel(
            defaults: defaults,
            defaultRootURL: home
        )
        #expect(workspace?.rootURLs == [home, saved])
        #expect(workspace?.activeDirectory == saved.standardizedFileURL)

        workspace?.removeRootDirectory(home)
        workspace = nil

        let restored = AppModel(
            defaults: defaults,
            defaultRootURL: home
        )
        #expect(restored.rootURLs == [saved])
        #expect(restored.activeDirectory == saved.standardizedFileURL)
    }

    @Test @MainActor
    func independentRootsPersistAndRestoreLastActiveDirectory() throws {
        defer { removeIsolatedDefaults() }
        let container = try temporaryDirectory()
        let first = container.appendingPathComponent("First", isDirectory: true)
        let second = container.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let defaults = isolatedDefaults(workspace: container)

        var workspace: AppModel? = AppModel(
            defaults: defaults,
            defaultRootURL: nil
        )
        #expect(workspace?.addRootDirectory(first) == .added(first))
        #expect(workspace?.addRootDirectory(second) == .added(second))
        #expect(workspace?.rootURLs == [first, second])
        #expect(workspace?.activeDirectory == second)
        workspace = nil

        let restored = AppModel(defaults: defaults)
        #expect(restored.rootURLs == [first, second])
        #expect(restored.activeDirectory == second)
        #expect(restored.terminalSessions.count == 1)
        #expect(restored.activeTerminalSession?.directory == second)
    }

    @Test @MainActor
    func rootDirectoriesCanBeReorderedAndRestoreOrder() throws {
        defer { removeIsolatedDefaults() }
        let container = try temporaryDirectory()
        let directories = ["First", "Second", "Third"].map {
            container.appendingPathComponent($0, isDirectory: true)
        }
        for directory in directories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: container) }
        let defaults = isolatedDefaults(workspace: container)

        var workspace: AppModel? = AppModel(
            defaults: defaults,
            defaultRootURL: nil
        )
        for directory in directories {
            #expect(workspace?.addRootDirectory(directory) == .added(directory))
        }
        let activeTerminalID = workspace?.activeTerminalID

        let currentFolders = try #require(workspace).folders
        workspace?.setFolderOrder([
            currentFolders[2], currentFolders[0], currentFolders[1],
        ])

        #expect(workspace?.rootURLs == [
            directories[2], directories[0], directories[1],
        ])
        #expect(workspace?.activeTerminalID == activeTerminalID)
        workspace = nil

        let restored = AppModel(defaults: defaults)
        #expect(restored.rootURLs == [
            directories[2], directories[0], directories[1],
        ])
        #expect(restored.activeDirectory == directories[2])
    }

    @Test @MainActor
    func parentAndChildDirectoriesCanBothBeAdded() throws {
        defer { removeIsolatedDefaults() }
        let container = try temporaryDirectory()
        let parent = container.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        let independent = container.appendingPathComponent(
            "Independent",
            isDirectory: true
        )
        for directory in [child, independent] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: container),
            defaultRootURL: nil
        )

        #expect(workspace.addRootDirectory(parent) == .added(parent))
        #expect(workspace.addRootDirectory(child) == .added(child))
        #expect(workspace.addRootDirectory(independent) == .added(independent))
        #expect(workspace.addRootDirectory(parent) == .duplicate(parent))
        #expect(workspace.rootURLs == [parent, child, independent])
        #expect(workspace.terminalSessionCount(exactlyAt: parent) == 1)
        #expect(workspace.terminalSessionCount(exactlyAt: child) == 1)

        workspace.removeRootDirectory(parent)

        #expect(workspace.rootURLs == [child, independent])
        #expect(workspace.terminalSessionCount(exactlyAt: child) == 1)
    }

    @Test @MainActor
    func removedRootDoesNotReturnOnNextLaunch() throws {
        defer { removeIsolatedDefaults() }
        let container = try temporaryDirectory()
        let first = container.appendingPathComponent("First", isDirectory: true)
        let second = container.appendingPathComponent("Second", isDirectory: true)
        for directory in [first, second] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: container) }
        let defaults = isolatedDefaults(workspace: container)

        var workspace: AppModel? = AppModel(
            defaults: defaults,
            defaultRootURL: nil
        )
        workspace?.addRootDirectory(first)
        workspace?.addRootDirectory(second)
        workspace?.removeRootDirectory(second)
        #expect(workspace?.rootURLs == [first])
        #expect(workspace?.activeDirectory == first)
        workspace = nil

        let restored = AppModel(defaults: defaults)
        #expect(restored.rootURLs == [first])
        #expect(restored.activeDirectory == first)
    }

    @Test @MainActor
    func subdirectoriesReuseTheirFolderTerminal() throws {
        defer { removeIsolatedDefaults() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        workspace.activateTerminal(for: first)
        let firstID = try #require(workspace.activeTerminalID)
        let sessionCount = workspace.terminalSessions.count

        workspace.activateTerminal(for: second)
        #expect(workspace.activeTerminalID == firstID)
        #expect(workspace.terminalSessions.count == sessionCount)
        #expect(workspace.activeTerminalSession?.directory == root.standardizedFileURL)

        workspace.activateTerminal(for: first)
        #expect(workspace.activeTerminalID == firstID)
        #expect(workspace.terminalSessions.count == sessionCount)
    }

    @Test @MainActor
    func folderCanOwnMultipleTerminalSessions() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let firstID = try #require(workspace.activeTerminalID)

        workspace.openNewTerminal(for: child)

        #expect(workspace.activeTerminalID != firstID)
        #expect(workspace.terminalSessionCount(exactlyAt: root) == 2)
        #expect(workspace.activeTerminalSession?.directory == root.standardizedFileURL)
        #expect(workspace.activeDirectorySessions.count == 2)
        workspace.selectTerminal(firstID)
        #expect(workspace.activeTerminalID == firstID)
    }

    @Test @MainActor
    func terminalTitleUsesApplicationTitleAndIgnoresPathTitle() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = TerminalPreferences(
            defaults: isolatedDefaults(workspace: directory)
        )
        let session = TerminalSession(
            directory: directory,
            preferences: preferences,
            defaultShellPath: "/bin/zsh"
        )

        #expect(session.displayTitle(
            terminalTitle: "Space",
            foregroundProcessName: "codex"
        ) == "Space")
        #expect(session.displayTitle(
            terminalTitle: "~/code/app/Space",
            foregroundProcessName: "/usr/bin/vim"
        ) == "vim")
        #expect(session.displayTitle(
            terminalTitle: "",
            foregroundProcessName: "-zsh"
        ) == "zsh")
        #expect(session.displayTitle(
            terminalTitle: "  ",
            foregroundProcessName: nil
        ) == "zsh")
        session.customTitle = "server"
        #expect(session.displayTitle(
            terminalTitle: "~/code/app/Space",
            foregroundProcessName: "top"
        ) == "server")
    }

    @Test @MainActor
    func returningToFolderWithMultipleTerminalsDoesNotCreateAnother() throws {
        defer { removeIsolatedDefaults() }
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let other = container.appendingPathComponent("other", isDirectory: true)
        for directory in [root, other] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: container) }

        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: container),
            initialRootURL: root
        )
        workspace.openNewTerminal(for: root)
        let secondTabID = try #require(workspace.activeTerminalID)
        let firstTabID = try #require(workspace.activeDirectoryTabs.first?.id)
        workspace.selectTab(firstTabID)
        let expectedID = try #require(workspace.activeTerminalID)
        #expect(expectedID != secondTabID)

        #expect(workspace.addRootDirectory(other) == .added(other))
        workspace.activateTerminal(for: other)
        let sessionCount = workspace.terminalSessions.count

        workspace.activateTerminal(for: root)

        #expect(workspace.activeTerminalID == expectedID)
        #expect(workspace.terminalSessions.count == sessionCount)
        #expect(workspace.terminalSessionCount(exactlyAt: root) == 2)
    }

    @Test @MainActor
    func closingActiveTerminalSelectsAdjacentSessionInSameDirectory() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let firstID = try #require(workspace.activeTerminalID)
        workspace.openNewTerminal(for: root)
        let secondID = try #require(workspace.activeTerminalID)

        workspace.closeTerminal(secondID)

        #expect(workspace.activeTerminalID == firstID)
        #expect(workspace.terminalSessionCount(exactlyAt: root) == 1)
    }

    @Test @MainActor
    func commandNineSelectsLastTerminalLikeGhostty() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )

        for _ in 0 ..< 9 {
            workspace.openNewTerminal(for: root)
        }
        let lastID = try #require(workspace.activeTerminalID)
        workspace.selectTerminal(at: 0)

        workspace.selectLastTerminal()

        #expect(workspace.activeTerminalID == lastID)
        #expect(workspace.activeDirectorySessions.count == 10)
    }

    @Test @MainActor
    func commandShiftBracketsSwitchAdjacentTerminalTabs() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let firstID = try #require(workspace.activeTerminalID)
        workspace.openNewTerminal(for: root)
        let secondID = try #require(workspace.activeTerminalID)
        workspace.selectTerminal(firstID)

        #expect(workspace.selectAdjacentTerminal(offset: 1))
        #expect(workspace.activeTerminalID == secondID)
        #expect(workspace.selectAdjacentTerminal(offset: -1))
        #expect(workspace.activeTerminalID == firstID)
    }

    @Test @MainActor
    func commandShiftArrowsSwitchAdjacentFoldersAndWrap() throws {
        defer { removeIsolatedDefaults() }
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let first = container.appendingPathComponent("First", isDirectory: true)
        let second = container.appendingPathComponent("Second", isDirectory: true)
        let third = container.appendingPathComponent("Third", isDirectory: true)
        for folder in [first, second, third] {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: container),
            initialRootURL: first,
            defaultRootURL: nil
        )
        let firstTerminalID = try #require(workspace.activeTerminalID)
        workspace.addRootDirectory(second)
        workspace.addRootDirectory(third)
        workspace.activateTerminal(for: first)

        #expect(workspace.selectAdjacentFolder(offset: 1))
        #expect(workspace.activeDirectory == second.standardizedFileURL)
        #expect(workspace.selectAdjacentFolder(offset: 1))
        #expect(workspace.activeDirectory == third.standardizedFileURL)
        #expect(workspace.selectAdjacentFolder(offset: 1))
        #expect(workspace.activeDirectory == first.standardizedFileURL)
        #expect(workspace.activeTerminalID == firstTerminalID)
        #expect(workspace.selectAdjacentFolder(offset: -1))
        #expect(workspace.activeDirectory == third.standardizedFileURL)
    }

    @Test @MainActor
    func commandDSplitsCurrentTerminalToTheRight() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let firstID = try #require(workspace.activeTerminalID)

        workspace.splitActiveTerminal(direction: .right)

        let secondID = try #require(workspace.activeTerminalID)
        let tab = try #require(workspace.activeTerminalTab)
        #expect(secondID != firstID)
        #expect(workspace.terminalSessions.count == 2)
        #expect(workspace.activeDirectoryTabs.count == 1)
        #expect(tab.terminalIDs == [firstID, secondID])
        let splitSession = try #require(
            workspace.terminalSessions.first { $0.id == secondID }
        )
        #expect(splitSession.terminal.configuration.context == .split)
        guard case let .split(_, axis, _, first, second) = tab.root else {
            Issue.record("Expected a split root")
            return
        }
        #expect(axis == .horizontal)
        #expect(first == .pane(firstID))
        #expect(second == .pane(secondID))
        #expect(workspace.canSelectSplit(in: .left))
        #expect(!workspace.canSelectSplit(in: .right))
        #expect(!workspace.canSelectSplit(in: .up))
        #expect(!workspace.canSelectSplit(in: .down))

        workspace.selectTerminal(firstID)
        #expect(!workspace.canSelectSplit(in: .left))
        #expect(workspace.canSelectSplit(in: .right))
        #expect(!workspace.canSelectSplit(in: .up))
        #expect(!workspace.canSelectSplit(in: .down))
    }

    @Test @MainActor
    func verticalSplitOnlyEnablesAvailableMenuDirections() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let topID = try #require(workspace.activeTerminalID)

        workspace.splitActiveTerminal(direction: .down)

        #expect(workspace.canSelectSplit(in: .up))
        #expect(!workspace.canSelectSplit(in: .down))
        #expect(!workspace.canSelectSplit(in: .left))
        #expect(!workspace.canSelectSplit(in: .right))

        workspace.selectTerminal(topID)
        #expect(!workspace.canSelectSplit(in: .up))
        #expect(workspace.canSelectSplit(in: .down))
        #expect(!workspace.canSelectSplit(in: .left))
        #expect(!workspace.canSelectSplit(in: .right))
    }

    @Test @MainActor
    func repeatedSplitsRebalanceRowsAndColumns() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )

        for _ in 0 ..< 3 {
            workspace.splitActiveTerminal(direction: .right)
        }
        for _ in 0 ..< 2 {
            workspace.splitActiveTerminal(direction: .down)
        }

        let tab = try #require(workspace.activeTerminalTab)
        let frames = Array(tab.root.paneFrames(in: CGRect(
            x: 0,
            y: 0,
            width: 1_200,
            height: 900
        )).values)
        #expect(frames.count == 6)
        #expect(frames.allSatisfy { abs($0.width - 300) < 0.001 })
        #expect(frames.filter { abs($0.height - 900) < 0.001 }.count == 3)
        #expect(frames.filter { abs($0.height - 300) < 0.001 }.count == 3)
    }

    @Test @MainActor
    func commandOptionArrowsNavigateNestedSplitsByDirection() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let leftID = try #require(workspace.activeTerminalID)
        workspace.splitActiveTerminal(direction: .right)
        let upperRightID = try #require(workspace.activeTerminalID)

        #expect(workspace.selectSplit(in: .left))
        #expect(workspace.activeTerminalID == leftID)
        #expect(workspace.selectSplit(in: .right))
        #expect(workspace.activeTerminalID == upperRightID)

        workspace.splitActiveTerminal(direction: .down)
        let lowerRightID = try #require(workspace.activeTerminalID)
        #expect(workspace.selectSplit(in: .up))
        #expect(workspace.activeTerminalID == upperRightID)
        #expect(workspace.selectSplit(in: .down))
        #expect(workspace.activeTerminalID == lowerRightID)
    }

    @Test @MainActor
    func closingSplitCollapsesLayoutAndFocusesSibling() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let firstID = try #require(workspace.activeTerminalID)
        workspace.splitActiveTerminal(direction: .right)
        let secondID = try #require(workspace.activeTerminalID)
        workspace.splitActiveTerminal(direction: .down)
        let thirdID = try #require(workspace.activeTerminalID)

        workspace.closeTerminal(thirdID)

        #expect(workspace.activeTerminalID == secondID)
        #expect(workspace.activeTerminalTab?.terminalIDs == [firstID, secondID])

        workspace.closeTerminal(secondID)

        #expect(workspace.activeTerminalID == firstID)
        #expect(workspace.activeTerminalTab?.root == .pane(firstID))
        #expect(workspace.activeDirectoryTabs.count == 1)
    }

    @Test @MainActor
    func tabNavigationSkipsOtherPanesInCurrentTab() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let firstPaneID = try #require(workspace.activeTerminalID)
        workspace.splitActiveTerminal(direction: .right)
        workspace.openNewTerminal(for: root)
        let secondTabPaneID = try #require(workspace.activeTerminalID)
        workspace.selectTerminal(firstPaneID)

        #expect(workspace.selectAdjacentTerminal(offset: 1))
        #expect(workspace.activeTerminalID == secondTabPaneID)
        #expect(workspace.selectAdjacentTerminal(offset: -1))
        #expect(workspace.activeTerminalID == firstPaneID)
    }

    @Test @MainActor
    func closingSplitTabClosesEveryPaneAndSelectsAdjacentTab() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        workspace.splitActiveTerminal(direction: .right)
        let splitTabID = try #require(workspace.activeTerminalTab?.id)
        workspace.openNewTerminal(for: root)
        let adjacentTabID = try #require(workspace.activeTerminalTab?.id)
        let adjacentTerminalID = try #require(workspace.activeTerminalID)
        workspace.selectTab(splitTabID)

        workspace.closeTab(splitTabID)

        #expect(workspace.terminalTabs.map(\.id) == [adjacentTabID])
        #expect(workspace.terminalSessions.count == 1)
        #expect(workspace.activeTerminalID == adjacentTerminalID)
    }

    @Test @MainActor
    func commandShiftTRestoresMostRecentlyClosedTerminal() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        workspace.openNewTerminal(for: root)
        let closedID = try #require(workspace.activeTerminalID)

        workspace.closeTerminal(closedID)

        #expect(workspace.canRestoreClosedTerminal)
        #expect(workspace.activeDirectorySessions.count == 1)

        workspace.restoreLastClosedTerminal()

        #expect(!workspace.canRestoreClosedTerminal)
        #expect(workspace.activeDirectorySessions.count == 2)
        #expect(workspace.activeTerminalID != closedID)
    }

    @Test @MainActor
    func closingLastTerminalLeavesDirectoryWithoutSession() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let terminalID = try #require(workspace.activeTerminalID)

        workspace.closeTerminal(terminalID)

        #expect(workspace.activeTerminalID == nil)
        #expect(workspace.activeDirectory == root.standardizedFileURL)
        #expect(workspace.activeDirectorySessions.isEmpty)
        #expect(!workspace.hasTerminalSession(exactlyAt: root))
    }

    @Test @MainActor
    func exitingTerminalClosesItsTab() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let firstID = try #require(workspace.activeTerminalID)
        workspace.openNewTerminal(for: root)
        let exitingID = try #require(workspace.activeTerminalID)
        let exitingTerminal = try #require(
            workspace.terminalSessions.first { $0.id == exitingID }?.terminal
        )

        exitingTerminal.onClose?(false)

        #expect(workspace.activeTerminalID == firstID)
        #expect(workspace.terminalSessionCount(exactlyAt: root) == 1)
        #expect(!workspace.terminalSessions.contains { $0.id == exitingID })
        #expect(!workspace.canRestoreClosedTerminal)
    }

    @Test @MainActor
    func openingAnotherRootKeepsExistingRootsAndTerminals() throws {
        defer { removeIsolatedDefaults() }
        let parent = try temporaryDirectory()
        let first = parent.appendingPathComponent("first", isDirectory: true)
        let second = parent.appendingPathComponent("second", isDirectory: true)
        for directory in [first, second] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: parent) }

        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: first),
            initialRootURL: first
        )
        let firstID = try #require(workspace.activeTerminalID)
        workspace.openNewTerminal(for: first)
        #expect(workspace.terminalSessions.count == 2)

        #expect(workspace.addRootDirectory(second) == .added(second))
        let secondID = try #require(workspace.activeTerminalID)
        #expect(secondID != firstID)
        #expect(workspace.activeDirectory == second.standardizedFileURL)
        #expect(workspace.rootURLs == [first, second])
        #expect(workspace.terminalSessions.count == 3)
        #expect(workspace.terminalSessions.contains { $0.id == firstID })

        workspace.activateTerminal(for: first)
        #expect(workspace.activeTerminalID != secondID)
        #expect(workspace.terminalSessions.count == 3)
    }

    @Test @MainActor
    func terminalTabsCanBeReordered() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AppModel(
            defaults: isolatedDefaults(workspace: root),
            initialRootURL: root
        )
        let firstID = try #require(workspace.activeTerminalID)
        workspace.openNewTerminal(for: root)
        let secondID = try #require(workspace.activeTerminalID)

        workspace.moveTab(firstID, to: secondID)

        #expect(workspace.activeDirectoryTabs.map(\.id) == [secondID, firstID])
    }

    @Test @MainActor
    func terminalPreferencesPersist() {
        defer { removeIsolatedDefaults() }
        let root = FileManager.default.temporaryDirectory
        let defaults = isolatedDefaults(workspace: root)
        let preferences = TerminalPreferences(defaults: defaults)
        #expect(
            preferences.ghosttyConfigPath
                == TerminalPreferences.defaultGhosttyConfigPath
        )
        preferences.applicationAppearance = .dark
        preferences.ghosttyConfigPath = "~/terminal/ghostty.conf"

        let restored = TerminalPreferences(defaults: defaults)
        #expect(restored.applicationAppearance == .dark)
        #expect(restored.ghosttyConfigPath == "~/terminal/ghostty.conf")
    }

    @Test @MainActor
    func ghosttyConfigPathResolvesExistingCustomFile() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("ghostty.conf")
        try "font-size = 15\n".write(to: config, atomically: true, encoding: .utf8)
        let preferences = TerminalPreferences(
            defaults: isolatedDefaults(workspace: directory)
        )

        preferences.ghosttyConfigPath = config.path

        #expect(preferences.resolvedGhosttyConfigURL == config)
        #expect(
            preferences.ghosttyConfigSource == .file(config.path)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
