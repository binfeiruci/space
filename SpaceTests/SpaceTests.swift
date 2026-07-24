import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Space

private extension AppModel {
    var activeFolderSessions: [TerminalSession] {
        guard let activeFolderURL else { return [] }
        let activePath = activeFolderURL.standardizedFileURL.path
        return terminalSessions.filter {
            $0.workingDirectoryURL.standardizedFileURL.path == activePath
        }
    }

    func terminalSessionCount(in folderURL: URL) -> Int {
        let path = folderURL.standardizedFileURL.path
        return terminalSessions.count {
            $0.workingDirectoryURL.standardizedFileURL.path == path
        }
    }

    func hasTerminalSession(in folderURL: URL) -> Bool {
        terminalSessionCount(in: folderURL) > 0
    }
}

private actor StubProcessInspector: TerminalProcessInspecting {
    private var namesBySessionID: [UUID: String] = [:]
    private var requestCount = 0

    func processNames(
        for requests: [TerminalProcessInspector.Request]
    ) -> [UUID: String] {
        requestCount += 1
        return namesBySessionID
    }

    func workingDirectoryURL(
        for _: TerminalProcessInspector.Request
    ) -> URL? {
        nil
    }

    func setNames(_ names: [UUID: String]) {
        namesBySessionID = names
    }

    func requestsReceived() -> Int {
        requestCount
    }
}

@Suite(.serialized)
struct SpaceTests {
    private static let isolatedDefaultsSuiteName =
        "SpaceTests.IsolatedDefaults"

