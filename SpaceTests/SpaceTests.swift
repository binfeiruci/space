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
    func nonShellTitleKeepsPath() {
        let session = TerminalSession(
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            defaultShellPath: "/bin/zsh"
        )

        #expect(session.displayTitle(
            terminalTitle: "file:///tmp/project",
            foregroundProcessName: "vim"
        ) == "file:///tmp/project")
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
    func sessionStructureIsNotRestoredAcrossLaunches() throws {
        let defaults = isolatedDefaults()
        let first = AppModel(defaults: defaults)
        first.openNewTerminal()
        #expect(first.terminalTabs.count == 2)

        let relaunched = AppModel(defaults: defaults)
        #expect(relaunched.terminalTabs.count == 1)
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

        model.setTabOrder([secondID, firstID])

        #expect(model.terminalTabs.map(\.id) == [secondID, firstID])
        #expect(model.terminalSession(id: firstSession.id) === firstSession)
        #expect(model.terminalTab(id: firstID)?.terminalIDs == firstTerminalIDs)
    }

    @Test @MainActor
    func tabNavigationUsesTabOrder() throws {
        let model = AppModel(defaults: isolatedDefaults())
        let firstID = try #require(model.activeTabID)
        model.openNewTerminal()
        let secondID = try #require(model.activeTabID)
        model.openNewTerminal()
        let thirdID = try #require(model.activeTabID)
        model.setTabOrder([secondID, thirdID, firstID])
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
