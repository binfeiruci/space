import AppKit
import Combine
import CoreGraphics
import Foundation
import GhosttyTerminal
import Observation

enum TerminalTabSidebarItem: Hashable, Identifiable {
    case tab(UUID)
    case divider(UUID)

    var id: Self { self }

    var tabID: UUID? {
        guard case let .tab(id) = self else { return nil }
        return id
    }

    var dividerID: UUID? {
        guard case let .divider(id) = self else { return nil }
        return id
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var terminalSessions: [TerminalSession] {
        willSet { workspaceIndex.indexSessions(newValue) }
    }
    private(set) var terminalTabs: [TerminalTabState] {
        willSet { workspaceIndex.indexTabs(newValue) }
    }
    private(set) var activeTabID: UUID? {
        didSet { markActiveTabRead() }
    }
    private(set) var alertRequest: AlertRequest?
    private(set) var isSidebarVisible = true
    private(set) var unreadTitleTabIDs: Set<UUID> = []
    private(set) var tabSidebarItems: [TerminalTabSidebarItem] = []
    private var activeTitleTerminalIDs: Set<UUID> = []
    private(set) var terminalLayoutRevision = 0

    let settings: AppSettings
    var closeWindowHandler: (() -> Void)?

    private let processInspector: any TerminalProcessInspecting
    private let workspaceStore: TerminalWorkspaceStore
    private var workspaceIndex = TerminalWorkspaceIndex()
    private var terminalRuntimeMonitorTask: Task<Void, Never>?
    private var terminalTitleCancellables: [UUID: AnyCancellable] = [:]

    init(
        defaults: any PreferencesStoring = UserDefaults.standard,
        processInspector: (any TerminalProcessInspecting)? = nil
    ) {
        self.processInspector = processInspector ?? TerminalProcessInspector()
        workspaceStore = TerminalWorkspaceStore(defaults: defaults)
        settings = AppSettings(defaults: defaults)
        terminalSessions = []
        terminalTabs = []
        activeTabID = nil

        if !restoreWorkspace() {
            let session = appendTerminalTab(
                workingDirectoryURL: FileManager.default
                    .homeDirectoryForCurrentUser
            )
            activeTabID = session.id
        }
        workspaceIndex.indexSessions(terminalSessions)
        workspaceIndex.indexTabs(terminalTabs)
    }

    var activeTerminalTab: TerminalTabState? {
        guard let activeTabID else { return nil }
        return terminalTab(id: activeTabID)
    }

    var activeTerminalID: UUID? {
        activeTerminalTab?.focusedTerminalID
    }

    var activeTerminalSession: TerminalSession? {
        guard let activeTerminalID else { return nil }
        return terminalSession(id: activeTerminalID)
    }

    func terminalSession(id: UUID) -> TerminalSession? {
        workspaceIndex.session(id: id)
    }

    func terminalTab(id: UUID) -> TerminalTabState? {
        workspaceIndex.tabIndex(id: id).map { terminalTabs[$0] }
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

    func saveWorkspace() {
        persistWorkspace()
    }

    func refreshTerminalProcessStates() async {
        let requests = terminalSessions.compactMap(\.processInspectionRequest)
        let statesBySessionID = await processInspector.processStates(
            for: requests
        )
        guard !Task.isCancelled else { return }
        for session in terminalSessions {
            session.updateProcessState(statesBySessionID[session.id])
        }
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func setSidebarVisible(_ isVisible: Bool) {
        isSidebarVisible = isVisible
    }

    func openNewTerminal() {
        let session = appendTerminalTab(
            workingDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        activeTabID = session.id
    }

    func openNewTerminal(after id: UUID) {
        guard let tabIndex = terminalTabs.firstIndex(where: { $0.id == id }),
              let sidebarIndex = sidebarTabIndex(id: id)
        else { return }
        let session = insertTerminalTab(
            at: tabIndex + 1,
            sidebarIndex: sidebarIndex + 1,
            workingDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        activeTabID = session.id
    }

    func duplicateTab(_ id: UUID) {
        guard let tabIndex = terminalTabs.firstIndex(where: { $0.id == id }),
              let sidebarIndex = sidebarTabIndex(id: id),
              let tab = terminalTab(id: id),
              let session = terminalSession(id: tab.focusedTerminalID)
        else { return }
        let duplicate = insertTerminalTab(
            at: tabIndex + 1,
            sidebarIndex: sidebarIndex + 1,
            workingDirectoryURL: session.currentWorkingDirectoryURL
        )
        activeTabID = duplicate.id
    }

    func ensureTerminalTab() {
        guard terminalTabs.isEmpty else { return }
        openNewTerminal()
    }

    func moveTabSidebarItems(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty,
              source.allSatisfy(tabSidebarItems.indices.contains),
              (0 ... tabSidebarItems.count).contains(destination)
        else { return }
        var reorderedItems = tabSidebarItems
        let movedItems = source.map { reorderedItems[$0] }
        for index in source.reversed() {
            reorderedItems.remove(at: index)
        }
        let removedBeforeDestination = source.count(in: 0 ..< destination)
        reorderedItems.insert(
            contentsOf: movedItems,
            at: destination - removedBeforeDestination
        )

        let tabsByID = Dictionary(
            uniqueKeysWithValues: terminalTabs.map { ($0.id, $0) }
        )
        let orderedTabIDs = reorderedItems.compactMap(\.tabID)
        tabSidebarItems = reorderedItems
        terminalTabs = orderedTabIDs.compactMap { tabsByID[$0] }
    }

    func addTabDivider(after id: UUID) {
        guard let index = sidebarTabIndex(id: id) else { return }
        tabSidebarItems.insert(.divider(UUID()), at: index + 1)
    }

    func removeTabDivider(id: UUID) {
        tabSidebarItems.removeAll { $0.dividerID == id }
    }

    func splitActiveTerminal(direction: TerminalSplitDirection) {
        guard let activeTerminalID,
              let tabIndex = terminalTabIndex(containing: activeTerminalID)
        else { return }

        let session = TerminalSession(
            workingDirectoryURL: FileManager.default
                .homeDirectoryForCurrentUser,
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

    func selectTerminal(_ id: UUID) {
        guard terminalSession(id: id) != nil,
              let tabIndex = terminalTabIndex(containing: id)
        else { return }
        terminalTabs[tabIndex].focusedTerminalID = id
        activeTabID = terminalTabs[tabIndex].id
    }

    func selectTab(_ id: UUID) {
        guard let tab = terminalTab(id: id) else { return }
        selectTerminal(tab.focusedTerminalID)
    }

    func selectTab(at index: Int) -> Bool {
        guard terminalTabs.indices.contains(index) else { return false }
        selectTab(terminalTabs[index].id)
        return true
    }

    func selectLastTab() -> Bool {
        guard let tab = terminalTabs.last else { return false }
        selectTab(tab.id)
        return true
    }

    func selectAdjacentTab(offset: Int) -> Bool {
        guard terminalTabs.count > 1,
              let activeTabID,
              let index = terminalTabs.firstIndex(where: {
                  $0.id == activeTabID
              })
        else { return false }
        let targetIndex = (index + offset + terminalTabs.count)
            % terminalTabs.count
        selectTab(terminalTabs[targetIndex].id)
        return true
    }

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

    func tabHasUnreadTitleActivity(_ id: UUID) -> Bool {
        unreadTitleTabIDs.contains(id)
    }

    func tabHasActiveTitleActivity(_ id: UUID) -> Bool {
        terminalTab(id: id)?.terminalIDs.contains {
            activeTitleTerminalIDs.contains($0)
        } ?? false
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
            terminalSession(id: terminalID)?.runningForegroundProcessName
        }
        guard !runningPrograms.isEmpty else {
            closeTab(id)
            return
        }
        let subject = runningPrograms.count == 1
            ? "A process is" : "\(runningPrograms.count) processes are"
        let object = runningPrograms.count == 1 ? "it" : "them"
        alertRequest = AlertRequest(
            title: "Close Tab with Running Processes?",
            message: "\(subject) still running: "
                + Array(Set(runningPrograms)).sorted().joined(separator: ", ")
                + ". Closing this tab will terminate \(object).",
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

    func closeTerminal(_ id: UUID) {
        guard let sessionIndex = terminalSessionIndex(id: id),
              let tabIndex = terminalTabIndex(containing: id)
        else { return }

        let closingSession = terminalSessions[sessionIndex]
        let closingTab = terminalTabs[tabIndex]
        let closingOrderIndex = terminalTabs.firstIndex {
            $0.id == closingTab.id
        }
        let replacementTabID = closingOrderIndex.flatMap { index -> UUID? in
            if index + 1 < terminalTabs.count {
                return terminalTabs[index + 1].id
            }
            if index > 0 { return terminalTabs[index - 1].id }
            return nil
        }
        let paneIDs = closingTab.terminalIDs
        let paneIndex = paneIDs.firstIndex(of: id)
        let replacementPaneID = paneIndex.flatMap { index -> UUID? in
            if index > 0 { return paneIDs[index - 1] }
            if index + 1 < paneIDs.count { return paneIDs[index + 1] }
            return nil
        }

        closingSession.terminal.onClose = nil
        stopTrackingTerminalTitle(for: id)
        if let updatedRoot = closingTab.root.removing(id) {
            terminalTabs[tabIndex].root = updatedRoot.balancedForEqualSplits()
            if closingTab.focusedTerminalID == id,
               let replacementPaneID {
                terminalTabs[tabIndex].focusedTerminalID = replacementPaneID
                terminalSession(id: replacementPaneID)?.requestTerminalFocus()
            }
        } else {
            terminalTabs.remove(at: tabIndex)
            tabSidebarItems.removeAll { $0.tabID == closingTab.id }
            unreadTitleTabIDs.remove(closingTab.id)
        }
        terminalSessions.remove(at: sessionIndex)

        if activeTabID == closingTab.id,
           !terminalTabs.contains(where: { $0.id == closingTab.id }) {
            activeTabID = replacementTabID
        }
        if terminalTabs.isEmpty { closeWindowHandler?() }

        DispatchQueue.main.async { [weak self] in
            self?.terminalLayoutRevision += 1
        }
    }

    func dismissAlert() {
        alertRequest = nil
    }

    func confirmAlert(_ alert: AlertRequest) {
        guard alertRequest?.id == alert.id else { return }
        alertRequest = nil
        switch alert.action {
        case let .closeTerminal(id): closeTerminal(id)
        case let .closeTab(id): closeTab(id)
        }
    }

    private func appendTerminalTab(
        workingDirectoryURL: URL
    ) -> TerminalSession {
        insertTerminalTab(
            at: terminalTabs.endIndex,
            sidebarIndex: tabSidebarItems.endIndex,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    private func insertTerminalTab(
        at tabIndex: Int,
        sidebarIndex: Int,
        workingDirectoryURL: URL
    ) -> TerminalSession {
        let session = TerminalSession(
            workingDirectoryURL: workingDirectoryURL
        )
        bindCloseHandler(to: session)
        terminalSessions.append(session)
        terminalTabs.insert(TerminalTabState(
            id: session.id,
            root: .pane(session.id),
            focusedTerminalID: session.id
        ), at: tabIndex)
        tabSidebarItems.insert(.tab(session.id), at: sidebarIndex)
        return session
    }

    private func sidebarTabIndex(id: UUID) -> Int? {
        tabSidebarItems.firstIndex { $0.tabID == id }
    }

    private func terminalSessionIndex(id: UUID) -> Int? {
        workspaceIndex.sessionIndex(id: id)
    }

    private func terminalTabIndex(containing terminalID: UUID) -> Int? {
        workspaceIndex.tabIndex(containing: terminalID)
    }

    private func monitorTerminalRuntime() async {
        while !Task.isCancelled {
            let applicationIsActive = NSApp.isActive
            let displayedTerminalIDs = Set(
                activeTerminalTab?.terminalIDs ?? []
            )
            for session in terminalSessions
            where !displayedTerminalIDs.contains(session.id) {
                session.terminal.controller.tick()
            }
            await refreshTerminalProcessStates()
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

    private func markActiveTabRead() {
        guard let activeTabID else { return }
        unreadTitleTabIDs.remove(activeTabID)
    }

    private func updateTerminalTitleActivity(
        isActive: Bool,
        for terminalID: UUID
    ) {
        if isActive {
            activeTitleTerminalIDs.insert(terminalID)
            return
        }
        guard activeTitleTerminalIDs.remove(terminalID) != nil,
              let tabIndex = terminalTabIndex(containing: terminalID)
        else { return }
        let tabID = terminalTabs[tabIndex].id
        if tabID != activeTabID { unreadTitleTabIDs.insert(tabID) }
    }

    private func bindCloseHandler(to session: TerminalSession) {
        let sessionID = session.id
        session.terminal.onClose = { [weak self] processAlive in
            if processAlive {
                self?.requestCloseTerminal(sessionID)
            } else {
                self?.closeTerminal(sessionID)
            }
        }

        let titleChanges = session.terminal.$title
            .dropFirst()
            .removeDuplicates()
            .map { _ in ContinuousClock.now }
            .share()
        let activityStarts = titleChanges
            .scan((previous: ContinuousClock.Instant?.none, isActive: false)) {
                state, instant in
                let isRapid = state.previous.map {
                    instant - $0 <= .seconds(1)
                } ?? false
                return (previous: instant, isActive: isRapid)
            }
            .map(\.isActive)
        let activityStops = titleChanges
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .map { _ in false }

        terminalTitleCancellables[sessionID] = Publishers.Merge(
            activityStarts,
            activityStops
        )
        .removeDuplicates()
        .sink { [weak self] isActive in
            self?.updateTerminalTitleActivity(
                isActive: isActive,
                for: sessionID
            )
        }
    }

    private func stopTrackingTerminalTitle(for terminalID: UUID) {
        terminalTitleCancellables.removeValue(forKey: terminalID)
        activeTitleTerminalIDs.remove(terminalID)
    }

    private func restoreWorkspace() -> Bool {
        guard let workspace = workspaceStore.load(),
              workspace.items.contains(where: { $0.kind == .tab })
        else { return false }

        var restoredActiveTabID: UUID?
        for item in workspace.items {
            switch item.kind {
            case .divider:
                tabSidebarItems.append(.divider(UUID()))
            case .tab:
                let session = appendTerminalTab(
                    workingDirectoryURL: restoredWorkingDirectoryURL(
                        path: item.workingDirectoryPath
                    )
                )
                if item.isActive { restoredActiveTabID = session.id }
            }
        }
        activeTabID = restoredActiveTabID ?? terminalTabs[0].id
        return true
    }

    private func persistWorkspace() {
        let items = tabSidebarItems.compactMap { item
            -> TerminalWorkspaceStore.Snapshot.SidebarItem? in
            switch item {
            case .divider:
                return .divider
            case let .tab(id):
                guard let tab = terminalTab(id: id),
                      let session = terminalSession(
                        id: tab.focusedTerminalID
                      )
                else { return nil }
                return .tab(
                    workingDirectoryPath: session.currentWorkingDirectoryURL
                        .path,
                    isActive: id == activeTabID
                )
            }
        }
        workspaceStore.save(.init(items: items))
    }

    private func restoredWorkingDirectoryURL(path: String?) -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        guard let path, !path.isEmpty else { return homeURL }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return homeURL }
        return url
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
                case .left: return frame.midX < currentFrame.midX
                case .right: return frame.midX > currentFrame.midX
                case .up: return frame.midY < currentFrame.midY
                case .down: return frame.midY > currentFrame.midY
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

    private func splitNavigationScore(
        from current: CGRect,
        to candidate: CGRect,
        direction: TerminalSplitDirection
    ) -> CGFloat {
        let primaryDistance: CGFloat
        let secondaryDistance: CGFloat
        let overlaps: Bool
        switch direction {
        case .left, .right:
            primaryDistance = abs(candidate.midX - current.midX)
            secondaryDistance = abs(candidate.midY - current.midY)
            overlaps = candidate.maxY > current.minY
                && candidate.minY < current.maxY
        case .up, .down:
            primaryDistance = abs(candidate.midY - current.midY)
            secondaryDistance = abs(candidate.midX - current.midX)
            overlaps = candidate.maxX > current.minX
                && candidate.minX < current.maxX
        }
        return primaryDistance + secondaryDistance * 0.5 + (overlaps ? 0 : 2)
    }
}
