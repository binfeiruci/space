import AppKit
import Combine
import CoreGraphics
import Foundation
import GhosttyTerminal

struct UnreadTitleActivityEvent: Equatable {
    let tabID: UUID
    private let occurrenceID = UUID()
}

private struct FolderLaunchState {
    enum Selection {
        case standalone
        case folder(URL)
    }

    let trackedFolders: [URL]
    let recentFolders: [URL]
    let openFolders: [URL]
    let includesStandaloneTab: Bool
    let selection: Selection

    init(
        initialFolder: URL?,
        recentFolders: [URL],
        workspace: FolderWorkspaceState
    ) {
        if let initialFolder {
            trackedFolders = [initialFolder]
            self.recentFolders = [initialFolder]
            openFolders = [initialFolder]
            includesStandaloneTab = false
            selection = .folder(initialFolder)
            return
        }

        self.recentFolders = recentFolders
        openFolders = workspace.openFolders
        includesStandaloneTab = true

        var trackedFolders = recentFolders
        var trackedPaths = Set(recentFolders.map(\.standardizedFileURL.path))
        for folder in openFolders {
            let path = folder.standardizedFileURL.path
            if trackedPaths.insert(path).inserted {
                trackedFolders.append(folder)
            }
        }
        self.trackedFolders = trackedFolders

        let activePath = workspace.activeFolder?.standardizedFileURL.path
        if let activeFolder = openFolders.first(where: {
            $0.standardizedFileURL.path == activePath
        }) {
            selection = .folder(activeFolder)
        } else {
            selection = .standalone
        }
    }

