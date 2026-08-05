import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Space

private actor StubProcessInspector: TerminalProcessInspecting {
    private var namesBySessionID: [UUID: String] = [:]
    private var requestCount = 0

    func processNames(
        for requests: [TerminalProcessInspector.Request]
    ) -> [UUID: String] {
        requestCount += 1
        return namesBySessionID
    }

    func setNames(_ names: [UUID: String]) {
        namesBySessionID = names
    }

    func requestsReceived() -> Int { requestCount }
}

@Suite(.serialized)
struct SpaceTests {
    private func isolatedDefaults() -> UserDefaults {
        let name = "SpaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    private func nextMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test
    func quitPromptOnlyAppearsForRunningPrograms() {
        let idle = ApplicationTerminationPrompt(runningProgramNames: [])
        let active = ApplicationTerminationPrompt(
            runningProgramNames: ["vim", "top", "top"]
        )

        #expect(!idle.requiresConfirmation)
        #expect(idle.informativeText.isEmpty)
        #expect(active.requiresConfirmation)
        #expect(active.informativeText.contains("3 terminals"))
        #expect(active.informativeText.contains("top, vim"))
    }

    @Test @MainActor
    func shortcutsRecognizeTabsAndAdjacentNavigation() {
        #expect(TerminalTabSelectionShortcut.index(
            characters: "1",
            modifierFlags: .command
        ) == 0)
        #expect(TerminalTabSelectionShortcut.index(
            characters: "9",
            modifierFlags: .command
        ) == 8)
        #expect(AdjacentTabShortcut.offset(
            keyCode: 33,
            characters: "{",
            modifierFlags: [.command, .shift]
        ) == -1)
        #expect(AdjacentTabShortcut.offset(
            keyCode: 30,
            characters: "}",
            modifierFlags: [.command, .shift]
        ) == 1)
    }

    @Test
    func terminalSearchActionsUseGhosttyBindingSyntax() {
        #expect(TerminalSearchAction.update(query: "needle") == "search:needle")
        #expect(TerminalSearchAction.navigate(forward: true)
            == "navigate_search:next")
        #expect(TerminalSearchAction.navigate(forward: false)
            == "navigate_search:previous")
        #expect(TerminalSearchAction.end == "end_search")
    }

    @Test @MainActor
    func shellTitleUsesCurrentDirectoryName() {
        let session = TerminalSession(
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/initial"),
            defaultShellPath: "/bin/zsh"
        )

        #expect(session.displayTitle(
            terminalTitle: "/tmp/current/project",
            foregroundProcessName: "zsh",
            currentWorkingDirectory: "/tmp/current/project"
        ) == "project")
        #expect(session.displayTitle(
            terminalTitle: "/",
            foregroundProcessName: "zsh",
            currentWorkingDirectory: "/"
        ) == "/")
        #expect(session.displayTitle(
            terminalTitle: "~",
            foregroundProcessName: "zsh",
            currentWorkingDirectory: FileManager.default
                .homeDirectoryForCurrentUser.path
        ) == "~")
    }

    @Test @MainActor
    func terminalTitleOnlyIgnoresHomeDirectoryPath() {
        let session = TerminalSession(
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            defaultShellPath: "/bin/zsh"
        )
        let homeURL = FileManager.default.homeDirectoryForCurrentUser

        #expect(session.displayTitle(
            terminalTitle: "file:///tmp/project",
            foregroundProcessName: "vim"
        ) == "file:///tmp/project")
        #expect(session.displayTitle(
            terminalTitle: homeURL.path,
            foregroundProcessName: "vim"
        ) == "vim")
        #expect(session.displayTitle(
            terminalTitle: homeURL.absoluteString,
            foregroundProcessName: "vim"
        ) == homeURL.absoluteString)
        #expect(session.displayTitle(
            terminalTitle: "Editing README.md",
            foregroundProcessName: "vim"
        ) == "Editing README.md")
    }

    @Test @MainActor
    func appStartsWithOneHomeTab() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let session = try #require(model.activeTerminalSession)

        #expect(model.terminalTabs.count == 1)
        #expect(session.workingDirectoryURL
            == FileManager.default.homeDirectoryForCurrentUser)
        #expect(session.terminal.theme == .init())
        #expect(session.terminal.controller.currentConfigSource == .defaultFiles)
    }

    @Test @MainActor
    func staleSplitContainerCannotStealTerminalView() async throws {
        let model = AppModel(defaults: isolatedDefaults())
        let session = try #require(model.activeTerminalSession)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let liveContainer = SpaceTerminalContainerView(
            frame: window.contentView!.bounds
        )
        window.contentView?.addSubview(liveContainer)
        let terminalView = NSView(frame: .zero)
        liveContainer.attach(terminalView, for: session)
        await nextMainRunLoop()
        #expect(terminalView.superview === liveContainer)

        let replacementContainer = SpaceTerminalContainerView(
            frame: liveContainer.frame
        )
        replacementContainer.attach(terminalView, for: session)
        await nextMainRunLoop()
        #expect(terminalView.superview === liveContainer)

        window.contentView?.addSubview(replacementContainer)
        await nextMainRunLoop()
        #expect(terminalView.superview === liveContainer)

        liveContainer.removeFromSuperview()
        replacementContainer.attach(terminalView, for: session)
        await nextMainRunLoop()
        #expect(terminalView.superview === replacementContainer)

        liveContainer.attach(terminalView, for: session)
        await nextMainRunLoop()
        #expect(terminalView.superview === replacementContainer)
    }

    @Test @MainActor
    func reusedSplitContainerClaimsTheNewSession() async throws {
        let model = AppModel(defaults: isolatedDefaults())
        let firstSession = try #require(model.activeTerminalSession)
        model.splitActiveTerminal(direction: .right)
        let secondSession = try #require(model.activeTerminalSession)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let reusedContainer = SpaceTerminalContainerView(
            frame: window.contentView!.bounds
        )
        window.contentView?.addSubview(reusedContainer)
        let oldTerminalView = NSView(frame: .zero)
        reusedContainer.attach(oldTerminalView, for: firstSession)
        await nextMainRunLoop()
        #expect(oldTerminalView.superview === reusedContainer)

        let newTerminalView = NSView(frame: .zero)
        reusedContainer.attach(newTerminalView, for: secondSession)
        await nextMainRunLoop()

        #expect(firstSession.terminalContainer == nil)
        #expect(secondSession.terminalContainer === reusedContainer)
        #expect(oldTerminalView.superview == nil)
        #expect(newTerminalView.superview === reusedContainer)
    }

    @Test @MainActor
    func defaultFilesRemainBaseForTerminalOverrides() {
        let configuration = TerminalConfiguration().fontSize(17)
        let controller = TerminalController(
            configSource: .defaultFiles,
            theme: .init(),
            terminalConfiguration: configuration
        )

        #expect(controller.currentConfigSource
            == .defaultFilesWithOverrides("font-size = 17\n"))
    }

    @Test @MainActor
    func tabsDirectoriesSelectionAndDividersRestoreAcrossLaunches() throws {
        let defaults = isolatedDefaults()
        let first = AppModel(defaults: defaults)
        let firstTabID = try #require(first.activeTabID)
        let firstSession = try #require(first.activeTerminalSession)
        first.openNewTerminal()
        let secondSession = try #require(first.activeTerminalSession)
        first.addTabDivider(after: firstTabID)
        first.selectTab(firstTabID)
        firstSession.terminal.terminalDidChangeWorkingDirectory("/tmp")
        secondSession.terminal.terminalDidChangeWorkingDirectory("/")
        let delegate = SpaceAppDelegate()
        delegate.model = first
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        #expect(first.terminalTabs.count == 2)

        let relaunched = AppModel(defaults: defaults)
        #expect(relaunched.terminalTabs.count == 2)
        #expect(relaunched.tabSidebarItems.count == 3)
        #expect(relaunched.tabSidebarItems[0].tabID != nil)
        #expect(relaunched.tabSidebarItems[1].dividerID != nil)
        #expect(relaunched.tabSidebarItems[2].tabID != nil)
        #expect(relaunched.activeTabID == relaunched.terminalTabs[0].id)
        #expect(relaunched.terminalSessions[0].workingDirectoryURL
            == URL(fileURLWithPath: "/tmp").standardizedFileURL)
        #expect(relaunched.terminalSessions[1].workingDirectoryURL
            == URL(fileURLWithPath: "/").standardizedFileURL)
    }

    @Test @MainActor
    func newTabsAndSplitsStartInHomeDirectory() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let initialSession = try #require(model.activeTerminalSession)
        initialSession.terminal.terminalDidChangeWorkingDirectory("/tmp")

        model.splitActiveTerminal(direction: .right)
        let splitSession = try #require(model.activeTerminalSession)
        #expect(splitSession.workingDirectoryURL
            == FileManager.default.homeDirectoryForCurrentUser)

        model.openNewTerminal()
        let tabSession = try #require(model.activeTerminalSession)
        #expect(tabSession.workingDirectoryURL
            == FileManager.default.homeDirectoryForCurrentUser)
        #expect(model.terminalTabs.count == 2)
    }

    @Test @MainActor
    func tabsCanBeReorderedWithoutRecreatingSessionsOrSplits() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let firstID = try #require(model.activeTabID)
        let firstSession = try #require(model.activeTerminalSession)
        model.splitActiveTerminal(direction: .right)
        let firstTerminalIDs = try #require(
            model.terminalTab(id: firstID)
        ).terminalIDs
        model.openNewTerminal()
        let secondID = try #require(model.activeTabID)

        model.moveTabSidebarItems(from: IndexSet(integer: 0), to: 2)

        #expect(model.terminalTabs.map(\.id) == [secondID, firstID])
        #expect(model.terminalSession(id: firstSession.id) === firstSession)
        #expect(model.terminalTab(id: firstID)?.terminalIDs == firstTerminalIDs)
    }

    @Test @MainActor
    func newTabBelowIsInsertedAfterSelectedSidebarTab() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let firstID = try #require(model.activeTabID)
        model.openNewTerminal()
        let secondID = try #require(model.activeTabID)
        model.addTabDivider(after: firstID)
        let dividerID = try #require(model.tabSidebarItems[1].dividerID)

        model.openNewTerminal(after: firstID)

        let insertedID = try #require(model.activeTabID)
        #expect(model.terminalTabs.map(\.id) == [
            firstID, insertedID, secondID,
        ])
        #expect(model.tabSidebarItems == [
            .tab(firstID),
            .tab(insertedID),
            .divider(dividerID),
            .tab(secondID),
        ])
        #expect(model.activeTerminalSession?.workingDirectoryURL
            == FileManager.default.homeDirectoryForCurrentUser)
    }

    @Test @MainActor
    func tabDividerIsAnIndependentReorderableSidebarItem() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let firstID = try #require(model.activeTabID)
        model.openNewTerminal()
        let secondID = try #require(model.activeTabID)
        model.openNewTerminal()
        let thirdID = try #require(model.activeTabID)
        model.openNewTerminal()
        let fourthID = try #require(model.activeTabID)

        model.addTabDivider(after: secondID)
        let dividerID = try #require(model.tabSidebarItems[2].dividerID)

        model.moveTabSidebarItems(from: IndexSet(integer: 0), to: 4)
        #expect(model.terminalTabs.map(\.id) == [
            secondID, thirdID, firstID, fourthID,
        ])

        model.moveTabSidebarItems(from: IndexSet(integer: 1), to: 4)
        #expect(model.tabSidebarItems[3].dividerID == dividerID)

        model.removeTabDivider(id: dividerID)
        #expect(!model.tabSidebarItems.contains(.divider(dividerID)))
    }

    @Test @MainActor
    func singletonTabCanMoveAcrossDivider() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let firstID = try #require(model.activeTabID)
        model.openNewTerminal()
        let secondID = try #require(model.activeTabID)
        model.addTabDivider(after: firstID)
        let dividerID = try #require(model.tabSidebarItems[1].dividerID)

        model.moveTabSidebarItems(from: IndexSet(integer: 0), to: 3)
        #expect(model.tabSidebarItems == [
            .divider(dividerID), .tab(secondID), .tab(firstID),
        ])
        #expect(model.terminalTabs.map(\.id) == [secondID, firstID])

        model.moveTabSidebarItems(from: IndexSet(integer: 0), to: 2)
        #expect(model.tabSidebarItems == [
            .tab(secondID), .divider(dividerID), .tab(firstID),
        ])
    }

    @Test @MainActor
    func dividerCanBeAddedAfterLastTab() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let firstID = try #require(model.activeTabID)
        model.openNewTerminal()
        let lastID = try #require(model.activeTabID)

        model.addTabDivider(after: lastID)
        let dividerID = try #require(model.tabSidebarItems.last?.dividerID)
        #expect(model.tabSidebarItems == [
            .tab(firstID), .tab(lastID), .divider(dividerID),
        ])
    }

    @Test @MainActor
    func multipleDividersCanBeAddedAfterTheSameTab() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let tabID = try #require(model.activeTabID)

        model.addTabDivider(after: tabID)
        model.addTabDivider(after: tabID)

        #expect(model.tabSidebarItems.count == 3)
        #expect(model.tabSidebarItems[0] == .tab(tabID))
        #expect(model.tabSidebarItems[1].dividerID != nil)
        #expect(model.tabSidebarItems[2].dividerID != nil)
        #expect(model.tabSidebarItems[1] != model.tabSidebarItems[2])
    }

    @Test @MainActor
    func tabNavigationUsesTabOrder() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let firstID = try #require(model.activeTabID)
        model.openNewTerminal()
        let secondID = try #require(model.activeTabID)
        model.openNewTerminal()
        let thirdID = try #require(model.activeTabID)
        model.moveTabSidebarItems(from: IndexSet(integer: 0), to: 3)
        #expect(model.terminalTabs.map(\.id) == [secondID, thirdID, firstID])

        model.selectTab(secondID)
        #expect(model.selectAdjacentTab(offset: 1))
        #expect(model.activeTabID == thirdID)
    }

    @Test @MainActor
    func directionalSplitNavigationUsesPaneGeometry() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let topLeftID = try #require(model.activeTerminalID)

        model.splitActiveTerminal(direction: .right)
        let topRightID = try #require(model.activeTerminalID)
        model.splitActiveTerminal(direction: .down)
        let bottomRightID = try #require(model.activeTerminalID)

        model.selectTerminal(topLeftID)
        model.splitActiveTerminal(direction: .down)

        #expect(model.selectSplit(in: .right))
        #expect(model.activeTerminalID == bottomRightID)
        #expect(model.selectSplit(in: .up))
        #expect(model.activeTerminalID == topRightID)
        #expect(model.selectSplit(in: .left))
        #expect(model.activeTerminalID == topLeftID)
    }

    @Test @MainActor
    func closingFocusedSplitSelectsPreviousPane() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let firstID = try #require(model.activeTerminalID)

        model.splitActiveTerminal(direction: .right)
        let secondID = try #require(model.activeTerminalID)
        let secondSession = try #require(model.activeTerminalSession)
        model.splitActiveTerminal(direction: .right)
        let thirdID = try #require(model.activeTerminalID)

        model.closeTerminal(thirdID)
        #expect(model.activeTerminalID == secondID)
        #expect(secondSession.terminalFocusRequest == 1)

        model.selectTerminal(firstID)
        model.closeTerminal(firstID)
        #expect(model.activeTerminalID == secondID)
    }

    @Test @MainActor
    func configurationAvailabilityDoesNotResolveConfigPath() {
        var configPathWasResolved = false
        let configurationFile = GhosttyConfigurationFile(
            configURL: {
                configPathWasResolved = true
                return nil
            },
            editorURL: { URL(fileURLWithPath: "/Applications/TextEdit.app") }
        )

        #expect(configurationFile.isAvailable)
        #expect(!configPathWasResolved)
    }

    @Test @MainActor
    func refreshingProcessNamesUsesInjectedInspector() async throws {
        let inspector = StubProcessInspector()
        let model = AppModel(
            defaults: isolatedDefaults(),
            processInspector: inspector
        )
        let session = try #require(model.activeTerminalSession)
        await inspector.setNames([session.id: "vim"])

        await model.refreshTerminalProcessNames()

        #expect(session.currentProcessName == "vim")
        #expect(await inspector.requestsReceived() == 1)
    }

    @Test @MainActor
    func settingsStillPersistIndependentlyOfSessions() {
        let defaults = isolatedDefaults()
        let model = AppModel(defaults: defaults)
        model.settings.appearance = .dark

        let restored = AppSettings(defaults: defaults)
        #expect(restored.appearance == .dark)
    }
}
