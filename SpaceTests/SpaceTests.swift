import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Space

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
    func terminalFileViewerUsesGlowForMarkdownWithVimFallback() {
        let file = URL(fileURLWithPath: "/tmp/Read Me.md")
        let command = TerminalFileViewer.command(for: file)

        #expect(command.contains("command -v glow"))
        #expect(command.contains("VISUAL=vim EDITOR=vim glow --tui"))
        #expect(command.contains("vim -- '/tmp/Read Me.md'"))
        #expect(command.hasSuffix("fi; exit"))
    }

    @Test
    func terminalFileViewerUsesVimForCodeAndShellQuotesThePath() {
        let file = URL(fileURLWithPath: "/tmp/it's $(unsafe).swift")
        let command = TerminalFileViewer.command(for: file)

        #expect(!command.contains("glow"))
        #expect(command == "vim -- '/tmp/it'\"'\"'s $(unsafe).swift'; exit")
    }

    @Test @MainActor
    func workspaceStartsEmptyWithoutRestoredDirectories() {
        defer { removeIsolatedDefaults() }
        let defaults = isolatedDefaults(
            workspace: FileManager.default.temporaryDirectory
        )

        let workspace = WorkspaceModel(
            defaults: defaults,
            watchesFiles: false
        )

        #expect(workspace.rootURLs.isEmpty)
        #expect(workspace.rootNodes.isEmpty)
        #expect(workspace.activeDirectory == nil)
        #expect(workspace.terminalSessions.isEmpty)
        #expect(workspace.activeTerminalID == nil)
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

        var workspace: WorkspaceModel? = WorkspaceModel(
            defaults: defaults,
            watchesFiles: false
        )
        #expect(workspace?.addRootDirectory(first) == .added(first))
        #expect(workspace?.addRootDirectory(second) == .added(second))
        #expect(workspace?.rootURLs == [first, second])
        #expect(workspace?.activeDirectory == second)
        workspace = nil

        let restored = WorkspaceModel(
            defaults: defaults,
            watchesFiles: false
        )
        #expect(restored.rootURLs == [first, second])
        #expect(restored.activeDirectory == second)
        #expect(restored.terminalSessions.count == 1)
        #expect(restored.activeTerminalSession?.directory == second)
    }

    @Test @MainActor
    func parentChildRootsCannotBothBeAdded() throws {
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: container),
            watchesFiles: false
        )

        #expect(workspace.addRootDirectory(parent) == .added(parent))
        #expect(
            workspace.addRootDirectory(child)
                == .overlaps(candidate: child, existing: parent)
        )
        #expect(workspace.addRootDirectory(independent) == .added(independent))
        #expect(workspace.addRootDirectory(parent) == .duplicate(parent))
        #expect(workspace.rootURLs == [parent, independent])
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

        var workspace: WorkspaceModel? = WorkspaceModel(
            defaults: defaults,
            watchesFiles: false
        )
        workspace?.addRootDirectory(first)
        workspace?.addRootDirectory(second)
        workspace?.removeRootDirectory(second)
        #expect(workspace?.rootURLs == [first])
        #expect(workspace?.activeDirectory == first)
        workspace = nil

        let restored = WorkspaceModel(
            defaults: defaults,
            watchesFiles: false
        )
        #expect(restored.rootURLs == [first])
        #expect(restored.activeDirectory == first)
    }

    @Test @MainActor
    func switchingBackToDirectoryReusesTerminalSession() throws {
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

        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
            initialRootURL: root
        )
        workspace.activateTerminal(for: first)
        let firstID = try #require(workspace.activeTerminalID)
        let sessionCount = workspace.terminalSessions.count

        workspace.activateTerminal(for: second)
        #expect(workspace.activeTerminalID != firstID)
        #expect(workspace.terminalSessions.count == sessionCount + 1)

        workspace.activateTerminal(for: first)
        #expect(workspace.activeTerminalID == firstID)
        #expect(workspace.terminalSessions.count == sessionCount + 1)
    }

    @Test @MainActor
    func directoryCanOwnMultipleTerminalSessions() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
            initialRootURL: root
        )
        let firstID = try #require(workspace.activeTerminalID)

        workspace.openNewTerminal(for: root)

        #expect(workspace.activeTerminalID != firstID)
        #expect(workspace.terminalSessionCount(exactlyAt: root) == 2)
        #expect(workspace.activeDirectorySessions.count == 2)
        workspace.selectTerminal(firstID)
        #expect(workspace.activeTerminalID == firstID)
    }

    @Test @MainActor
    func terminalTitleUsesForegroundProgramAndDefaultsToShellName() throws {
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

        #expect(session.displayTitle(foregroundProcessName: "top") == "top")
        #expect(session.displayTitle(foregroundProcessName: "/usr/bin/vim") == "vim")
        #expect(session.displayTitle(foregroundProcessName: "-zsh") == "zsh")
        #expect(session.displayTitle(foregroundProcessName: nil) == "zsh")
        session.customTitle = "server"
        #expect(session.displayTitle(foregroundProcessName: "top") == "server")
    }

    @Test @MainActor
    func returningToDirectoryWithMultipleTerminalsDoesNotCreateAnother() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(
            at: other,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
            initialRootURL: root
        )
        workspace.openNewTerminal(for: root)
        let expectedID = try #require(workspace.activeTerminalID)
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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
    func commandDSplitsCurrentTerminalToTheRight() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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
    }

    @Test @MainActor
    func commandOptionArrowsNavigateNestedSplitsByDirection() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
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

    @Test
    func directorySearchScansAndFuzzyMatchesRootDirectories() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Sources/App", isDirectory: true)
        let tests = root.appendingPathComponent("Tests/AppTests", isDirectory: true)
        let ignored = root.appendingPathComponent(
            "node_modules/dependency",
            isDirectory: true
        )
        for directory in [source, tests, ignored] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = WorkspaceDirectorySearch.scan(rootURL: root)
        let sourceMatches = WorkspaceDirectorySearch.topMatches(
            entries,
            query: "srcapp"
        )
        let preferredMatches = WorkspaceDirectorySearch.topMatches(
            entries,
            query: "app",
            preferredPaths: [tests.standardizedFileURL.path]
        )
        let manyEntries = (0 ..< 50).map { index in
            WorkspaceDirectoryEntry(
                url: root.appendingPathComponent("Folder\(index)", isDirectory: true),
                relativePath: "Folder\(index)"
            )
        }
        let limitedMatches = WorkspaceDirectorySearch.topMatches(
            manyEntries,
            query: "folder",
            limit: 20
        )

        #expect(entries.contains { $0.relativePath == "Sources/App" })
        #expect(entries.contains { $0.relativePath == "Tests/AppTests" })
        #expect(!entries.contains { $0.relativePath.contains("node_modules") })
        #expect(sourceMatches.first?.relativePath == "Sources/App")
        #expect(preferredMatches.first?.relativePath == "Tests/AppTests")
        #expect(limitedMatches.count == 20)
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

        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: first),
            watchesFiles: false,
            initialRootURL: first
        )
        let firstID = try #require(workspace.activeTerminalID)
        workspace.openNewTerminal(for: first)
        #expect(workspace.terminalSessions.count == 2)

        #expect(workspace.addRootDirectory(second) == .added(second))
        let secondID = try #require(workspace.activeTerminalID)
        #expect(secondID != firstID)
        #expect(workspace.rootURL == second.standardizedFileURL)
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
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
            initialRootURL: root
        )
        let firstID = try #require(workspace.activeTerminalID)
        workspace.openNewTerminal(for: root)
        let secondID = try #require(workspace.activeTerminalID)

        workspace.moveTerminal(firstID, to: secondID)

        #expect(workspace.activeDirectorySessions.map(\.id) == [secondID, firstID])
    }

    @Test @MainActor
    func selectingAFileDoesNotChangeTerminalAndClearsOnTerminalActivation() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("notes.txt")
        try "preview".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
            initialRootURL: root
        )
        let terminalID = workspace.activeTerminalID

        workspace.selectFile(file)

        #expect(workspace.selectedFileURL == file.standardizedFileURL)
        #expect(workspace.activeTerminalID == terminalID)

        workspace.activateTerminal(for: root)
        #expect(workspace.selectedFileURL == nil)
        #expect(workspace.activeTerminalID == terminalID)
    }

    @Test @MainActor
    func returnOnFileOpensViewerInRightSplit() async throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("README.md")
        try "# Preview".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
            initialRootURL: root
        )
        let rootNode = try #require(workspace.rootNode)
        let deadline = ContinuousClock.now + .seconds(2)
        while rootNode.children.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        workspace.selectFile(file)

        #expect(workspace.openSelectedTreeItemInTerminal())
        #expect(workspace.terminalSessions.count == 2)
        #expect(workspace.activeTerminalTab?.terminalIDs.count == 2)
        #expect(workspace.activeTerminalSession?.customTitle == "README.md")
        #expect(workspace.selectedFileURL == nil)
    }

    @Test @MainActor
    func directionKeysNavigateExpandAndCollapseTheFileTree() async throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let file = root.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try "preview".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(
            defaults: isolatedDefaults(workspace: root),
            watchesFiles: false,
            initialRootURL: root
        )
        let deadline = ContinuousClock.now + .seconds(2)
        let rootNode = try #require(workspace.rootNode)
        while rootNode.children.count != 2,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(workspace.selectedTreeItemURL == root.standardizedFileURL)
        #expect(workspace.isDirectoryExpanded(root))
        #expect(workspace.moveTreeSelection(offset: 1))
        #expect(workspace.selectedTreeItemURL == folder.standardizedFileURL)
        #expect(workspace.expandOrEnterSelectedTreeDirectory())
        #expect(workspace.isDirectoryExpanded(folder))
        #expect(workspace.moveTreeSelection(offset: 1))
        #expect(workspace.selectedTreeItemURL == file.standardizedFileURL)
        #expect(workspace.collapseOrSelectParentTreeDirectory())
        #expect(workspace.selectedTreeItemURL == root.standardizedFileURL)
        #expect(workspace.collapseOrSelectParentTreeDirectory())
        #expect(!workspace.isDirectoryExpanded(root))
        #expect(workspace.expandOrEnterSelectedTreeDirectory())
        #expect(workspace.isDirectoryExpanded(root))
        #expect(workspace.expandOrEnterSelectedTreeDirectory())
        #expect(workspace.selectedTreeItemURL == folder.standardizedFileURL)
        let terminalCount = workspace.terminalSessions.count
        #expect(workspace.activateSelectedTreeDirectory())
        #expect(workspace.activeDirectory == folder.standardizedFileURL)
        #expect(workspace.terminalSessions.count == terminalCount + 1)
    }

    @Test
    func directorySearchReportsTruncation() throws {
        let root = try temporaryDirectory()
        for name in ["One", "Two", "Three"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = WorkspaceDirectorySearch.scanResult(
            rootURL: root,
            maximumCount: 2
        )
        #expect(result.entries.count == 2)
        #expect(result.isTruncated)
    }

    @Test
    func directorySearchScansBreadthFirst() throws {
        let root = try temporaryDirectory()
        let deep = root.appendingPathComponent("A/Deep", isDirectory: true)
        let sibling = root.appendingPathComponent("B", isDirectory: true)
        for directory in [deep, sibling] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = WorkspaceDirectorySearch.scanResult(
            rootURL: root,
            maximumCount: 3
        )

        #expect(result.entries.map(\.relativePath) == [".", "A", "B"])
        #expect(result.isTruncated)
    }

    @Test
    func directorySearchOnlyReportsDepthLimitWhenChildrenAreOmitted() throws {
        let root = try temporaryDirectory()
        let leaf = root.appendingPathComponent("Leaf", isDirectory: true)
        try FileManager.default.createDirectory(
            at: leaf,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let complete = WorkspaceDirectorySearch.scanResult(
            rootURL: root,
            maximumDepth: 1
        )
        #expect(!complete.isTruncated)

        let nested = leaf.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        let truncated = WorkspaceDirectorySearch.scanResult(
            rootURL: root,
            maximumDepth: 1
        )
        #expect(truncated.isTruncated)
        #expect(!truncated.entries.contains { $0.relativePath == "Leaf/Nested" })
    }

    @Test @MainActor
    func backgroundDirectoryRefreshKeepsLoadedChildrenVisible() async throws {
        let root = try temporaryDirectory()
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let node = FileNode(url: root, isDirectory: true)
        node.loadChildren()
        let deadline = ContinuousClock.now + .seconds(2)
        while (node.isLoading || node.children.isEmpty),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let originalChild = try #require(node.children.first)

        let refresh = Task { @MainActor in
            await node.reloadLoadedTree(affectedPaths: [child.path])
        }
        await Task.yield()

        #expect(!node.isLoading)
        #expect(node.children.first === originalChild)
        await refresh.value
        #expect(!node.isLoading)
        #expect(node.children.first === originalChild)
    }

    @Test @MainActor
    func rootExpandedAndSidebarStateDoNotPersist() throws {
        defer { removeIsolatedDefaults() }
        let root = try temporaryDirectory()
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = isolatedDefaults(workspace: root)
        defaults.set(child.path, forKey: "rootDirectoryPath")
        defaults.set([root.path: [child.path]], forKey: "expandedDirectoryPaths")
        defaults.set(false, forKey: "sidebar.isVisible")
        defaults.set(360.0, forKey: "sidebar.width")

        var workspace: WorkspaceModel? = WorkspaceModel(
            defaults: defaults,
            watchesFiles: false,
            initialRootURL: root
        )
        #expect(workspace?.rootURL == root.standardizedFileURL)
        #expect(workspace?.isDirectoryExpanded(child) == false)
        workspace?.setDirectoryExpanded(true, url: child)
        #expect(workspace?.isDirectoryExpanded(child) == true)
        workspace = nil

        let restored = WorkspaceModel(
            defaults: defaults,
            watchesFiles: false,
            initialRootURL: root
        )
        #expect(restored.activeDirectory == root.standardizedFileURL)
        #expect(!restored.isDirectoryExpanded(child))
        #expect(defaults.object(forKey: "rootDirectoryPath") == nil)
        #expect(defaults.object(forKey: "expandedDirectoryPaths") == nil)
        #expect(defaults.object(forKey: "sidebar.isVisible") == nil)
        #expect(defaults.object(forKey: "sidebar.width") == nil)
    }

    @Test @MainActor
    func terminalPreferencesPersist() {
        defer { removeIsolatedDefaults() }
        let root = FileManager.default.temporaryDirectory
        let defaults = isolatedDefaults(workspace: root)
        let preferences = TerminalPreferences(defaults: defaults)
        preferences.fontFamily = "Menlo"
        preferences.fontSize = 17
        preferences.theme = .light

        let restored = TerminalPreferences(defaults: defaults)
        #expect(restored.fontFamily == "Menlo")
        #expect(restored.fontSize == 17)
        #expect(restored.theme == .light)
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