    var trackedFoldersInOrder: [URL] {
        let openPaths = Set(openFolders.map(\.standardizedFileURL.path))
        return openFolders + trackedFolders.filter {
            !openPaths.contains($0.standardizedFileURL.path)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var folders: [Folder]
    @Published private var folderOrderPaths: [String]
    @Published private var recentFolderPaths: [String]
    @Published private(set) var terminalSessions: [TerminalSession] {
        willSet { workspaceIndex.indexSessions(newValue) }
    }
    @Published private(set) var terminalTabs: [TerminalTabState] {
        willSet { workspaceIndex.indexTabs(newValue) }
    }
    @Published private(set) var activeTabID: UUID? {
        didSet {
            markActiveTabRead()
        }
    }
    @Published private(set) var alertRequest: AlertRequest?
    @Published private(set) var renameRequest: TabRenameRequest?
    @Published private(set) var memoSaveNotice: MemoSaveNotice?
    @Published private(set) var isFolderImporterPresented = false
    @Published private(set) var isSidebarVisible = true
    @Published private(set) var agentAttentionByTerminalID:
        [UUID: AgentAttentionNotification] = [:]
    @Published private var refreshingTitleFrameByTerminalID: [UUID: String] = [:]
    @Published private(set) var unreadTitleTabIDs: Set<UUID> = []
    @Published private(set) var latestUnreadTitleActivity:
        UnreadTitleActivityEvent?

    let settings: AppSettings
    var agentAttentionHandler: ((UUID) -> Void)?
    var closeWindowHandler: (() -> Void)?

    private let folderStore: FolderStore
    private let processInspector: any TerminalProcessInspecting
    private let memoWriter = MemoWriter()
    private let agentAttentionCoordinator = AgentAttentionCoordinator()
    private var workspaceIndex = TerminalWorkspaceIndex()
    private var terminalRuntimeMonitorTask: Task<Void, Never>?
    private var terminalTitleCancellables: [UUID: AnyCancellable] = [:]
    private var recentlyClosedTerminalLocations: [ClosedTerminalLocation] = []
    private var lastActiveStandaloneTabID: UUID?
    private var lastActiveTabIDByFolderPath: [String: UUID] = [:]
    private static let recentFolderLimit = 15

    init(
        defaults: UserDefaults = .standard,
        initialFolderURL: URL? = nil,
        processInspector: (any TerminalProcessInspecting)? = nil
    ) {
        folderStore = FolderStore(defaults: defaults)
        self.processInspector = processInspector ?? TerminalProcessInspector()
        settings = AppSettings(defaults: defaults)

        let launchState = FolderLaunchState(
            initialFolder: FolderStore.validFolderURL(initialFolderURL),
            recentFolders: folderStore.restoreRecentFolders(
                limit: Self.recentFolderLimit
            ),
            workspace: folderStore.restoreWorkspace()
        )

        folders = launchState.trackedFolders.map { Folder(url: $0) }
        folderOrderPaths = launchState.trackedFoldersInOrder.map {
            $0.standardizedFileURL.path
        }
        recentFolderPaths = launchState.recentFolders.map {
            $0.standardizedFileURL.path
        }
        terminalSessions = []
        terminalTabs = []
        activeTabID = nil

        restoreTabs(from: launchState)
        workspaceIndex.indexSessions(terminalSessions)
        workspaceIndex.indexTabs(terminalTabs)
        persistRecentFolders()
        persistFolderWorkspace()
    }

    private func restoreTabs(from launchState: FolderLaunchState) {
        if launchState.includesStandaloneTab {
            let session = appendTerminalTab(
                workingDirectoryURL: FileManager.default
                    .homeDirectoryForCurrentUser,
                ownerFolderURL: nil
            )
            lastActiveStandaloneTabID = session.id
        }

        for folderURL in launchState.openFolders {
            let session = appendTerminalTab(
                workingDirectoryURL: folderURL,
                ownerFolderURL: folderURL
            )
            lastActiveTabIDByFolderPath[folderURL.path] = session.id
        }

        switch launchState.selection {
        case .standalone:
            activeTabID = lastActiveStandaloneTabID
        case let .folder(folderURL):
            let activePath = folderURL.standardizedFileURL.path
            activeTabID = terminalTabs.first {
                $0.ownerFolderURL?.standardizedFileURL.path == activePath
            }?.id
        }
    }

    @discardableResult
    private func appendTerminalTab(
        workingDirectoryURL: URL,
        ownerFolderURL: URL?
    ) -> TerminalSession {
        let session = TerminalSession(
            workingDirectoryURL: workingDirectoryURL,
            settings: settings
        )
        bindCloseHandler(to: session)
        terminalSessions.append(session)
        terminalTabs.append(TerminalTabState(
            id: session.id,
            ownerFolderURL: ownerFolderURL,
            root: .pane(session.id),
            focusedTerminalID: session.id
        ))
        return session
    }

    var folderURLs: [URL] {
        folders.map(\.url)
    }

    var recentFolders: [Folder] {
        let foldersByPath = Dictionary(
            uniqueKeysWithValues: folders.map {
                ($0.url.standardizedFileURL.path, $0)
            }
        )
        return recentFolderPaths.compactMap { foldersByPath[$0] }
    }

    var activeScopeTabs: [TerminalTabState] {
        guard let activeTerminalTab else { return [] }
        return terminalTabs.filter {
            $0.ownerFolderURL == activeTerminalTab.ownerFolderURL
        }
    }

    var standaloneTabs: [TerminalTabState] {
        terminalTabs.filter { $0.ownerFolderURL == nil }
    }

    var foldersWithTabs: [Folder] {
        storedFoldersInOrder.filter(folderHasTabs)
    }

    var trackedFoldersInOrder: [Folder] {
        foldersWithTabs + storedFoldersInOrder.filter { !folderHasTabs($0) }
    }

    var tabsInSidebarOrder: [TerminalTabState] {
        let folderTabs = foldersWithTabs.flatMap { folder in
            let folderPath = folder.url.standardizedFileURL.path
            return terminalTabs.filter {
                $0.ownerFolderURL?.standardizedFileURL.path == folderPath
            }
        }
        return standaloneTabs + folderTabs
    }

    var tabGroupCount: Int {
        foldersWithTabs.count + (standaloneTabs.isEmpty ? 0 : 1)
    }

    var unreadTitleFolderPaths: Set<String> {
        Set(terminalTabs.compactMap { tab in
            guard unreadTitleTabIDs.contains(tab.id) else { return nil }
            return tab.ownerFolderURL?.standardizedFileURL.path
        })
    }

    private var storedFoldersInOrder: [Folder] {
        let orderByPath = Dictionary(
            uniqueKeysWithValues: folderOrderPaths.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        return folders.sorted { lhs, rhs in
            let lhsPath = lhs.url.standardizedFileURL.path
            let rhsPath = rhs.url.standardizedFileURL.path
            return orderByPath[lhsPath, default: .max]
                < orderByPath[rhsPath, default: .max]
        }
    }

    func folderHasTabs(_ folder: Folder) -> Bool {
        let folderPath = folder.url.standardizedFileURL.path
        return terminalTabs.contains {
            $0.ownerFolderURL?.standardizedFileURL.path == folderPath
        }
    }

    var activeTerminalTab: TerminalTabState? {
        guard let activeTabID else { return nil }
        return terminalTab(id: activeTabID)
    }

    var activeTerminalID: UUID? {
        activeTerminalTab?.focusedTerminalID
    }

    var activeFolderURL: URL? {
        activeTerminalTab?.ownerFolderURL
    }

    var activeTabTerminalIDs: [UUID] {
        activeTerminalTab?.terminalIDs ?? []
    }

    var activeTerminalSession: TerminalSession? {
        guard let activeTerminalID else { return nil }
        return terminalSession(id: activeTerminalID)
    }

    func terminalSession(id: UUID) -> TerminalSession? {
        workspaceIndex.session(id: id)
    }

    private func terminalSessionIndex(id: UUID) -> Int? {
        workspaceIndex.sessionIndex(id: id)
    }

    func terminalTab(id: UUID) -> TerminalTabState? {
        workspaceIndex.tabIndex(id: id).map { terminalTabs[$0] }
    }

    private func terminalTabIndex(containing terminalID: UUID) -> Int? {
        workspaceIndex.tabIndex(containing: terminalID)
    }

    var canRestoreClosedTerminal: Bool {
        !recentlyClosedTerminalLocations.isEmpty
    }

    func startTerminalRuntimeMonitoring() {
        guard terminalRuntimeMonitorTask == nil else { return }
        terminalRuntimeMonitorTask = Task { [weak self] in
            await self?.monitorTerminalRuntime()
        }
    }

    func stopTerminalRuntimeMonitoring() {
        terminalRuntimeMonitorTask?.cancel()
        terminalRuntimeMonitorTask = nil
    }

    var isTerminalRuntimeMonitoring: Bool {
        terminalRuntimeMonitorTask != nil
    }

    func refreshTerminalProcessNames() async {
        let requests = terminalSessions.compactMap(
            \.processInspectionRequest
        )
        let namesBySessionID = await processInspector.processNames(
            for: requests
        )
        guard !Task.isCancelled else { return }
        for session in terminalSessions {
            session.updateCurrentProcessName(
                namesBySessionID[session.id]
            )
        }
    }

    private func monitorTerminalRuntime() async {
        while !Task.isCancelled {
            let applicationIsActive = NSApp.isActive
            let displayedTerminalIDs = Set(activeTabTerminalIDs)
            for session in terminalSessions
            where !displayedTerminalIDs.contains(session.id) {
                session.terminal.controller.tick()
            }

            await refreshTerminalProcessNames()
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: TerminalRuntimeMonitoringPolicy.interval(
                    applicationIsActive: applicationIsActive,
                    sidebarIsVisible: isSidebarVisible
                ))
            } catch {
                return
            }
        }
    }

    func chooseFolder() {
        isFolderImporterPresented = true
    }

    func dismissFolderImporter() {
        isFolderImporterPresented = false
    }

    func sendActiveSelectionToMemo() {
        guard let session = activeTerminalSession,
              let terminalView = session.terminalView else { return }

        let pasteboard = NSPasteboard.general
        guard let selection = TerminalSelectionReader.selection(
            from: pasteboard,
            copyingSelection: terminalView.copySelectedTextToPasteboard
        ) else {
            memoSaveNotice = MemoSaveNotice(
                message: "No text selected.",
                systemImage: "exclamationmark.circle"
            )
            return
        }

        guard let memoFileURL = settings.validMemoFileURL else {
            alertRequest = AlertRequest(
                title: "Unable to Update Memo",
                message: "Choose a valid memo file location in Settings.",
                confirmationTitle: nil,
                action: nil
            )
            return
        }

        let fallbackWorkingDirectoryURL = session.currentWorkingDirectoryURL
        let processInspectionRequest = session.processInspectionRequest
        let inspector = processInspector
        let writer = memoWriter
        Task { [weak self] in
            do {
                let workingDirectoryURL: URL
                if let processInspectionRequest,
                   let inspectedURL = await inspector
                    .workingDirectoryURL(for: processInspectionRequest) {
                    workingDirectoryURL = inspectedURL
                } else {
                    workingDirectoryURL = fallbackWorkingDirectoryURL
                }
                try await writer.append(
                    selection,
                    workingDirectoryURL: workingDirectoryURL,
                    to: memoFileURL
                )
                self?.memoSaveNotice = MemoSaveNotice(
                    message: "Added to memo",
                    systemImage: "checkmark"
                )
            } catch {
                self?.alertRequest = AlertRequest(
                    title: "Unable to Update Memo",
                    message: error.localizedDescription,
                    confirmationTitle: nil,
                    action: nil
                )
            }
        }
    }

    func dismissMemoSaveNotice(_ id: UUID) {
        guard memoSaveNotice?.id == id else { return }
        memoSaveNotice = nil
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func setSidebarVisible(_ isVisible: Bool) {
        isSidebarVisible = isVisible
    }

    func addFolders(_ urls: [URL]) {
        var results: [FolderAdditionResult] = []
        var lastAddedFolder: URL?
        for url in urls {
            let result = addFolder(url, activate: false)
            results.append(result)
            if case let .added(folder) = result {
                lastAddedFolder = folder
            }
        }
        if let lastAddedFolder {
            activateFolder(lastAddedFolder)
        }
        presentFolderAdditionFailures(results)
    }

    func presentFolderImportError(_ error: Error) {
        alertRequest = AlertRequest(
            title: "Unable to Add Folder",
            message: error.localizedDescription,
            confirmationTitle: nil,
            action: nil
        )
    }

    @discardableResult
    func addFolder(
        _ url: URL,
        activate: Bool = true
    ) -> FolderAdditionResult {
        guard let folderURL = FolderStore.validFolderURL(url) else {
            return .invalid(url.standardizedFileURL)
        }
        if let trackedFolder = folders.first(where: {
            $0.url.standardizedFileURL.path == folderURL.path
        }) {
            guard !folderHasTabs(trackedFolder) else {
                return .duplicate(folderURL)
            }
            markFolderRecent(folderURL)
            if activate {
                activateFolder(folderURL)
            }
            return .added(folderURL)
        }
        folders.append(Folder(url: folderURL))
        folderOrderPaths.append(folderURL.path)
        markFolderRecent(folderURL)

        if activate {
            activateFolder(folderURL)
        }
        return .added(folderURL)
    }

    func folderURL(containing url: URL) -> URL? {
        folderURLs
            .filter { FolderStore.contains(url, in: $0) }
            .max { $0.path.count < $1.path.count }
    }

    func requestRemoveFolder(_ url: URL) {
        guard let folder = folderURLs.first(where: {
            $0.standardizedFileURL.path == url.standardizedFileURL.path
        }) else { return }
        let folderPath = folder.standardizedFileURL.path
        let folderTerminalIDs = Set(terminalTabs.filter {
            $0.ownerFolderURL?.standardizedFileURL.path == folderPath
        }.flatMap(\.terminalIDs))
        let folderSessions = terminalSessions.filter {
            folderTerminalIDs.contains($0.id)
        }
        guard folderSessions.contains(where: \.isRunningForegroundProgram) else {
            removeFolder(folder)
            return
        }

        let sessionCount = folderSessions.count
        let terminalCount = sessionCount == 1
            ? "1 terminal"
            : "\(sessionCount) terminals"
        alertRequest = AlertRequest(
            title: "Remove Folder “\(Folder(url: folder).displayName)”?",
            message: "This will close \(terminalCount) for this folder and terminate any running processes.",
            confirmationTitle: "Remove and Close Terminals",
            action: .removeFolder(folder)
        )
    }

    func removeFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        guard let folderIndex = folders.firstIndex(where: {
            $0.url.standardizedFileURL.path == folder.path
        }) else { return }

        let removedTabs = terminalTabs.filter {
            $0.ownerFolderURL?.standardizedFileURL.path == folder.path
        }
        let removedTabIDs = Set(removedTabs.map(\.id))
        let removedSessionIDs = Set(removedTabs.flatMap(\.terminalIDs))
        for session in terminalSessions where removedSessionIDs.contains(session.id) {
            session.terminal.onClose = nil
            agentAttentionCoordinator.unbind(terminalID: session.id)
            stopTrackingTerminalTitle(for: session.id)
            clearAgentAttention(for: session.id)
        }
        terminalSessions.removeAll { removedSessionIDs.contains($0.id) }
        terminalTabs.removeAll {
            $0.ownerFolderURL?.standardizedFileURL.path == folder.path
        }
        unreadTitleTabIDs.subtract(removedTabIDs)
        recentlyClosedTerminalLocations.removeAll {
            $0.ownerFolderURL?.standardizedFileURL.path == folder.path
        }
        folders.remove(at: folderIndex)
        folderOrderPaths.removeAll { $0 == folder.path }
        recentFolderPaths.removeAll { $0 == folder.path }
        lastActiveTabIDByFolderPath.removeValue(forKey: folder.path)

        if activeTabID.map(removedTabIDs.contains) == true {
            activeTabID = terminalTabs.last?.id
        }

        persistRecentFolders()
        persistFolderWorkspace()
    }

    func setFolderOrder(_ orderedFolders: [Folder]) {
        guard orderedFolders.count == folders.count,
              Set(orderedFolders.map(\.id)) == Set(folders.map(\.id)) else {
            return
        }
        folders = orderedFolders
        folderOrderPaths = orderedFolders.map {
            $0.url.standardizedFileURL.path
        }
        persistFolderWorkspace()
    }

    func activateFolder(_ url: URL) {
        guard let folderURL = folderURL(containing: url.standardizedFileURL)
        else { return }

        let folderPath = folderURL.path
        if let terminalID = latestAgentAttentionTerminalID(in: folderURL) {
            selectTerminal(terminalID)
            return
        }
        let rememberedTab = lastActiveTabIDByFolderPath[folderPath].flatMap {
            rememberedID in terminalTab(id: rememberedID).flatMap { tab in
                tab.ownerFolderURL?.standardizedFileURL.path == folderPath
                    ? tab
                    : nil
            }
        }
        if let existing = rememberedTab ?? terminalTabs.last(where: {
            $0.ownerFolderURL?.standardizedFileURL.path == folderPath
        }) {
            selectTab(existing.id)
            return
        }

        openNewTerminal(for: folderURL)
    }

    private func activateStandaloneTabGroup() {
        let tabs = standaloneTabs
        if let terminalID = latestAgentAttentionTerminalID(
            in: tabs.flatMap(\.terminalIDs)
        ) {
            selectTerminal(terminalID)
            return
        }
        if let rememberedTab = lastActiveStandaloneTabID.flatMap({ id in
            tabs.first(where: { $0.id == id })
        }) {
            selectTab(rememberedTab.id)
            return
        }
        if let existing = tabs.last {
            selectTab(existing.id)
            return
        }
        openNewStandaloneTerminal()
    }

    func openNewTerminal(for url: URL) {
        guard let folderURL = folderURL(containing: url.standardizedFileURL)
        else { return }
        markFolderRecent(folderURL)

        let isOpeningFirstTab = !terminalTabs.contains {
            $0.ownerFolderURL?.standardizedFileURL.path == folderURL.path
        }
        let session = appendTerminalTab(
            workingDirectoryURL: folderURL,
            ownerFolderURL: folderURL
        )
        if isOpeningFirstTab {
            repositionFolderForTabState(folderURL)
        }
        activeTabID = session.id
        lastActiveTabIDByFolderPath[folderURL.path] = session.id
        persistFolderWorkspace()
    }

    func openNewStandaloneTerminal() {
        openStandaloneTerminal(
            workingDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    func openNewTerminalInActiveContext() {
        if let folderURL = activeTerminalTab?.ownerFolderURL {
            openNewTerminal(for: folderURL)
        } else {
            openNewStandaloneTerminal()
        }
    }

    func ensureTerminalTab() {
        guard terminalTabs.isEmpty else { return }
        openNewStandaloneTerminal()
    }

    private func openStandaloneTerminal(workingDirectoryURL: URL) {
        guard let workingDirectoryURL = FolderStore.validFolderURL(
            workingDirectoryURL
        ) else { return }
        let session = appendTerminalTab(
            workingDirectoryURL: workingDirectoryURL,
            ownerFolderURL: nil
        )
        activeTabID = session.id
        lastActiveStandaloneTabID = session.id
        persistFolderWorkspace()
    }

    private func repositionFolderForTabState(_ folderURL: URL) {
        var orderedFolders = storedFoldersInOrder
        guard let sourceIndex = orderedFolders.firstIndex(where: {
            $0.url.standardizedFileURL.path == folderURL.path
        }) else { return }

        let folder = orderedFolders.remove(at: sourceIndex)
        let insertionIndex = orderedFolders.lastIndex(where: folderHasTabs)
            .map { $0 + 1 } ?? 0
        orderedFolders.insert(folder, at: insertionIndex)
        setFolderOrder(orderedFolders)
    }

    func splitActiveTerminal(direction: TerminalSplitDirection) {
        _ = makeSplitTerminal(direction: direction)
    }

    func updateSplitRatio(_ ratio: CGFloat, for splitID: UUID) {
        for index in terminalTabs.indices {
            let root = terminalTabs[index].root
            let updatedRoot = root.settingRatio(ratio, for: splitID)
            guard updatedRoot != root else { continue }
            terminalTabs[index].root = updatedRoot
            return
        }
    }

    @discardableResult
    private func makeSplitTerminal(
        direction: TerminalSplitDirection
    ) -> TerminalSession? {
        guard let activeTerminalID,
              let activeSession = activeTerminalSession,
              let tabIndex = terminalTabIndex(
                  containing: activeTerminalID
              ) else { return nil }

        let session = TerminalSession(
            workingDirectoryURL: activeSession.workingDirectoryURL,
            settings: settings,
            surfaceContext: .split
        )
        bindCloseHandler(to: session)
        terminalSessions.append(session)
        terminalTabs[tabIndex].root = terminalTabs[tabIndex].root.inserting(
            session.id,
            beside: activeTerminalID,
            direction: direction
        ).balancedForEqualSplits()
        terminalTabs[tabIndex].focusedTerminalID = session.id
        if let folderURL = terminalTabs[tabIndex].ownerFolderURL {
            lastActiveTabIDByFolderPath[folderURL.path] =
                terminalTabs[tabIndex].id
        }
        return session
    }

    func selectTerminal(_ id: UUID) {
        guard terminalSession(id: id) != nil,
              let tabIndex = terminalTabIndex(containing: id) else { return }
        terminalTabs[tabIndex].focusedTerminalID = id
        let tab = terminalTabs[tabIndex]
        activeTabID = tab.id
        clearAgentAttention(for: id)
        if let folderURL = tab.ownerFolderURL {
            markFolderRecent(folderURL)
            lastActiveTabIDByFolderPath[folderURL.standardizedFileURL.path] =
                tab.id
        } else {
            lastActiveStandaloneTabID = tab.id
        }
        persistFolderWorkspace()
    }

    func selectTab(_ id: UUID) {
        guard let tab = terminalTab(id: id) else { return }
        selectTerminal(
            latestAgentAttentionTerminalID(in: tab.terminalIDs)
                ?? tab.focusedTerminalID
        )
    }

    func tabNeedsAgentAttention(_ id: UUID) -> Bool {
        guard let tab = terminalTab(id: id) else {
            return false
        }
        return latestAgentAttentionTerminalID(in: tab.terminalIDs) != nil
    }

    func tabHasUnreadTitleActivity(_ id: UUID) -> Bool {
        unreadTitleTabIDs.contains(id)
    }

    func tabIsRefreshingTitle(_ id: UUID) -> Bool {
        guard let tab = terminalTab(id: id) else { return false }
        return tab.terminalIDs.contains {
            refreshingTitleFrameByTerminalID[$0] != nil
        }
    }

    func folderNeedsAgentAttention(_ url: URL) -> Bool {
        latestAgentAttentionTerminalID(in: url.standardizedFileURL) != nil
    }

    func folderRefreshingTitleFrame(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let terminalIDs = Set(terminalTabs.filter {
            $0.ownerFolderURL?.standardizedFileURL.path == path
        }.flatMap(\.terminalIDs))
        for session in terminalSessions.reversed()
        where terminalIDs.contains(session.id) {
            if let frame = refreshingTitleFrameByTerminalID[session.id] {
                return frame
            }
        }
        return nil
    }

    private static func leadingTitleFrame(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first)
    }

    private func updateTerminalTitleActivity(
        _ frame: String?,
        for terminalID: UUID
    ) {
        if let frame {
            refreshingTitleFrameByTerminalID[terminalID] = frame
            return
        }
        guard refreshingTitleFrameByTerminalID.removeValue(
            forKey: terminalID
        ) != nil else { return }
        completeUnreadTitleActivity(for: terminalID)
    }

    private func markActiveTabRead() {
        guard let activeTabID else { return }
        unreadTitleTabIDs.remove(activeTabID)
    }

    private func completeUnreadTitleActivity(for terminalID: UUID) {
        guard let tabIndex = terminalTabIndex(containing: terminalID) else {
            return
        }
        let tabID = terminalTabs[tabIndex].id
        guard tabID != activeTabID else { return }
        unreadTitleTabIDs.insert(tabID)
        latestUnreadTitleActivity = UnreadTitleActivityEvent(
            tabID: tabID
        )
    }

    func receiveAgentAttention(
        _ notification: AgentAttentionNotification,
        from terminalID: UUID,
        terminalIsFocused: Bool
    ) {
        receiveAgentAttention(
            notification,
            from: terminalID,
            terminalIsFocused: terminalIsFocused,
            applicationIsActive: NSApp.isActive
        )
    }

    func receiveAgentAttention(
        _ notification: AgentAttentionNotification,
        from terminalID: UUID,
        terminalIsFocused: Bool,
        applicationIsActive: Bool
    ) {
        guard terminalSession(id: terminalID) != nil else { return }

        if applicationIsActive,
           activeTerminalID == terminalID,
           terminalIsFocused {
            clearAgentAttention(for: terminalID)
            return
        }

        agentAttentionByTerminalID[terminalID] = notification
        agentAttentionHandler?(terminalID)
    }

    func clearVisibleAgentAttention() {
        guard NSApp.isActive,
              let terminalID = activeTerminalID,
              let session = terminalSession(id: terminalID),
              session.terminal.isFocused else { return }
        clearAgentAttention(for: terminalID)
    }

    @discardableResult
    func selectTab(at index: Int) -> Bool {
        let tabs = tabsInSidebarOrder
        guard tabs.indices.contains(index) else { return false }
        selectTab(tabs[index].id)
        return true
    }

    @discardableResult
    func selectLastTab() -> Bool {
        guard let tab = tabsInSidebarOrder.last else { return false }
        selectTab(tab.id)
        return true
    }

    @discardableResult
    func selectAdjacentTab(offset: Int) -> Bool {
        let tabs = tabsInSidebarOrder
        guard tabs.count > 1,
              let activeTab = activeTerminalTab,
              let index = tabs.firstIndex(where: {
                  $0.id == activeTab.id
              }) else { return false }
        let next = (index + offset + tabs.count) % tabs.count
        selectTab(tabs[next].id)
        return true
    }

    @discardableResult
    func selectAdjacentTabGroup(offset: Int) -> Bool {
        let orderedFolders = foldersWithTabs
        let hasStandaloneGroup = !standaloneTabs.isEmpty
        let groupCount = orderedFolders.count + (hasStandaloneGroup ? 1 : 0)
        guard groupCount > 1 else { return false }

        let activeIndex: Int
        if let activeFolderURL,
           let activeFolder = folderURL(containing: activeFolderURL),
           let folderIndex = orderedFolders.firstIndex(where: {
               $0.url.standardizedFileURL.path == activeFolder.path
           }) {
            activeIndex = folderIndex + (hasStandaloneGroup ? 1 : 0)
        } else {
            guard hasStandaloneGroup else { return false }
            activeIndex = 0
        }

        let next = (activeIndex + offset + groupCount) % groupCount
        if hasStandaloneGroup && next == 0 {
            activateStandaloneTabGroup()
        } else {
            let folderIndex = next - (hasStandaloneGroup ? 1 : 0)
            activateFolder(orderedFolders[folderIndex].url)
        }
        return true
    }

    @discardableResult
    func selectSplit(in direction: TerminalSplitDirection) -> Bool {
        guard let target = splitNavigationTarget(in: direction) else {
            return false
        }
        selectTerminal(target)
        return true
    }

    func canSelectSplit(in direction: TerminalSplitDirection) -> Bool {
        splitNavigationTarget(in: direction) != nil
    }

    func setTabOrder(_ orderedTabIDs: [UUID]) {
        guard orderedTabIDs.count == terminalTabs.count,
              Set(orderedTabIDs) == Set(terminalTabs.map(\.id)) else { return }
        let tabsByID = Dictionary(
            uniqueKeysWithValues: terminalTabs.map { ($0.id, $0) }
        )
        terminalTabs = orderedTabIDs.compactMap { tabsByID[$0] }
    }

    func requestCloseActiveTerminal() {
        guard let activeTerminalID else { return }
        requestCloseTerminal(activeTerminalID)
    }

    func requestCloseTerminal(_ id: UUID) {
        guard let session = terminalSession(id: id) else { return }
        guard let runningProcessName = session.runningForegroundProcessName else {
            closeTerminal(id)
            return
        }

        alertRequest = AlertRequest(
            title: "Close Terminal with Running Process?",
            message: runningProcessName
                + " is still running. Closing this terminal will terminate it.",
            confirmationTitle: "Close Terminal",
            action: .closeTerminal(id)
        )
    }

    func requestCloseTab(_ id: UUID) {
        guard let tab = terminalTab(id: id) else { return }
        let runningPrograms = tab.terminalIDs.compactMap { terminalID in
            terminalSession(id: terminalID).flatMap {
                $0.runningForegroundProcessName
            }
        }
        guard !runningPrograms.isEmpty else {
            closeTab(id)
            return
        }

        let processCount = runningPrograms.count
        let processSubject = processCount == 1
            ? "A process is"
            : "\(processCount) processes are"
        let processObject = processCount == 1 ? "it" : "them"
        alertRequest = AlertRequest(
            title: "Close Tab with Running Processes?",
            message: "\(processSubject) still running: "
                + Array(Set(runningPrograms)).sorted().joined(separator: ", ")
                + ". Closing this tab will terminate \(processObject).",
            confirmationTitle: "Close Tab",
            action: .closeTab(id)
        )
    }

    func closeTab(_ id: UUID) {
        guard let terminalIDs = terminalTab(id: id)?.terminalIDs else { return }
        for terminalID in terminalIDs {
            closeTerminal(terminalID)
        }
    }

    func closeTerminal(
        _ id: UUID,
        recordsForRestoration: Bool = true
    ) {
        guard let sessionIndex = terminalSessionIndex(id: id) else { return }

        let closingSession = terminalSessions[sessionIndex]
        guard let tabIndex = terminalTabIndex(containing: id) else { return }
        let closingTab = terminalTabs[tabIndex]
        let paneIDs = closingTab.terminalIDs
        let paneIndex = paneIDs.firstIndex(of: id)
        let replacementInTab = paneIndex.flatMap { index -> UUID? in
            if index + 1 < paneIDs.count { return paneIDs[index + 1] }
            if index > 0 { return paneIDs[index - 1] }
            return nil
        }
        let scopeTabs = terminalTabs.filter {
            $0.ownerFolderURL == closingTab.ownerFolderURL
        }
        let closingScopeTabIndex = scopeTabs.firstIndex {
            $0.id == closingTab.id
        }
        let replacementTabID = closingScopeTabIndex.flatMap { index -> UUID? in
            if index + 1 < scopeTabs.count { return scopeTabs[index + 1].id }
            if index > 0 { return scopeTabs[index - 1].id }
            return nil
        }
        if recordsForRestoration {
            recentlyClosedTerminalLocations.append(ClosedTerminalLocation(
                workingDirectoryURL: closingSession.workingDirectoryURL,
                ownerFolderURL: closingTab.ownerFolderURL
            ))
            if recentlyClosedTerminalLocations.count > 20 {
                recentlyClosedTerminalLocations.removeFirst()
            }
        }
        closingSession.terminal.onClose = nil
        agentAttentionCoordinator.unbind(terminalID: id)
        stopTrackingTerminalTitle(for: id)
        clearAgentAttention(for: id)
        if let updatedRoot = closingTab.root.removing(id) {
            terminalTabs[tabIndex].root = updatedRoot.balancedForEqualSplits()
            if closingTab.focusedTerminalID == id,
               let replacementInTab {
                terminalTabs[tabIndex].focusedTerminalID = replacementInTab
            }
        } else {
            terminalTabs.remove(at: tabIndex)
            unreadTitleTabIDs.remove(closingTab.id)
        }
        terminalSessions.remove(at: sessionIndex)
        if activeTabID == closingTab.id,
           !terminalTabs.contains(where: { $0.id == closingTab.id }) {
            activeTabID = replacementTabID ?? terminalTabs.last?.id
        }
        if let folderURL = closingTab.ownerFolderURL {
            let folderPath = folderURL.standardizedFileURL.path
            let folderStillHasTabs = terminalTabs.contains {
                $0.ownerFolderURL?.standardizedFileURL.path == folderPath
            }
            if !folderStillHasTabs {
                lastActiveTabIDByFolderPath.removeValue(forKey: folderPath)
                repositionFolderForTabState(folderURL)
                pruneUntrackedFolders()
            } else if lastActiveTabIDByFolderPath[folderPath]
                == closingTab.id,
                !terminalTabs.contains(where: { $0.id == closingTab.id }) {
                lastActiveTabIDByFolderPath[folderPath] = replacementTabID
            }
        } else if lastActiveStandaloneTabID == closingTab.id,
                  !terminalTabs.contains(where: { $0.id == closingTab.id }) {
            lastActiveStandaloneTabID = replacementTabID
        }
        if terminalTabs.isEmpty {
            closeWindowHandler?()
        }
        persistFolderWorkspace()

        // AppKit may finish dismantling the old split containers after SwiftUI
        // has rendered the collapsed tree. Refresh on the next run loop so the
        // surviving session-owned terminal view is attached to its final pane.
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func restoreLastClosedTerminal() {
        while let location = recentlyClosedTerminalLocations.popLast() {
            guard FolderStore.validFolderURL(
                location.workingDirectoryURL
            ) != nil else {
                continue
            }
            if let folderURL = location.ownerFolderURL {
                if self.folderURL(containing: folderURL) == nil {
                    guard case .added = addFolder(
                        folderURL,
                        activate: false
                    ) else {
                        continue
                    }
                }
                openNewTerminal(for: folderURL)
            } else {
                openStandaloneTerminal(
                    workingDirectoryURL: location.workingDirectoryURL
                )
            }
            return
        }
    }

    func promptRenameTab(_ id: UUID) {
        guard let tab = terminalTab(id: id),
              let session = terminalSession(
                  id: tab.focusedTerminalID
              ) else { return }
        renameRequest = TabRenameRequest(
            tabID: id,
            initialTitle: tab.customTitle ?? "",
            automaticTitle: session.displayTitle(
                terminalTitle: session.terminal.title,
                foregroundProcessName: session.currentProcessName
            )
        )
    }

    func saveTabRename(_ request: TabRenameRequest, title: String) {
        guard let tabIndex = workspaceIndex.tabIndex(
            id: request.tabID
        ) else {
            renameRequest = nil
            return
        }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        terminalTabs[tabIndex].customTitle = value.isEmpty ? nil : value
        renameRequest = nil
    }

    func dismissRenameRequest() {
        renameRequest = nil
    }

    func dismissAlert() {
        alertRequest = nil
    }

    func confirmAlert(_ alert: AlertRequest) {
        guard alertRequest?.id == alert.id else { return }
        alertRequest = nil
        switch alert.action {
        case let .removeFolder(url):
            removeFolder(url)
        case let .closeTerminal(id):
            closeTerminal(id)
        case let .closeTab(id):
            closeTab(id)
        case nil:
            break
        }
    }

    private func splitNavigationScore(
        from current: CGRect,
        to candidate: CGRect,
        direction: TerminalSplitDirection
    ) -> CGFloat {
        let primaryDistance: CGFloat
        let secondaryDistance: CGFloat
        let overlapsPerpendicularAxis: Bool
        switch direction {
        case .left, .right:
            primaryDistance = abs(candidate.midX - current.midX)
            secondaryDistance = abs(candidate.midY - current.midY)
            overlapsPerpendicularAxis = candidate.maxY > current.minY
                && candidate.minY < current.maxY
        case .up, .down:
            primaryDistance = abs(candidate.midY - current.midY)
            secondaryDistance = abs(candidate.midX - current.midX)
            overlapsPerpendicularAxis = candidate.maxX > current.minX
                && candidate.minX < current.maxX
        }
        return primaryDistance
            + secondaryDistance * 0.5
            + (overlapsPerpendicularAxis ? 0 : 2)
    }

    private func splitNavigationTarget(
        in direction: TerminalSplitDirection
    ) -> UUID? {
        guard let activeTerminalID,
              let root = activeTerminalTab?.root,
              let currentFrame = root.paneFrames()[activeTerminalID]
        else { return nil }

        return root.paneFrames()
            .filter { id, frame in
                guard id != activeTerminalID else { return false }
                switch direction {
                case .left:
                    return frame.midX < currentFrame.midX
                case .right:
                    return frame.midX > currentFrame.midX
                case .up:
                    return frame.midY < currentFrame.midY
                case .down:
                    return frame.midY > currentFrame.midY
                }
            }
            .min { lhs, rhs in
                splitNavigationScore(
                    from: currentFrame,
                    to: lhs.value,
                    direction: direction
                ) < splitNavigationScore(
                    from: currentFrame,
                    to: rhs.value,
                    direction: direction
                )
            }?.key
    }

    private func bindCloseHandler(to session: TerminalSession) {
        let sessionID = session.id
        session.terminal.onClose = { [weak self] processAlive in
            if processAlive {
                self?.requestCloseTerminal(sessionID)
            } else {
                self?.closeTerminal(
                    sessionID,
                    recordsForRestoration: false
                )
            }
        }

        agentAttentionCoordinator.bind(
            to: session,
            notificationHandler: {
                [weak self] notification, terminalID, isFocused in
                self?.receiveAgentAttention(
                    notification,
                    from: terminalID,
                    terminalIsFocused: isFocused
                )
            },
            focusHandler: { [weak self] in
                self?.clearVisibleAgentAttention()
            }
        )

        let titleChanges = session.terminal
            .$title
            .dropFirst()
            .removeDuplicates()
            .map { title in
                (title: title, instant: ContinuousClock.now)
            }
            .share()

        let activityFrames = titleChanges
            .scan((
                previous: ContinuousClock.Instant?.none,
                frame: String?.none
            )) { state, now in
                let isRapid = state.previous.map {
                    now.instant - $0 <= .seconds(1)
                } ?? false
                return (
                    previous: now.instant,
                    frame: isRapid ? Self.leadingTitleFrame(now.title) : nil
                )
            }
            .map(\.frame)

        let activityStops = titleChanges
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .map { _ in String?.none }

        terminalTitleCancellables[sessionID] = Publishers.Merge(
            activityFrames,
            activityStops
        )
        .removeDuplicates()
        .sink { [weak self] frame in
            self?.updateTerminalTitleActivity(frame, for: sessionID)
        }
    }

    private func stopTrackingTerminalTitle(for terminalID: UUID) {
        terminalTitleCancellables.removeValue(forKey: terminalID)
        refreshingTitleFrameByTerminalID.removeValue(forKey: terminalID)
    }

    private func latestAgentAttentionTerminalID(
        in folderURL: URL
    ) -> UUID? {
        let path = folderURL.standardizedFileURL.path
        let terminalIDs = terminalTabs
            .filter { $0.ownerFolderURL?.standardizedFileURL.path == path }
            .flatMap(\.terminalIDs)
        return latestAgentAttentionTerminalID(in: terminalIDs)
    }

    private func latestAgentAttentionTerminalID(
        in terminalIDs: [UUID]
    ) -> UUID? {
        terminalIDs.compactMap { terminalID in
            agentAttentionByTerminalID[terminalID].map {
                (terminalID, $0.receivedAt)
            }
        }.max { $0.1 < $1.1 }?.0
    }

    private func clearAgentAttention(for terminalID: UUID) {
        agentAttentionByTerminalID.removeValue(forKey: terminalID)
    }

    private func persistRecentFolders() {
        let foldersByPath = Dictionary(
            uniqueKeysWithValues: folders.map {
                ($0.url.standardizedFileURL.path, $0.url)
            }
        )
        folderStore.persistRecentFolders(
            recentFolderPaths.compactMap { foldersByPath[$0] }
        )
    }

    func persistFolderWorkspace() {
        folderStore.persistWorkspace(FolderWorkspaceState(
            openFolders: foldersWithTabs.map(\.url),
            activeFolder: activeFolderURL
        ))
    }

    func clearRecentFolders() {
        recentFolderPaths.removeAll()
        pruneUntrackedFolders()
        persistRecentFolders()
    }

    private func markFolderRecent(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentFolderPaths.removeAll { $0 == path }
        recentFolderPaths.insert(path, at: 0)
        if recentFolderPaths.count > Self.recentFolderLimit {
            recentFolderPaths.removeLast(
                recentFolderPaths.count - Self.recentFolderLimit
            )
        }
        pruneUntrackedFolders()
        persistRecentFolders()
    }

    private func pruneUntrackedFolders() {
        let recentPaths = Set(recentFolderPaths)
        let openPaths = Set(terminalTabs.compactMap {
            $0.ownerFolderURL?.standardizedFileURL.path
        })
        let retainedPaths = recentPaths.union(openPaths)
        folders.removeAll {
            !retainedPaths.contains($0.url.standardizedFileURL.path)
        }
        folderOrderPaths.removeAll { !retainedPaths.contains($0) }
    }

    private func presentFolderAdditionFailures(
        _ results: [FolderAdditionResult]
    ) {
        let messages = results.compactMap { result -> String? in
            switch result {
            case .added:
                nil
            case let .invalid(url):
                "“\(url.path)” is not a valid folder."
            case let .duplicate(url):
                "Folder “\(Folder(url: url).displayName)” has already been added."
            }
        }
        guard !messages.isEmpty else { return }

        alertRequest = AlertRequest(
            title: "Some Folders Were Not Added",
            message: messages.joined(separator: "\n"),
            confirmationTitle: nil,
            action: nil
        )
    }

}