    private func isolatedDefaults(scope _: URL) -> UserDefaults {
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
    func homeFolderUsesTildeAsItsDisplayName() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser

        #expect(Folder(url: homeURL).displayName == "~")
        #expect(
            Folder(url: homeURL.appendingPathComponent("Projects")).displayName
                == "Projects"
        )
    }

    @Test
    func terminalInputMethodRectCorrectsLibghosttyCellOffset() {
        let rect = LibghosttyInputMethodWorkaround.correctedAnchorRect(
            NSRect(x: 120, y: 260, width: 4, height: 20)
        )

        #expect(rect == NSRect(x: 120, y: 280, width: 4, height: 20))
        #expect(LibghosttyInputMethodWorkaround.correctedAnchorRect(.zero)
            == .zero)
    }

    @Test
    func quitPromptOnlyAppearsForRunningPrograms() {
        let idlePrompt = ApplicationTerminationPrompt(runningProgramNames: [])
        let singlePrompt = ApplicationTerminationPrompt(
            runningProgramNames: ["vim"]
        )
        let prompt = ApplicationTerminationPrompt(
            runningProgramNames: ["vim", "top", "top"]
        )

        #expect(!idlePrompt.requiresConfirmation)
        #expect(idlePrompt.informativeText.isEmpty)
        #expect(singlePrompt.requiresConfirmation)
        #expect(
            singlePrompt.informativeText
                == "Running process in 1 terminal: vim."
                + "\nQuitting Space will terminate it."
        )
        #expect(prompt.requiresConfirmation)
        #expect(prompt.informativeText.contains("3 terminals"))
        #expect(prompt.informativeText.contains("top, vim"))
        #expect(prompt.informativeText.contains("Quitting Space will terminate them"))
    }

    @Test @MainActor
    func adjacentTabShortcutRecognizesShiftedBracketKeys() {
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .shift]

        #expect(AdjacentTabShortcut.offset(
            keyCode: 33,
            characters: "{",
            modifierFlags: shortcutModifiers
        ) == -1)
        #expect(AdjacentTabShortcut.offset(
            keyCode: 30,
            characters: "}",
            modifierFlags: shortcutModifiers
        ) == 1)
        #expect(AdjacentTabShortcut.offset(
            keyCode: 33,
            characters: "[",
            modifierFlags: .command
        ) == nil)
        #expect(AdjacentTabShortcut.offset(
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
    func terminalRuntimeMonitoringUsesAdaptiveIntervals() {
        #expect(TerminalRuntimeMonitoringPolicy.interval(
            applicationIsActive: true,
            sidebarIsVisible: true
        ) == .milliseconds(250))
        #expect(TerminalRuntimeMonitoringPolicy.interval(
            applicationIsActive: true,
            sidebarIsVisible: false
        ) == .milliseconds(750))
        #expect(TerminalRuntimeMonitoringPolicy.interval(
            applicationIsActive: false,
            sidebarIsVisible: true
        ) == .seconds(1))
    }

    @Test @MainActor
    func terminalRuntimeMonitoringLifecycleIsIdempotent() {
        let defaults = isolatedDefaults(
            scope: FileManager.default.temporaryDirectory
        )
        defer { removeIsolatedDefaults() }
        let model = AppModel(defaults: defaults)

        #expect(!model.isTerminalRuntimeMonitoring)
        model.startTerminalRuntimeMonitoring()
        model.startTerminalRuntimeMonitoring()
        #expect(model.isTerminalRuntimeMonitoring)
        model.stopTerminalRuntimeMonitoring()
        #expect(!model.isTerminalRuntimeMonitoring)
    }

    @Test @MainActor
    func refreshingProcessNamesUsesTheInjectedInspector() async throws {
        defer { removeIsolatedDefaults() }
        let inspector = StubProcessInspector()
        let model = AppModel(
            defaults: isolatedDefaults(
                scope: FileManager.default.temporaryDirectory
            ),
            processInspector: inspector
        )
        let session = try #require(model.activeTerminalSession)
        await inspector.setNames([session.id: "vim"])

        await model.refreshTerminalProcessNames()
        let requestCount = await inspector.requestsReceived()

        #expect(session.currentProcessName == "vim")
        #expect(requestCount == 1)
    }

    @Test @MainActor
    func terminationCheckRefreshesProcessesBeforeBuildingPrompt() async throws {
        defer { removeIsolatedDefaults() }
        let inspector = StubProcessInspector()
        let model = AppModel(
            defaults: isolatedDefaults(
                scope: FileManager.default.temporaryDirectory
            ),
            processInspector: inspector
        )
        let session = try #require(model.activeTerminalSession)
        await inspector.setNames([session.id: "vim"])

        let prompt = await ApplicationTerminationCheck.prompt(for: model)

        #expect(prompt.runningProgramNames == ["vim"])
        #expect(prompt.requiresConfirmation)
    }

    @Test @MainActor
    func workspaceIndexTracksSessionAndTabMutations() throws {
        defer { removeIsolatedDefaults() }
        let model = AppModel(defaults: isolatedDefaults(
            scope: FileManager.default.temporaryDirectory
        ))
        let firstSession = try #require(model.activeTerminalSession)

        #expect(model.terminalSession(id: firstSession.id) === firstSession)
        #expect(model.terminalTab(id: firstSession.id)?.id == firstSession.id)

        model.openNewStandaloneTerminal()
        let secondSession = try #require(model.activeTerminalSession)
        #expect(model.terminalSession(id: secondSession.id) === secondSession)
        #expect(model.terminalTab(id: secondSession.id)?.id == secondSession.id)

        model.closeTerminal(secondSession.id)
        #expect(model.terminalSession(id: secondSession.id) == nil)
        #expect(model.terminalTab(id: secondSession.id) == nil)
        #expect(model.terminalSession(id: firstSession.id) === firstSession)
    }

    @Test
    func memoFileCreatesAndAppendsSelectionsWithWorkingDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memoURL = directory.appendingPathComponent("memo.md")
        let firstWorkingDirectory = directory.appendingPathComponent("first")
        let secondWorkingDirectory = directory.appendingPathComponent("second")

        let date = Date(timeIntervalSince1970: 0)
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        try MemoFile.append(
            "first note",
            workingDirectoryURL: firstWorkingDirectory,
            date: date,
            timeZone: timeZone,
            to: memoURL
        )
        #expect(try String(contentsOf: memoURL, encoding: .utf8)
            == "---\n1970-01-01 00:00\n"
                + "cwd: \(firstWorkingDirectory.path)\n\nfirst note\n\n")

        try MemoFile.append(
            "second note\nthird line\n",
            workingDirectoryURL: secondWorkingDirectory,
            date: date,
            timeZone: timeZone,
            to: memoURL
        )
        #expect(try String(contentsOf: memoURL, encoding: .utf8)
            == "---\n1970-01-01 00:00\n"
                + "cwd: \(firstWorkingDirectory.path)\n\nfirst note\n\n"
                + "---\n1970-01-01 00:00\n"
                + "cwd: \(secondWorkingDirectory.path)\n\n"
                + "second note\nthird line\n\n")
    }

    @Test
    func memoFilePreservesMoreThanTwoTrailingNewlines() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memoURL = directory.appendingPathComponent("memo.md")

        let date = Date(timeIntervalSince1970: 0)
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        try MemoFile.append(
            "note\n\n\n",
            workingDirectoryURL: directory,
            date: date,
            timeZone: timeZone,
            to: memoURL
        )

        #expect(try String(contentsOf: memoURL, encoding: .utf8)
            == "---\n1970-01-01 00:00\n"
                + "cwd: \(directory.path)\n\nnote\n\n\n")
    }

    @Test
    func memoWriterPerformsSerializedBackgroundWrites() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memoURL = directory.appendingPathComponent("memo.md")
        let writer = MemoWriter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 8 {
                group.addTask {
                    try await writer.append(
                        "entry-\(index)",
                        workingDirectoryURL: directory,
                        to: memoURL
                    )
                }
            }
            try await group.waitForAll()
        }

        let contents = try String(
            contentsOf: memoURL,
            encoding: .utf8
        )
        #expect(contents.components(separatedBy: "---\n").count - 1 == 8)
        for index in 0 ..< 8 {
            #expect(contents.contains("entry-\(index)\n\n"))
        }
    }

    @Test
    func memoDisplayPathAbbreviatesOnlyTheHomeDirectory() {
        let home = URL(fileURLWithPath: "/Users/example")

        #expect(MemoFile.displayPath(
            for: home,
            homeDirectoryURL: home
        ) == "~")
        #expect(MemoFile.displayPath(
            for: home.appendingPathComponent("code/app/Space"),
            homeDirectoryURL: home
        ) == "~/code/app/Space")
        #expect(MemoFile.displayPath(
            for: URL(fileURLWithPath: "/Users/example-other/project"),
            homeDirectoryURL: home
        ) == "/Users/example-other/project")
    }

    @Test
    func terminalWorkingDirectoryUsesReportedPathAndFallsBack() {
        let fallback = URL(fileURLWithPath: "/fallback")
        #expect(TerminalSession.workingDirectoryURL(
            reportedPath: "/tmp/project",
            fallback: fallback
        ).path == "/tmp/project")
        #expect(TerminalSession.workingDirectoryURL(
            reportedPath: "file:///tmp/a%20project",
            fallback: fallback
        ).path == "/tmp/a project")
        #expect(TerminalSession.workingDirectoryURL(
            reportedPath: nil,
            fallback: fallback
        ) == fallback)
    }

    @Test
    func processWorkingDirectoryReadsCurrentProcess() throws {
        let workingDirectory = try #require(
            TerminalProcessInspector.processWorkingDirectoryURL(
                processID: getpid()
            )
        )
        let expected = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).standardizedFileURL

        #expect(workingDirectory == expected)
    }

    @Test @MainActor
    func terminalSelectionReaderAlwaysRestoresThePasteboard() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("SpaceTests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let missingSelection = TerminalSelectionReader.selection(
            from: pasteboard
        ) {
            pasteboard.clearContents()
            pasteboard.setString("temporary", forType: .string)
            return false
        }

        #expect(missingSelection == nil)
        #expect(pasteboard.string(forType: .string) == "original")

        let selection = TerminalSelectionReader.selection(from: pasteboard) {
            pasteboard.clearContents()
            pasteboard.setString("selected", forType: .string)
            return true
        }

        #expect(selection == "selected")
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test @MainActor
    func presentingTerminalSearchAlwaysRequestsFieldFocus() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(
            defaults: isolatedDefaults(scope: directory)
        )
        let session = TerminalSession(
            workingDirectoryURL: directory,
            settings: settings
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
        let model = AppModel(
            defaults: isolatedDefaults(scope: directory),
            initialFolderURL: directory
        )
        let firstTerminalID = try #require(model.activeTerminalID)
        let firstTabID = try #require(model.activeTerminalTab?.id)

        model.openNewTerminal(for: directory)
        let secondTerminalID = try #require(model.activeTerminalID)
        let firstSession = try #require(model.terminalSessions.first {
            $0.id == firstTerminalID
        })
        firstSession.terminal.terminalDidRequestDesktopNotification(
            title: "Codex",
            body: "Input required"
        )

        #expect(
            model.agentAttentionByTerminalID[firstTerminalID]?.title
                == "Codex"
        )
        #expect(model.tabNeedsAgentAttention(firstTabID))
        #expect(model.folderNeedsAgentAttention(directory))
        #expect(model.activeTerminalID == secondTerminalID)

        model.selectTab(firstTabID)

        #expect(model.activeTerminalID == firstTerminalID)
        #expect(model.agentAttentionByTerminalID[firstTerminalID] == nil)
        #expect(!model.tabNeedsAgentAttention(firstTabID))
        #expect(!model.folderNeedsAgentAttention(directory))
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
        let model = AppModel(
            defaults: isolatedDefaults(scope: container),
            initialFolderURL: firstFolder
        )
        model.addFolder(secondFolder, activate: true)
        let targetTerminalID = try #require(model.activeTerminalID)
        model.splitActiveTerminal(direction: .right)
        let otherSplitID = try #require(model.activeTerminalID)
        #expect(targetTerminalID != otherSplitID)

        model.activateFolder(firstFolder)
        model.receiveAgentAttention(
            AgentAttentionNotification(title: "Codex", body: "Approval needed"),
            from: targetTerminalID,
            terminalIsFocused: false,
            applicationIsActive: false
        )
        model.activateFolder(secondFolder)

        #expect(model.activeFolderURL == secondFolder.standardizedFileURL)
        #expect(model.activeTerminalID == targetTerminalID)
        #expect(model.agentAttentionByTerminalID[targetTerminalID] == nil)
    }

    @Test @MainActor
    func visibleAgentNotificationDoesNotCreateAttention() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: directory),
            initialFolderURL: directory
        )
        let terminalID = try #require(model.activeTerminalID)
        let notification = AgentAttentionNotification(
            title: "Codex",
            body: "Input required"
        )

        model.receiveAgentAttention(
            notification,
            from: terminalID,
            terminalIsFocused: true,
            applicationIsActive: true
        )
        #expect(model.agentAttentionByTerminalID.isEmpty)

        model.receiveAgentAttention(
            notification,
            from: terminalID,
            terminalIsFocused: true,
            applicationIsActive: false
        )
        #expect(model.agentAttentionByTerminalID[terminalID] == notification)
    }

    @Test @MainActor
    func rapidlyRefreshingTerminalTitleMarksItsFolderAsActive() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: directory),
            initialFolderURL: directory
        )
        let session = try #require(model.activeTerminalSession)

        session.terminal.terminalDidChangeTitle("⠋ Working")
        #expect(model.folderRefreshingTitleFrame(directory) == nil)

        session.terminal.terminalDidChangeTitle("⠙ Working")
        #expect(model.folderRefreshingTitleFrame(directory) == "⠙")

        session.terminal.terminalDidChangeTitle("⠹ Working")
        #expect(model.folderRefreshingTitleFrame(directory) == "⠹")

        model.closeTerminal(session.id)
        #expect(model.folderRefreshingTitleFrame(directory) == nil)
    }

    @Test @MainActor
    func completedBackgroundTitleActivityMarksTabUnreadUntilSelected()
        async throws
    {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: directory),
            initialFolderURL: directory
        )
        let backgroundTab = try #require(model.activeTerminalTab)
        let backgroundSession = try #require(model.activeTerminalSession)

        model.openNewTerminal(for: directory)
        #expect(model.activeTabID != backgroundTab.id)

        backgroundSession.terminal.terminalDidChangeTitle("⠋ Working")
        backgroundSession.terminal.terminalDidChangeTitle("⠙ Working")
        #expect(model.tabIsRefreshingTitle(backgroundTab.id))
        #expect(!model.tabHasUnreadTitleActivity(backgroundTab.id))

        try await Task.sleep(for: .seconds(1.1))

        #expect(!model.tabIsRefreshingTitle(backgroundTab.id))
        #expect(model.tabHasUnreadTitleActivity(backgroundTab.id))
        #expect(model.latestUnreadTitleActivity?.tabID == backgroundTab.id)

        model.selectTab(backgroundTab.id)

        #expect(!model.tabHasUnreadTitleActivity(backgroundTab.id))
    }

    @Test @MainActor
    func completedCurrentTabTitleActivityDoesNotMarkItUnread() async throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: directory),
            initialFolderURL: directory
        )
        let tab = try #require(model.activeTerminalTab)
        let session = try #require(model.activeTerminalSession)

        session.terminal.terminalDidChangeTitle("⠋ Working")
        session.terminal.terminalDidChangeTitle("⠙ Working")
        try await Task.sleep(for: .seconds(1.1))

        #expect(!model.tabHasUnreadTitleActivity(tab.id))
        #expect(model.latestUnreadTitleActivity == nil)
    }

    @Test @MainActor
    func activatingFolderClearsAutomaticallySelectedTabUnreadState()
        async throws
    {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: directory),
            initialFolderURL: directory
        )
        let folderTab = try #require(model.activeTerminalTab)
        let folderSession = try #require(model.activeTerminalSession)

        model.openNewStandaloneTerminal()
        #expect(model.activeTabID != folderTab.id)

        folderSession.terminal.terminalDidChangeTitle("⠋ Working")
        folderSession.terminal.terminalDidChangeTitle("⠙ Working")
        try await Task.sleep(for: .seconds(1.1))

        #expect(model.tabHasUnreadTitleActivity(folderTab.id))

        model.activateFolder(directory)

        #expect(model.activeTabID == folderTab.id)
        #expect(!model.tabHasUnreadTitleActivity(folderTab.id))
    }

    @Test @MainActor
    func folderImporterPresentationIsDrivenByAppState() {
        defer { removeIsolatedDefaults() }
        let defaults = isolatedDefaults(
            scope: FileManager.default.temporaryDirectory
        )
        let model = AppModel(defaults: defaults)

        #expect(!model.isFolderImporterPresented)
        model.chooseFolder()
        #expect(model.isFolderImporterPresented)
        model.dismissFolderImporter()
        #expect(!model.isFolderImporterPresented)
    }

    @Test @MainActor
    func swiftUIPresentationsCommitRenameAndRemoveIdleFolder() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = isolatedDefaults(scope: folder)
        let model = AppModel(
            defaults: defaults,
            initialFolderURL: folder
        )
        let tabID = try #require(model.activeTerminalTab?.id)

        model.promptRenameTab(tabID)
        let renameRequest = try #require(model.renameRequest)
        #expect(renameRequest.initialTitle.isEmpty)
        #expect(!renameRequest.automaticTitle.isEmpty)
        model.saveTabRename(renameRequest, title: "  Build  ")
        #expect(model.activeTerminalTab?.customTitle == "Build")
        #expect(model.renameRequest == nil)

        model.splitActiveTerminal(direction: .right)
        #expect(model.activeTerminalTab?.customTitle == "Build")

        model.promptRenameTab(tabID)
        let resetRequest = try #require(model.renameRequest)
        model.saveTabRename(resetRequest, title: "  ")
        #expect(model.activeTerminalTab?.customTitle == nil)

        model.requestRemoveFolder(folder)
        #expect(model.folderURLs.isEmpty)
        #expect(model.alertRequest == nil)
    }

    @Test @MainActor
    func appStartsWithStandaloneHomeTabWithoutAddingFolder() throws {
        defer { removeIsolatedDefaults() }
        let defaults = isolatedDefaults(
            scope: FileManager.default.homeDirectoryForCurrentUser
        )

        let model = AppModel(defaults: defaults)

        #expect(model.folderURLs.isEmpty)
        #expect(model.activeFolderURL == nil)
        let tab = try #require(model.activeTerminalTab)
        let session = try #require(model.activeTerminalSession)
        #expect(tab.ownerFolderURL == nil)
        #expect(model.standaloneTabs.map(\.id) == [tab.id])
        #expect(
            session.workingDirectoryURL
                == FileManager.default.homeDirectoryForCurrentUser
                    .standardizedFileURL
        )

        model.closeTerminal(session.id, recordsForRestoration: false)
    }

    @Test @MainActor
    func reopeningWithoutTabsCreatesOneStandaloneHomeTab() throws {
        defer { removeIsolatedDefaults() }
        let defaults = isolatedDefaults(
            scope: FileManager.default.homeDirectoryForCurrentUser
        )
        let model = AppModel(defaults: defaults)
        let initialTerminalID = try #require(model.activeTerminalID)
        model.closeTerminal(
            initialTerminalID,
            recordsForRestoration: false
        )

        model.ensureTerminalTab()
        model.ensureTerminalTab()

        let session = try #require(model.activeTerminalSession)
        #expect(model.terminalTabs.count == 1)
        #expect(model.standaloneTabs.count == 1)
        #expect(model.folderURLs.isEmpty)
        #expect(
            session.workingDirectoryURL
                == FileManager.default.homeDirectoryForCurrentUser
                    .standardizedFileURL
        )

        model.closeTerminal(session.id, recordsForRestoration: false)
    }

    @Test @MainActor
    func newStandaloneTabUsesHomeWithoutAddingItAsAFolder() throws {
        defer { removeIsolatedDefaults() }
        let defaults = isolatedDefaults(
            scope: FileManager.default.homeDirectoryForCurrentUser
        )
        let model = AppModel(defaults: defaults)
        let initialTabID = try #require(model.activeTabID)

        model.openNewStandaloneTerminal()

        let tab = try #require(model.activeTerminalTab)
        let session = try #require(model.activeTerminalSession)
        #expect(tab.ownerFolderURL == nil)
        #expect(model.standaloneTabs.map(\.id) == [initialTabID, tab.id])
        #expect(model.activeScopeTabs.map(\.id) == [initialTabID, tab.id])
        #expect(model.activeFolderURL == nil)
        #expect(model.folderURLs.isEmpty)
        #expect(
            session.workingDirectoryURL
                == FileManager.default.homeDirectoryForCurrentUser
                    .standardizedFileURL
        )

        model.closeTerminal(session.id, recordsForRestoration: false)
        if let initialTerminalID = model.activeTerminalID {
            model.closeTerminal(
                initialTerminalID,
                recordsForRestoration: false
            )
        }
    }

    @Test @MainActor
    func newTabInActiveContextUsesTheActiveFolder() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let initialTabID = try #require(model.activeTabID)

        model.openNewTerminalInActiveContext()

        let tab = try #require(model.activeTerminalTab)
        let session = try #require(model.activeTerminalSession)
        #expect(tab.id != initialTabID)
        #expect(tab.ownerFolderURL == folder.standardizedFileURL)
        #expect(model.standaloneTabs.isEmpty)
        #expect(model.activeScopeTabs.count == 2)
        #expect(session.workingDirectoryURL == folder.standardizedFileURL)

        for terminalID in model.terminalSessions.map(\.id) {
            model.closeTerminal(terminalID, recordsForRestoration: false)
        }
    }

    @Test @MainActor
    func newTabInStandaloneContextStaysStandalone() throws {
        defer { removeIsolatedDefaults() }
        let defaults = isolatedDefaults(
            scope: FileManager.default.homeDirectoryForCurrentUser
        )
        let model = AppModel(defaults: defaults)

        model.openNewTerminalInActiveContext()

        #expect(model.standaloneTabs.count == 2)
        #expect(model.activeTerminalTab?.ownerFolderURL == nil)
        #expect(model.activeScopeTabs.count == 2)

        for terminalID in model.terminalSessions.map(\.id) {
            model.closeTerminal(terminalID, recordsForRestoration: false)
        }
    }

    @Test @MainActor
    func removingHomeFolderKeepsStandaloneHomeTab() throws {
        defer { removeIsolatedDefaults() }
        let defaults = isolatedDefaults(
            scope: FileManager.default.homeDirectoryForCurrentUser
        )
        let home = FileManager.default.homeDirectoryForCurrentUser
        let model = AppModel(defaults: defaults, initialFolderURL: home)
        let folderTabID = try #require(model.activeTerminalTab?.id)

        model.openNewStandaloneTerminal()
        let standaloneTabID = try #require(model.activeTerminalTab?.id)
        model.removeFolder(home)

        #expect(model.folderURLs.isEmpty)
        #expect(model.terminalTabs.map(\.id) == [standaloneTabID])
        #expect(!model.terminalTabs.contains { $0.id == folderTabID })
        #expect(model.activeTerminalTab?.id == standaloneTabID)

        if let terminalID = model.activeTerminalID {
            model.closeTerminal(terminalID, recordsForRestoration: false)
        }
    }

    @Test @MainActor
    func savedFoldersRestoreWithStandaloneHomeTab() throws {
        defer { removeIsolatedDefaults() }
        let home = try temporaryDirectory()
        let saved = home.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(
            at: saved,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults(scope: home)
        defaults.set(
            [saved.path],
            forKey: "folders.paths.v1"
        )
        var model: AppModel? = AppModel(defaults: defaults)
        #expect(model?.folderURLs == [saved])
        #expect(model?.activeFolderURL == nil)
        #expect(model?.standaloneTabs.count == 1)
        #expect(
            model?.activeTerminalSession?.workingDirectoryURL
                == FileManager.default.homeDirectoryForCurrentUser
                    .standardizedFileURL
        )

        model = nil

        let restored = AppModel(defaults: defaults)
        #expect(restored.folderURLs == [saved])
        #expect(restored.activeFolderURL == nil)
        #expect(restored.standaloneTabs.count == 1)
    }

    @Test @MainActor
    func independentFoldersPersistAndRestoreWithStandaloneTab() throws {
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
        let defaults = isolatedDefaults(scope: container)

        var model: AppModel? = AppModel(defaults: defaults)
        #expect(model?.addFolder(first) == .added(first))
        #expect(model?.addFolder(second) == .added(second))
        #expect(model?.folderURLs == [first, second])
        #expect(model?.activeFolderURL == second)
        model = nil

        let restored = AppModel(defaults: defaults)
        #expect(restored.folderURLs == [first, second])
        #expect(restored.activeFolderURL == nil)
        #expect(restored.terminalSessions.count == 1)
        #expect(restored.standaloneTabs.count == 1)
        #expect(
            restored.activeTerminalSession?.workingDirectoryURL
                == FileManager.default.homeDirectoryForCurrentUser
                    .standardizedFileURL
        )
    }

    @Test @MainActor
    func foldersCanBeReorderedAndRestoreOrder() throws {
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
        let defaults = isolatedDefaults(scope: container)

        var model: AppModel? = AppModel(defaults: defaults)
        for directory in directories {
            #expect(model?.addFolder(directory) == .added(directory))
        }
        let activeTerminalID = model?.activeTerminalID

        let currentFolders = try #require(model).folders
        model?.setFolderOrder([
            currentFolders[2], currentFolders[0], currentFolders[1],
        ])

        #expect(model?.folderURLs == [
            directories[2], directories[0], directories[1],
        ])
        #expect(model?.activeTerminalID == activeTerminalID)
        model = nil

        let restored = AppModel(defaults: defaults)
        #expect(restored.folderURLs == [
            directories[2], directories[0], directories[1],
        ])
        #expect(restored.activeFolderURL == nil)
        #expect(restored.standaloneTabs.count == 1)
    }

    @Test @MainActor
    func folderGroupsTrackWhetherFoldersHaveTabs() throws {
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
        let first = directories[0]
        let second = directories[1]
        let third = directories[2]
        let model = AppModel(
            defaults: isolatedDefaults(scope: container),
            initialFolderURL: first
        )
        let firstTerminalID = try #require(model.activeTerminalID)

        #expect(model.addFolder(second, activate: false) == .added(second))
        #expect(model.addFolder(third, activate: false) == .added(third))
        model.activateFolder(third)

        #expect(model.foldersWithTabs.map(\.url) == [first, third])
        #expect(model.foldersWithoutTabs.map(\.url) == [second])
        #expect(model.foldersInSidebarOrder.map(\.url) == [
            first, third, second,
        ])

        model.selectTerminal(firstTerminalID)
        #expect(model.selectAdjacentTabGroup(offset: 1))
        #expect(model.activeFolderURL == third)

        model.closeTerminal(firstTerminalID)

        #expect(model.folderURLs == [third, first, second])
        #expect(model.foldersWithTabs.map(\.url) == [third])
        #expect(model.foldersWithoutTabs.map(\.url) == [first, second])
        #expect(model.foldersInSidebarOrder.map(\.url) == [
            third, first, second,
        ])
    }

    @Test @MainActor
    func folderTabGroupingPersistsSidebarOrder() throws {
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
        let defaults = isolatedDefaults(scope: container)
        let model = AppModel(
            defaults: defaults,
            initialFolderURL: directories[0]
        )
        #expect(model.addFolder(directories[1], activate: false)
            == .added(directories[1]))
        #expect(model.addFolder(directories[2], activate: false)
            == .added(directories[2]))
        model.activateFolder(directories[2])

        let foldersByURL = Dictionary(
            uniqueKeysWithValues: model.folders.map { ($0.url, $0) }
        )
        model.setFolderOrder([
            try #require(foldersByURL[directories[1]]),
            try #require(foldersByURL[directories[0]]),
            try #require(foldersByURL[directories[2]]),
        ])

        model.activateFolder(directories[1])

        #expect(model.foldersWithTabs.map(\.url) == [
            directories[0], directories[2], directories[1],
        ])
        #expect(model.folderURLs == [
            directories[0], directories[2], directories[1],
        ])
        #expect(model.foldersInSidebarOrder.map(\.url) == [
            directories[0], directories[2], directories[1],
        ])

        let restored = AppModel(defaults: defaults)
        #expect(restored.folderURLs == [
            directories[0], directories[2], directories[1],
        ])
        #expect(restored.foldersInSidebarOrder.map(\.url) == [
            directories[0], directories[2], directories[1],
        ])
    }

    @Test @MainActor
    func parentAndChildFoldersCanBothBeAdded() throws {
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
        let model = AppModel(
            defaults: isolatedDefaults(scope: container)
        )

        #expect(model.addFolder(parent) == .added(parent))
        #expect(model.addFolder(child) == .added(child))
        #expect(model.addFolder(independent) == .added(independent))
        #expect(model.addFolder(parent) == .duplicate(parent))
        #expect(model.folderURLs == [parent, child, independent])
        #expect(model.terminalSessionCount(in: parent) == 1)
        #expect(model.terminalSessionCount(in: child) == 1)

        model.removeFolder(parent)

        #expect(model.folderURLs == [child, independent])
        #expect(model.terminalSessionCount(in: child) == 1)
    }

    @Test @MainActor
    func removedFolderDoesNotReturnOnNextLaunch() throws {
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
        let defaults = isolatedDefaults(scope: container)

        var model: AppModel? = AppModel(defaults: defaults)
        model?.addFolder(first)
        model?.addFolder(second)
        model?.removeFolder(second)
        #expect(model?.folderURLs == [first])
        #expect(model?.activeFolderURL == first)
        model = nil

        let restored = AppModel(defaults: defaults)
        #expect(restored.folderURLs == [first])
        #expect(restored.activeFolderURL == nil)
        #expect(restored.standaloneTabs.count == 1)
    }

    @Test @MainActor
    func subdirectoriesReuseTheirFolderTerminal() throws {
        defer { removeIsolatedDefaults() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = folder.appendingPathComponent("first", isDirectory: true)
        let second = folder.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        model.activateFolder(first)
        let firstID = try #require(model.activeTerminalID)
        let sessionCount = model.terminalSessions.count

        model.activateFolder(second)
        #expect(model.activeTerminalID == firstID)
        #expect(model.terminalSessions.count == sessionCount)
        #expect(
            model.activeTerminalSession?.workingDirectoryURL
                == folder.standardizedFileURL
        )

        model.activateFolder(first)
        #expect(model.activeTerminalID == firstID)
        #expect(model.terminalSessions.count == sessionCount)
    }

    @Test @MainActor
    func folderCanOwnMultipleTerminalSessions() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        let child = folder.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let firstID = try #require(model.activeTerminalID)

        model.openNewTerminal(for: child)

        #expect(model.activeTerminalID != firstID)
        #expect(model.terminalSessionCount(in: folder) == 2)
        #expect(
            model.activeTerminalSession?.workingDirectoryURL
                == folder.standardizedFileURL
        )
        #expect(model.activeFolderSessions.count == 2)
        model.selectTerminal(firstID)
        #expect(model.activeTerminalID == firstID)
    }

    @Test @MainActor
    func terminalTitleUsesApplicationTitleAndIgnoresPathTitle() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(
            defaults: isolatedDefaults(scope: directory)
        )
        let session = TerminalSession(
            workingDirectoryURL: directory,
            settings: settings,
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
        #expect(session.displayTitle(
            terminalTitle: "decorated shell title",
            foregroundProcessName: "/bin/zsh"
        ) == "zsh")
        var tab = TerminalTabState(
            id: session.id,
            ownerFolderURL: directory,
            root: .pane(session.id),
            focusedTerminalID: session.id
        )
        #expect(tab.displayTitle(automaticTitle: "top") == "top")
        tab.customTitle = "server"
        #expect(tab.displayTitle(automaticTitle: "top") == "server")
    }

    @Test @MainActor
    func foregroundProcessResolverFollowsNestedPTY() throws {
        let wrapper = TerminalProcessInspector.ProcessSnapshot(
            processID: 100,
            parentProcessID: 1,
            processGroupID: 100,
            ttyDevice: 7,
            terminalForegroundProcessGroupID: 100,
            name: "pty-wrapper"
        )
        let bridge = TerminalProcessInspector.ProcessSnapshot(
            processID: 101,
            parentProcessID: 100,
            processGroupID: 101,
            ttyDevice: nil,
            terminalForegroundProcessGroupID: 0,
            name: "bridge"
        )
        let idleShell = TerminalProcessInspector.ProcessSnapshot(
            processID: 102,
            parentProcessID: 101,
            processGroupID: 102,
            ttyDevice: 8,
            terminalForegroundProcessGroupID: 102,
            name: "zsh"
        )

        let idleProcess = try #require(
            TerminalProcessInspector.resolveForegroundProcess(
                processGroupID: 100,
                ttyDevice: 7,
                processes: [wrapper, bridge, idleShell]
            )
        )
        #expect(idleProcess.processID == 102)
        #expect(idleProcess.name == "zsh")

        let waitingShell = TerminalProcessInspector.ProcessSnapshot(
            processID: 102,
            parentProcessID: 101,
            processGroupID: 102,
            ttyDevice: 8,
            terminalForegroundProcessGroupID: 103,
            name: "zsh"
        )
        let top = TerminalProcessInspector.ProcessSnapshot(
            processID: 103,
            parentProcessID: 102,
            processGroupID: 103,
            ttyDevice: 8,
            terminalForegroundProcessGroupID: 103,
            name: "top"
        )
        let backgroundProcess = TerminalProcessInspector.ProcessSnapshot(
            processID: 104,
            parentProcessID: 102,
            processGroupID: 104,
            ttyDevice: 8,
            terminalForegroundProcessGroupID: 103,
            name: "server"
        )

        let runningProcess = try #require(
            TerminalProcessInspector.resolveForegroundProcess(
                processGroupID: 100,
                ttyDevice: 7,
                processes: [
                    wrapper,
                    bridge,
                    waitingShell,
                    top,
                    backgroundProcess,
                ]
            )
        )
        #expect(runningProcess.processID == 103)
        #expect(runningProcess.name == "top")
    }

    @Test @MainActor
    func foregroundProcessResolverSkipsLoginAndSelectsItsShell() throws {
        let processes = [
            TerminalProcessInspector.ProcessSnapshot(
                processID: 100,
                parentProcessID: 1,
                processGroupID: 100,
                ttyDevice: 7,
                name: "login"
            ),
            TerminalProcessInspector.ProcessSnapshot(
                processID: 101,
                parentProcessID: 100,
                processGroupID: 100,
                ttyDevice: 7,
                name: "zsh"
            ),
        ]

        let process = try #require(
            TerminalProcessInspector.resolveForegroundProcess(
                processGroupID: 100,
                ttyDevice: 7,
                processes: processes
            )
        )

        #expect(process.processID == 101)
        #expect(process.name == "zsh")
    }

    @Test @MainActor
    func foregroundProcessResolverUsesNonLauncherGroupLeader() throws {
        let processes = [
            TerminalProcessInspector.ProcessSnapshot(
                processID: 200,
                parentProcessID: 101,
                processGroupID: 200,
                ttyDevice: 7,
                name: "vim"
            ),
            TerminalProcessInspector.ProcessSnapshot(
                processID: 201,
                parentProcessID: 200,
                processGroupID: 200,
                ttyDevice: 7,
                name: "helper"
            ),
        ]

        let process = try #require(
            TerminalProcessInspector.resolveForegroundProcess(
                processGroupID: 200,
                ttyDevice: 7,
                processes: processes
            )
        )

        #expect(process.processID == 200)
        #expect(process.name == "vim")
    }

    @Test @MainActor
    func foregroundProcessResolverRejectsPIDFromAnotherTTY() {
        let processes = [
            TerminalProcessInspector.ProcessSnapshot(
                processID: 300,
                parentProcessID: 1,
                processGroupID: 300,
                ttyDevice: 8,
                name: "login"
            ),
        ]

        let process = TerminalProcessInspector.resolveForegroundProcess(
            processGroupID: 300,
            ttyDevice: 7,
            processes: processes
        )
        #expect(process?.processID == nil)
    }

    @Test @MainActor
    func foregroundProcessResolverUsesDeepestTTYProcessWithoutALeader() throws {
        let processes = [
            TerminalProcessInspector.ProcessSnapshot(
                processID: 401,
                parentProcessID: 400,
                processGroupID: 400,
                ttyDevice: 7,
                name: "zsh"
            ),
            TerminalProcessInspector.ProcessSnapshot(
                processID: 402,
                parentProcessID: 401,
                processGroupID: 400,
                ttyDevice: 7,
                name: "top"
            ),
        ]

        let process = try #require(
            TerminalProcessInspector.resolveForegroundProcess(
                processGroupID: 400,
                ttyDevice: 7,
                processes: processes
            )
        )

        #expect(process.processID == 402)
        #expect(process.name == "top")
    }

    @Test @MainActor
    func returningToFolderWithMultipleTerminalsDoesNotCreateAnother() throws {
        defer { removeIsolatedDefaults() }
        let container = try temporaryDirectory()
        let folder = container.appendingPathComponent("folder", isDirectory: true)
        let other = container.appendingPathComponent("other", isDirectory: true)
        for directory in [folder, other] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: container) }

        let model = AppModel(
            defaults: isolatedDefaults(scope: container),
            initialFolderURL: folder
        )
        model.openNewTerminal(for: folder)
        let secondTabID = try #require(model.activeTerminalID)
        let firstTabID = try #require(model.activeScopeTabs.first?.id)
        model.selectTab(firstTabID)
        let expectedID = try #require(model.activeTerminalID)
        #expect(expectedID != secondTabID)

        #expect(model.addFolder(other) == .added(other))
        model.activateFolder(other)
        let sessionCount = model.terminalSessions.count

        model.activateFolder(folder)

        #expect(model.activeTerminalID == expectedID)
        #expect(model.terminalSessions.count == sessionCount)
        #expect(model.terminalSessionCount(in: folder) == 2)
    }

    @Test @MainActor
    func closingActiveTerminalSelectsAdjacentSessionInSameFolder() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let firstID = try #require(model.activeTerminalID)
        model.openNewTerminal(for: folder)
        let secondID = try #require(model.activeTerminalID)

        model.closeTerminal(secondID)

        #expect(model.activeTerminalID == firstID)
        #expect(model.terminalSessionCount(in: folder) == 1)
    }

    @Test @MainActor
    func closingInactiveTabPreservesLastActiveTabInFolder() throws {
        defer { removeIsolatedDefaults() }
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = container.appendingPathComponent(
            "folder",
            isDirectory: true
        )
        let other = container.appendingPathComponent(
            "other",
            isDirectory: true
        )
        for directory in [folder, other] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let model = AppModel(
            defaults: isolatedDefaults(scope: container),
            initialFolderURL: folder
        )
        let firstTabID = try #require(model.activeTabID)
        model.openNewTerminal(for: folder)
        let secondTabID = try #require(model.activeTabID)
        model.openNewTerminal(for: folder)
        model.selectTab(firstTabID)

        model.closeTab(secondTabID)
        model.addFolder(other)
        model.activateFolder(folder)

        #expect(model.activeTabID == firstTabID)
    }

    @Test @MainActor
    func commandNineSelectsLastTabLikeGhostty() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )

        for _ in 0 ..< 9 {
            model.openNewTerminal(for: folder)
        }
        let lastID = try #require(model.activeTerminalID)
        model.selectTab(at: 0)

        model.selectLastTab()

        #expect(model.activeTerminalID == lastID)
        #expect(model.activeFolderSessions.count == 10)
    }

    @Test @MainActor
    func tabNavigationUsesGlobalSidebarOrder() throws {
        defer { removeIsolatedDefaults() }
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let first = container.appendingPathComponent(
            "First",
            isDirectory: true
        )
        let second = container.appendingPathComponent(
            "Second",
            isDirectory: true
        )
        for folder in [first, second] {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        }
        let model = AppModel(
            defaults: isolatedDefaults(scope: container),
            initialFolderURL: first
        )
        let firstFolderFirstTabID = try #require(model.activeTabID)
        model.openNewTerminal(for: first)
        let firstFolderLastTabID = try #require(model.activeTabID)
        model.addFolder(second)
        let secondFolderTabID = try #require(model.activeTabID)
        model.openNewStandaloneTerminal()
        let standaloneTabID = try #require(model.activeTabID)

        #expect(model.selectTab(at: 0))
        #expect(model.activeTabID == standaloneTabID)
        #expect(model.selectTab(at: 1))
        #expect(model.activeTabID == firstFolderFirstTabID)
        #expect(model.selectLastTab())
        #expect(model.activeTabID == secondFolderTabID)
        model.selectTab(firstFolderLastTabID)

        #expect(model.selectAdjacentTab(offset: 1))
        #expect(model.activeTabID == secondFolderTabID)
        #expect(model.selectAdjacentTab(offset: 1))
        #expect(model.activeTabID == standaloneTabID)
        #expect(model.selectAdjacentTab(offset: -1))
        #expect(model.activeTabID == secondFolderTabID)
    }

    @Test @MainActor
    func commandShiftBracketsSwitchAdjacentTerminalTabs() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let firstID = try #require(model.activeTerminalID)
        model.openNewTerminal(for: folder)
        let secondID = try #require(model.activeTerminalID)
        model.selectTerminal(firstID)

        #expect(model.selectAdjacentTab(offset: 1))
        #expect(model.activeTerminalID == secondID)
        #expect(model.selectAdjacentTab(offset: -1))
        #expect(model.activeTerminalID == firstID)
    }

    @Test @MainActor
    func commandShiftArrowsSwitchAdjacentTabGroupsAndWrap() throws {
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
        let model = AppModel(
            defaults: isolatedDefaults(scope: container),
            initialFolderURL: first
        )
        let firstTerminalID = try #require(model.activeTerminalID)
        model.addFolder(second)
        model.addFolder(third)
        model.activateFolder(first)

        #expect(model.selectAdjacentTabGroup(offset: 1))
        #expect(model.activeFolderURL == second.standardizedFileURL)
        #expect(model.selectAdjacentTabGroup(offset: 1))
        #expect(model.activeFolderURL == third.standardizedFileURL)
        #expect(model.selectAdjacentTabGroup(offset: 1))
        #expect(model.activeFolderURL == nil)
        let standaloneTabID = try #require(model.activeTabID)
        #expect(model.standaloneTabs.map(\.id) == [standaloneTabID])

        model.openNewStandaloneTerminal()
        #expect(model.activeTabID != standaloneTabID)
        model.selectTab(standaloneTabID)

        #expect(model.selectAdjacentTabGroup(offset: 1))
        #expect(model.activeFolderURL == first.standardizedFileURL)
        #expect(model.activeTerminalID == firstTerminalID)
        #expect(model.selectAdjacentTabGroup(offset: -1))
        #expect(model.activeFolderURL == nil)
        #expect(model.activeTabID == standaloneTabID)
        #expect(model.selectAdjacentTabGroup(offset: -1))
        #expect(model.activeFolderURL == third.standardizedFileURL)
    }

    @Test @MainActor
    func commandDSplitsCurrentTerminalToTheRight() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let tabID = try #require(model.activeTabID)
        let firstID = try #require(model.activeTerminalID)

        model.splitActiveTerminal(direction: .right)

        let secondID = try #require(model.activeTerminalID)
        let tab = try #require(model.activeTerminalTab)
        #expect(model.activeTabID == tabID)
        #expect(secondID != firstID)
        #expect(model.terminalSessions.count == 2)
        #expect(model.activeScopeTabs.count == 1)
        #expect(tab.terminalIDs == [firstID, secondID])
        let splitSession = try #require(
            model.terminalSessions.first { $0.id == secondID }
        )
        #expect(splitSession.terminal.configuration.context == .split)
        guard case let .split(_, axis, _, first, second) = tab.root else {
            Issue.record("Expected a split root")
            return
        }
        #expect(axis == .horizontal)
        #expect(first == .pane(firstID))
        #expect(second == .pane(secondID))
        #expect(model.canSelectSplit(in: .left))
        #expect(!model.canSelectSplit(in: .right))
        #expect(!model.canSelectSplit(in: .up))
        #expect(!model.canSelectSplit(in: .down))

        model.selectTerminal(firstID)
        #expect(!model.canSelectSplit(in: .left))
        #expect(model.canSelectSplit(in: .right))
        #expect(!model.canSelectSplit(in: .up))
        #expect(!model.canSelectSplit(in: .down))
    }

    @Test @MainActor
    func verticalSplitOnlyEnablesAvailableMenuDirections() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let topID = try #require(model.activeTerminalID)

        model.splitActiveTerminal(direction: .down)

        #expect(model.canSelectSplit(in: .up))
        #expect(!model.canSelectSplit(in: .down))
        #expect(!model.canSelectSplit(in: .left))
        #expect(!model.canSelectSplit(in: .right))

        model.selectTerminal(topID)
        #expect(!model.canSelectSplit(in: .up))
        #expect(model.canSelectSplit(in: .down))
        #expect(!model.canSelectSplit(in: .left))
        #expect(!model.canSelectSplit(in: .right))
    }

    @Test @MainActor
    func repeatedSplitsRebalanceRowsAndColumns() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )

        for _ in 0 ..< 3 {
            model.splitActiveTerminal(direction: .right)
        }
        for _ in 0 ..< 2 {
            model.splitActiveTerminal(direction: .down)
        }

        let tab = try #require(model.activeTerminalTab)
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
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let leftID = try #require(model.activeTerminalID)
        model.splitActiveTerminal(direction: .right)
        let upperRightID = try #require(model.activeTerminalID)

        #expect(model.selectSplit(in: .left))
        #expect(model.activeTerminalID == leftID)
        #expect(model.selectSplit(in: .right))
        #expect(model.activeTerminalID == upperRightID)

        model.splitActiveTerminal(direction: .down)
        let lowerRightID = try #require(model.activeTerminalID)
        #expect(model.selectSplit(in: .up))
        #expect(model.activeTerminalID == upperRightID)
        #expect(model.selectSplit(in: .down))
        #expect(model.activeTerminalID == lowerRightID)
    }

    @Test @MainActor
    func closingSplitCollapsesLayoutAndFocusesSibling() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let firstID = try #require(model.activeTerminalID)
        model.splitActiveTerminal(direction: .right)
        let secondID = try #require(model.activeTerminalID)
        model.splitActiveTerminal(direction: .down)
        let thirdID = try #require(model.activeTerminalID)

        model.closeTerminal(thirdID)

        #expect(model.activeTerminalID == secondID)
        #expect(model.activeTerminalTab?.terminalIDs == [firstID, secondID])

        model.closeTerminal(secondID)

        #expect(model.activeTerminalID == firstID)
        #expect(model.activeTerminalTab?.root == .pane(firstID))
        #expect(model.activeScopeTabs.count == 1)
    }

    @Test @MainActor
    func tabNavigationSkipsOtherPanesInCurrentTab() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let firstPaneID = try #require(model.activeTerminalID)
        model.splitActiveTerminal(direction: .right)
        model.openNewTerminal(for: folder)
        let secondTabPaneID = try #require(model.activeTerminalID)
        model.selectTerminal(firstPaneID)

        #expect(model.selectAdjacentTab(offset: 1))
        #expect(model.activeTerminalID == secondTabPaneID)
        #expect(model.selectAdjacentTab(offset: -1))
        #expect(model.activeTerminalID == firstPaneID)
    }

    @Test @MainActor
    func closingSplitTabClosesEveryPaneAndSelectsAdjacentTab() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        model.splitActiveTerminal(direction: .right)
        let splitTabID = try #require(model.activeTerminalTab?.id)
        model.openNewTerminal(for: folder)
        let adjacentTabID = try #require(model.activeTerminalTab?.id)
        let adjacentTerminalID = try #require(model.activeTerminalID)
        model.selectTab(splitTabID)

        model.closeTab(splitTabID)

        #expect(model.terminalTabs.map(\.id) == [adjacentTabID])
        #expect(model.terminalSessions.count == 1)
        #expect(model.activeTerminalID == adjacentTerminalID)
    }

    @Test @MainActor
    func commandShiftTRestoresMostRecentlyClosedTerminal() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        model.openNewTerminal(for: folder)
        let closedID = try #require(model.activeTerminalID)

        model.closeTerminal(closedID)

        #expect(model.canRestoreClosedTerminal)
        #expect(model.activeFolderSessions.count == 1)

        model.restoreLastClosedTerminal()

        #expect(!model.canRestoreClosedTerminal)
        #expect(model.activeFolderSessions.count == 2)
        #expect(model.activeTerminalID != closedID)
    }

    @Test @MainActor
    func closingLastTerminalClearsSelectionAndRequestsWindowClose() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let terminalID = try #require(model.activeTerminalID)
        var closeWindowRequestCount = 0
        model.closeWindowHandler = {
            closeWindowRequestCount += 1
        }

        model.closeTerminal(terminalID)

        #expect(model.activeTabID == nil)
        #expect(model.activeTerminalID == nil)
        #expect(model.activeFolderURL == nil)
        #expect(model.activeScopeTabs.isEmpty)
        #expect(model.activeFolderSessions.isEmpty)
        #expect(!model.hasTerminalSession(in: folder))
        #expect(closeWindowRequestCount == 1)
    }

    @Test @MainActor
    func exitingTerminalClosesItsTab() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let firstID = try #require(model.activeTerminalID)
        model.openNewTerminal(for: folder)
        let exitingID = try #require(model.activeTerminalID)
        let exitingTerminal = try #require(
            model.terminalSessions.first { $0.id == exitingID }?.terminal
        )

        exitingTerminal.onClose?(false)

        #expect(model.activeTerminalID == firstID)
        #expect(model.terminalSessionCount(in: folder) == 1)
        #expect(!model.terminalSessions.contains { $0.id == exitingID })
        #expect(!model.canRestoreClosedTerminal)
    }

    @Test @MainActor
    func openingAnotherFolderKeepsExistingFoldersAndTerminals() throws {
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

        let model = AppModel(
            defaults: isolatedDefaults(scope: first),
            initialFolderURL: first
        )
        let firstID = try #require(model.activeTerminalID)
        model.openNewTerminal(for: first)
        #expect(model.terminalSessions.count == 2)

        #expect(model.addFolder(second) == .added(second))
        let secondID = try #require(model.activeTerminalID)
        #expect(secondID != firstID)
        #expect(model.activeFolderURL == second.standardizedFileURL)
        #expect(model.folderURLs == [first, second])
        #expect(model.terminalSessions.count == 3)
        #expect(model.terminalSessions.contains { $0.id == firstID })

        model.activateFolder(first)
        #expect(model.activeTerminalID != secondID)
        #expect(model.terminalSessions.count == 3)
    }

    @Test @MainActor
    func terminalTabsCanBeReordered() throws {
        defer { removeIsolatedDefaults() }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            defaults: isolatedDefaults(scope: folder),
            initialFolderURL: folder
        )
        let firstID = try #require(model.activeTerminalID)
        model.openNewTerminal(for: folder)
        let secondID = try #require(model.activeTerminalID)

        model.setTabOrder([secondID, firstID])

        #expect(model.activeScopeTabs.map(\.id) == [secondID, firstID])
    }

    @Test @MainActor
    func appSettingsPersist() {
        defer { removeIsolatedDefaults() }
        let folder = FileManager.default.temporaryDirectory
        let defaults = isolatedDefaults(scope: folder)
        let settings = AppSettings(defaults: defaults)
        let customMemoPath = folder
            .appendingPathComponent("missing/memo.md")
            .path
        #expect(
            settings.ghosttyConfigPath
                == AppSettings.defaultGhosttyConfigPath
        )
        #expect(settings.memoFilePath == AppSettings.defaultMemoFilePath)
        #expect(settings.isMemoFilePathValid)
        settings.appearance = .dark
        settings.ghosttyConfigPath = "~/terminal/ghostty.conf"
        settings.memoFilePath = customMemoPath
        #expect(!settings.isGhosttyConfigPathValid)
        #expect(!settings.isMemoFilePathValid)

        let restored = AppSettings(defaults: defaults)
        #expect(restored.appearance == .dark)
        #expect(restored.ghosttyConfigPath == "~/terminal/ghostty.conf")
        #expect(restored.memoFilePath == customMemoPath)
    }

    @Test @MainActor
    func ghosttyConfigPathResolvesExistingCustomFile() throws {
        defer { removeIsolatedDefaults() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("ghostty.conf")
        try "font-size = 15\n".write(to: config, atomically: true, encoding: .utf8)
        let settings = AppSettings(
            defaults: isolatedDefaults(scope: directory)
        )

        settings.ghosttyConfigPath = config.path

        #expect(settings.resolvedGhosttyConfigURL == config)
        #expect(settings.isGhosttyConfigPathValid)
        #expect(
            settings.ghosttyConfigSource == .file(config.path)
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
