import AppKit
import Combine
import Darwin
import Foundation
import GhosttyTerminal

enum WorkspaceRootAdditionResult: Equatable {
    case added(URL)
    case invalid(URL)
    case duplicate(URL)
    case overlaps(candidate: URL, existing: URL)
}

enum TerminalSearchAction {
    static func update(query: String) -> String {
        "search:\(query)"
    }

    static func navigate(forward: Bool) -> String {
        "navigate_search:\(forward ? "next" : "previous")"
    }

    static let end = "end_search"
}

enum TerminalSplitAxis: Equatable {
    case horizontal
    case vertical
}

enum TerminalSplitDirection: CaseIterable, Equatable {
    case left
    case right
    case up
    case down

    var axis: TerminalSplitAxis {
        switch self {
        case .left, .right:
            return .horizontal
        case .up, .down:
            return .vertical
        }
    }

    var insertsBeforeCurrentPane: Bool {
        self == .left || self == .up
    }
}

indirect enum TerminalSplitNode: Equatable {
    case pane(UUID)
    case split(
        id: UUID,
        axis: TerminalSplitAxis,
        ratio: CGFloat,
        first: TerminalSplitNode,
        second: TerminalSplitNode
    )

    var terminalIDs: [UUID] {
        switch self {
        case let .pane(id):
            return [id]
        case let .split(_, _, _, first, second):
            return first.terminalIDs + second.terminalIDs
        }
    }

    func contains(_ terminalID: UUID) -> Bool {
        switch self {
        case let .pane(id):
            return id == terminalID
        case let .split(_, _, _, first, second):
            return first.contains(terminalID) || second.contains(terminalID)
        }
    }

    func inserting(
        _ newTerminalID: UUID,
        beside terminalID: UUID,
        direction: TerminalSplitDirection
    ) -> TerminalSplitNode {
        switch self {
        case let .pane(id):
            guard id == terminalID else { return self }
            let current = TerminalSplitNode.pane(id)
            let new = TerminalSplitNode.pane(newTerminalID)
            return .split(
                id: UUID(),
                axis: direction.axis,
                ratio: 0.5,
                first: direction.insertsBeforeCurrentPane ? new : current,
                second: direction.insertsBeforeCurrentPane ? current : new
            )
        case let .split(id, axis, ratio, first, second):
            if first.contains(terminalID) {
                return .split(
                    id: id,
                    axis: axis,
                    ratio: ratio,
                    first: first.inserting(
                        newTerminalID,
                        beside: terminalID,
                        direction: direction
                    ),
                    second: second
                )
            }
            guard second.contains(terminalID) else { return self }
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: first,
                second: second.inserting(
                    newTerminalID,
                    beside: terminalID,
                    direction: direction
                )
            )
        }
    }

    func removing(_ terminalID: UUID) -> TerminalSplitNode? {
        switch self {
        case let .pane(id):
            return id == terminalID ? nil : self
        case let .split(id, axis, ratio, first, second):
            let updatedFirst = first.removing(terminalID)
            let updatedSecond = second.removing(terminalID)
            switch (updatedFirst, updatedSecond) {
            case let (first?, second?):
                return .split(
                    id: id,
                    axis: axis,
                    ratio: ratio,
                    first: first,
                    second: second
                )
            case let (first?, nil):
                return first
            case let (nil, second?):
                return second
            case (nil, nil):
                return nil
            }
        }
    }

    func paneFrames(in bounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1))
        -> [UUID: CGRect] {
        switch self {
        case let .pane(id):
            return [id: bounds]
        case let .split(_, axis, ratio, first, second):
            let clampedRatio = min(max(ratio, 0.1), 0.9)
            let firstBounds: CGRect
            let secondBounds: CGRect
            switch axis {
            case .horizontal:
                let firstWidth = bounds.width * clampedRatio
                firstBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: firstWidth,
                    height: bounds.height
                )
                secondBounds = CGRect(
                    x: bounds.minX + firstWidth,
                    y: bounds.minY,
                    width: bounds.width - firstWidth,
                    height: bounds.height
                )
            case .vertical:
                let firstHeight = bounds.height * clampedRatio
                firstBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: firstHeight
                )
                secondBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY + firstHeight,
                    width: bounds.width,
                    height: bounds.height - firstHeight
                )
            }
            return first.paneFrames(in: firstBounds).merging(
                second.paneFrames(in: secondBounds),
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
}

struct TerminalTabState: Identifiable, Equatable {
    let id: UUID
    let directory: URL
    var root: TerminalSplitNode
    var focusedTerminalID: UUID

    var terminalIDs: [UUID] {
        root.terminalIDs
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var rootNodes: [FileNode]
    @Published private(set) var activeDirectory: URL?
    @Published private(set) var terminalSessions: [TerminalSession]
    @Published private(set) var terminalTabs: [TerminalTabState]
    @Published private(set) var activeTerminalID: UUID?
    @Published private(set) var selectedTreeItemURL: URL?
    @Published private(set) var selectedFileURL: URL?
    @Published private var expandedDirectoryPaths: [String: Set<String>]
    @Published var showTerminalDirectoriesOnly = false
    @Published var isCommandPalettePresented = false
    @Published var isActionPalettePresented = false

    let terminalPreferences: TerminalPreferences

    private let defaults: UserDefaults
    private let watchesFiles: Bool
    private var fileRefreshTask: Task<Void, Never>?
    private var preferencesCancellable: AnyCancellable?
    private var recentlyClosedTerminalDirectories: [URL] = []

    private lazy var fileWatcher = WorkspaceFileWatcher { [weak self] changes in
        self?.handleFileChanges(changes)
    }

    init(
        defaults: UserDefaults = .standard,
        watchesFiles: Bool = true,
        initialRootURL: URL? = nil
    ) {
        self.defaults = defaults
        self.watchesFiles = watchesFiles
        terminalPreferences = TerminalPreferences(defaults: defaults)
        Keys.obsoletePersistedState.forEach(defaults.removeObject(forKey:))

        let roots = Self.validDirectory(initialRootURL).map { [$0] }
            ?? Self.restoredRootDirectories(from: defaults)
        let restoredActiveDirectory = Self.restoredActiveDirectory(
            from: defaults,
            roots: roots
        )
        let initialDirectory = restoredActiveDirectory ?? roots.first

        rootNodes = roots.map(Self.makeRootNode)
        expandedDirectoryPaths = Dictionary(
            uniqueKeysWithValues: roots.map { ($0.path, [$0.path]) }
        )
        activeDirectory = initialDirectory
        terminalSessions = []
        terminalTabs = []
        activeTerminalID = nil
        selectedTreeItemURL = initialDirectory
        selectedFileURL = nil

        if let initialDirectory {
            let initialSession = TerminalSession(
                directory: initialDirectory,
                preferences: terminalPreferences
            )
            terminalSessions = [initialSession]
            terminalTabs = [TerminalTabState(
                id: initialSession.id,
                directory: initialDirectory,
                root: .pane(initialSession.id),
                focusedTerminalID: initialSession.id
            )]
            activeTerminalID = initialSession.id
            bindCloseHandler(to: initialSession)
        }
        if watchesFiles {
            fileWatcher.start(watching: roots)
        }
        persistWorkspaceState()

        preferencesCancellable = terminalPreferences.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in
                    await Task.yield()
                    self?.applyPreferencesToExistingTerminals()
                }
            }
    }

    var rootURLs: [URL] {
        rootNodes.map(\.url)
    }

    var rootURL: URL? {
        activeDirectory.flatMap(rootDirectory(containing:)) ?? rootURLs.first
    }

    var rootNode: FileNode? {
        guard let rootURL else { return rootNodes.first }
        return rootNodes.first {
            $0.url.standardizedFileURL == rootURL.standardizedFileURL
        }
    }

    var activeDirectorySessions: [TerminalSession] {
        guard let activeDirectory else { return [] }
        let activePath = activeDirectory.standardizedFileURL.path
        return terminalSessions.filter {
            $0.directory.standardizedFileURL.path == activePath
        }
    }

    var activeDirectoryTabs: [TerminalTabState] {
        guard let activeDirectory else { return [] }
        let activePath = activeDirectory.standardizedFileURL.path
        return terminalTabs.filter {
            $0.directory.standardizedFileURL.path == activePath
        }
    }

    var activeTerminalTab: TerminalTabState? {
        guard let activeTerminalID else { return nil }
        return terminalTabs.first { $0.root.contains(activeTerminalID) }
    }

    var activeTabTerminalIDs: [UUID] {
        activeTerminalTab?.terminalIDs ?? []
    }

    var canNavigateSplit: Bool {
        activeTabTerminalIDs.count > 1
    }

    var activeTerminalSession: TerminalSession? {
        guard let activeTerminalID else { return nil }
        return terminalSessions.first { $0.id == activeTerminalID }
    }

    var canRestoreClosedTerminal: Bool {
        !recentlyClosedTerminalDirectories.isEmpty
    }

    func chooseRootDirectory() {
        let panel = NSOpenPanel()
        panel.title = "添加工作目录"
        panel.prompt = "添加"
        panel.directoryURL = activeDirectory ?? rootURLs.first
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }
        var results: [WorkspaceRootAdditionResult] = []
        var lastAddedDirectory: URL?
        for url in panel.urls {
            let result = addRootDirectory(url, activate: false)
            results.append(result)
            if case let .added(directory) = result {
                lastAddedDirectory = directory
            }
        }
        if let lastAddedDirectory {
            activateTerminal(for: lastAddedDirectory)
            selectedTreeItemURL = lastAddedDirectory
        }
        presentRootAdditionFailures(results)
    }

    @discardableResult
    func addRootDirectory(
        _ url: URL,
        activate: Bool = true
    ) -> WorkspaceRootAdditionResult {
        guard let directory = Self.validDirectory(url) else {
            return .invalid(url.standardizedFileURL)
        }
        if rootURLs.contains(where: {
            $0.standardizedFileURL.path == directory.path
        }) {
            return .duplicate(directory)
        }
        if let existing = rootURLs.first(where: {
            Self.pathsOverlap($0, directory)
        }) {
            return .overlaps(candidate: directory, existing: existing)
        }

        rootNodes.append(Self.makeRootNode(for: directory))
        expandedDirectoryPaths[directory.path, default: []].insert(directory.path)
        restartFileWatcher()
        persistWorkspaceState()

        if activate {
            activateTerminal(for: directory)
            selectedTreeItemURL = directory
        }
        return .added(directory)
    }

    func rootDirectory(containing url: URL) -> URL? {
        rootURLs.first { Self.isInside(url, root: $0) }
    }

    func isRootDirectory(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return rootURLs.contains { $0.standardizedFileURL.path == path }
    }

    func requestRemoveRootDirectory(_ url: URL) {
        guard let root = rootURLs.first(where: {
            $0.standardizedFileURL.path == url.standardizedFileURL.path
        }) else { return }
        let sessionCount = terminalSessions.count {
            Self.isInside($0.directory, root: root)
        }
        guard sessionCount > 0 else {
            removeRootDirectory(root)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "从工作区移除“\(root.lastPathComponent)”？"
        alert.informativeText = "将关闭其中的 \(sessionCount) 个终端及正在运行的程序。"
        alert.addButton(withTitle: "移除并关闭终端")
        alert.addButton(withTitle: "取消")

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.removeRootDirectory(root)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            removeRootDirectory(root)
        }
    }

    func removeRootDirectory(_ url: URL) {
        let root = url.standardizedFileURL
        guard let rootIndex = rootNodes.firstIndex(where: {
            $0.url.standardizedFileURL.path == root.path
        }) else { return }

        fileRefreshTask?.cancel()
        if let selectedFileURL, Self.isInside(selectedFileURL, root: root) {
            clearFileSelection()
        }

        let removedSessionIDs = Set(terminalSessions.compactMap { session in
            Self.isInside(session.directory, root: root) ? session.id : nil
        })
        for session in terminalSessions where removedSessionIDs.contains(session.id) {
            session.terminal.onClose = nil
        }
        terminalSessions.removeAll { removedSessionIDs.contains($0.id) }
        terminalTabs.removeAll {
            Self.isInside($0.directory, root: root)
        }
        recentlyClosedTerminalDirectories.removeAll {
            Self.isInside($0, root: root)
        }
        rootNodes.remove(at: rootIndex)
        expandedDirectoryPaths.removeValue(forKey: root.path)

        if activeTerminalID.map(removedSessionIDs.contains) == true {
            activeTerminalID = nil
        }
        if let activeTerminalSession {
            activeDirectory = activeTerminalSession.directory
        } else if let remainingTab = terminalTabs.last {
            activeDirectory = remainingTab.directory
            activeTerminalID = remainingTab.focusedTerminalID
        } else if let firstRoot = rootURLs.first {
            activeDirectory = firstRoot
            openNewTerminal(for: firstRoot)
        } else {
            activeDirectory = nil
            activeTerminalID = nil
            isCommandPalettePresented = false
            isActionPalettePresented = false
            showTerminalDirectoriesOnly = false
        }

        if selectedTreeItemURL.map({ Self.isInside($0, root: root) }) == true {
            selectedTreeItemURL = activeDirectory ?? rootURLs.first
        }
        restartFileWatcher()
        persistWorkspaceState()
    }

    func refreshFiles() {
        scheduleFileRefresh(affectedPaths: nil)
    }

    func activateTerminal(for url: URL) {
        let directory = url.standardizedFileURL
        guard Self.validDirectory(directory) != nil,
              rootDirectory(containing: directory) != nil else { return }

        clearFileSelection()

        let directoryPath = directory.path
        if let existing = terminalTabs.last(where: {
            $0.directory.standardizedFileURL.path == directoryPath
        }) {
            activeDirectory = existing.directory
            activeTerminalID = existing.focusedTerminalID
            persistWorkspaceState()
            return
        }

        openNewTerminal(for: directory)
    }

    func openNewTerminal(for url: URL) {
        let directory = url.standardizedFileURL
        guard Self.validDirectory(directory) != nil,
              rootDirectory(containing: directory) != nil else { return }

        clearFileSelection()

        let session = TerminalSession(
            directory: directory,
            preferences: terminalPreferences
        )
        bindCloseHandler(to: session)
        activeDirectory = directory
        terminalSessions.append(session)
        terminalTabs.append(TerminalTabState(
            id: session.id,
            directory: directory,
            root: .pane(session.id),
            focusedTerminalID: session.id
        ))
        activeTerminalID = session.id
        persistWorkspaceState()
    }

    func splitActiveTerminal(direction: TerminalSplitDirection) {
        _ = makeSplitTerminal(direction: direction)
    }

    @discardableResult
    private func makeSplitTerminal(
        direction: TerminalSplitDirection,
        initialInput: String? = nil,
        customTitle: String? = nil
    ) -> TerminalSession? {
        guard let activeTerminalID,
              let activeSession = activeTerminalSession,
              let tabIndex = terminalTabs.firstIndex(where: {
                  $0.root.contains(activeTerminalID)
              }) else { return nil }

        clearFileSelection()
        let session = TerminalSession(
            directory: activeSession.directory,
            preferences: terminalPreferences,
            surfaceContext: .split,
            initialInput: initialInput
        )
        session.customTitle = customTitle
        bindCloseHandler(to: session)
        terminalSessions.append(session)
        terminalTabs[tabIndex].root = terminalTabs[tabIndex].root.inserting(
            session.id,
            beside: activeTerminalID,
            direction: direction
        )
        terminalTabs[tabIndex].focusedTerminalID = session.id
        self.activeTerminalID = session.id
        persistWorkspaceState()
        return session
    }

    func duplicateActiveTerminal() {
        guard let session = activeTerminalSession else { return }
        openNewTerminal(for: session.directory)
    }

    func selectTerminal(_ id: UUID) {
        guard let session = terminalSessions.first(where: { $0.id == id }),
              let tabIndex = terminalTabs.firstIndex(where: {
                  $0.root.contains(id)
              }) else { return }
        clearFileSelection()
        terminalTabs[tabIndex].focusedTerminalID = id
        activeDirectory = session.directory
        activeTerminalID = session.id
        persistWorkspaceState()
    }

    func selectTab(_ id: UUID) {
        guard let tab = terminalTabs.first(where: { $0.id == id }) else { return }
        selectTerminal(tab.focusedTerminalID)
    }

    func selectTerminal(at index: Int) {
        let tabs = activeDirectoryTabs
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func selectLastTerminal() {
        guard let tab = activeDirectoryTabs.last else { return }
        selectTab(tab.id)
    }

    @discardableResult
    func selectAdjacentTerminal(offset: Int) -> Bool {
        let tabs = activeDirectoryTabs
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
    func selectSplit(in direction: TerminalSplitDirection) -> Bool {
        guard let activeTerminalID,
              let root = activeTerminalTab?.root,
              let currentFrame = root.paneFrames()[activeTerminalID]
        else { return false }

        let candidates = root.paneFrames().filter { id, frame in
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
        let selected = candidates.min { lhs, rhs in
            splitNavigationScore(
                from: currentFrame,
                to: lhs.value,
                direction: direction
            ) < splitNavigationScore(
                from: currentFrame,
                to: rhs.value,
                direction: direction
            )
        }
        guard let selected else { return false }
        selectTerminal(selected.key)
        return true
    }

    func moveTerminal(_ sourceID: UUID, before targetID: UUID) {
        guard sourceID != targetID,
              let sourceIndex = terminalSessions.firstIndex(where: {
                  $0.id == sourceID
              }),
              let targetSession = terminalSessions.first(where: {
                  $0.id == targetID
              }),
              let sourceSession = terminalSessions.first(where: {
                  $0.id == sourceID
              }),
              sourceSession.directory == targetSession.directory else { return }

        let session = terminalSessions.remove(at: sourceIndex)
        guard let updatedTargetIndex = terminalSessions.firstIndex(where: {
            $0.id == targetID
        }) else { return }
        terminalSessions.insert(session, at: updatedTargetIndex)
        moveTab(containing: sourceID, beforeTabContaining: targetID)
    }

    func moveTerminal(_ sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              let sourceIndex = terminalSessions.firstIndex(where: {
                  $0.id == sourceID
              }),
              let targetIndex = terminalSessions.firstIndex(where: {
                  $0.id == targetID
              }) else { return }
        let source = terminalSessions[sourceIndex]
        let target = terminalSessions[targetIndex]
        guard source.directory == target.directory else { return }

        let session = terminalSessions.remove(at: sourceIndex)
        guard let updatedTargetIndex = terminalSessions.firstIndex(where: {
            $0.id == targetID
        }) else { return }
        let insertionIndex = sourceIndex < targetIndex
            ? updatedTargetIndex + 1
            : updatedTargetIndex
        terminalSessions.insert(session, at: insertionIndex)
        moveTab(containing: sourceID, afterTabContaining: targetID)
    }

    func moveTab(_ sourceTabID: UUID, to targetTabID: UUID) {
        guard sourceTabID != targetTabID,
              let sourceIndex = terminalTabs.firstIndex(where: {
                  $0.id == sourceTabID
              }),
              let targetIndex = terminalTabs.firstIndex(where: {
                  $0.id == targetTabID
              }),
              terminalTabs[sourceIndex].directory
                  == terminalTabs[targetIndex].directory else { return }
        let tab = terminalTabs.remove(at: sourceIndex)
        guard let updatedTargetIndex = terminalTabs.firstIndex(where: {
            $0.id == targetTabID
        }) else { return }
        let insertionIndex = sourceIndex < targetIndex
            ? updatedTargetIndex + 1
            : updatedTargetIndex
        terminalTabs.insert(tab, at: insertionIndex)
    }

    func moveActiveTerminal(offset: Int) {
        guard let activeTab = activeTerminalTab,
              let current = activeDirectoryTabs.firstIndex(where: {
                  $0.id == activeTab.id
              }) else { return }
        let target = current + offset
        let tabs = activeDirectoryTabs
        guard tabs.indices.contains(target) else { return }
        moveTab(activeTab.id, to: tabs[target].id)
    }

    func requestCloseActiveTerminal() {
        guard let activeTerminalID else { return }
        requestCloseTerminal(activeTerminalID)
    }

    func requestCloseTerminal(_ id: UUID) {
        guard let session = terminalSessions.first(where: {
            $0.id == id
        }) else { return }
        guard session.isRunningForegroundProgram else {
            closeTerminal(id)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "关闭正在运行的终端？"
        alert.informativeText = (session.currentProcessName ?? "程序")
            + " 仍在运行，关闭终端会结束该进程。"
        alert.addButton(withTitle: "关闭终端")
        alert.addButton(withTitle: "取消")

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.closeTerminal(id)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            closeTerminal(id)
        }
    }

    func requestCloseTab(_ id: UUID) {
        guard let tab = terminalTabs.first(where: { $0.id == id }) else { return }
        let runningPrograms = tab.terminalIDs.compactMap { terminalID in
            terminalSessions.first(where: { $0.id == terminalID }).flatMap {
                $0.isRunningForegroundProgram ? $0.currentProcessName : nil
            }
        }
        guard !runningPrograms.isEmpty else {
            closeTab(id)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "关闭正在运行的终端标签？"
        alert.informativeText = "\(runningPrograms.count) 个分屏仍在运行命令："
            + Array(Set(runningPrograms)).sorted().joined(separator: "、")
            + "。关闭标签会结束这些进程。"
        alert.addButton(withTitle: "关闭标签")
        alert.addButton(withTitle: "取消")

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.closeTab(id)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            closeTab(id)
        }
    }

    func closeTab(_ id: UUID) {
        guard let terminalIDs = terminalTabs.first(where: { $0.id == id })?
            .terminalIDs else { return }
        for terminalID in terminalIDs {
            closeTerminal(terminalID)
        }
    }

    func closeTerminal(
        _ id: UUID,
        recordsForRestoration: Bool = true
    ) {
        guard let sessionIndex = terminalSessions.firstIndex(where: {
            $0.id == id
        }) else { return }

        let closingSession = terminalSessions[sessionIndex]
        guard let tabIndex = terminalTabs.firstIndex(where: {
            $0.root.contains(id)
        }) else { return }
        let closingTab = terminalTabs[tabIndex]
        let paneIDs = closingTab.terminalIDs
        let paneIndex = paneIDs.firstIndex(of: id)
        let replacementInTab = paneIndex.flatMap { index -> UUID? in
            if index + 1 < paneIDs.count { return paneIDs[index + 1] }
            if index > 0 { return paneIDs[index - 1] }
            return nil
        }
        let directoryTabs = terminalTabs.filter {
            $0.directory.standardizedFileURL.path
                == closingTab.directory.standardizedFileURL.path
        }
        let closingDirectoryTabIndex = directoryTabs.firstIndex {
            $0.id == closingTab.id
        }
        let replacementTabID = closingDirectoryTabIndex.flatMap { index -> UUID? in
            if index + 1 < directoryTabs.count { return directoryTabs[index + 1].id }
            if index > 0 { return directoryTabs[index - 1].id }
            return nil
        }
        if recordsForRestoration {
            recentlyClosedTerminalDirectories.append(closingSession.directory)
            if recentlyClosedTerminalDirectories.count > 20 {
                recentlyClosedTerminalDirectories.removeFirst()
            }
        }
        closingSession.terminal.onClose = nil
        if let updatedRoot = closingTab.root.removing(id) {
            terminalTabs[tabIndex].root = updatedRoot
            if closingTab.focusedTerminalID == id,
               let replacementInTab {
                terminalTabs[tabIndex].focusedTerminalID = replacementInTab
            }
        } else {
            terminalTabs.remove(at: tabIndex)
        }
        terminalSessions.remove(at: sessionIndex)
        if activeTerminalID == id {
            if let replacementInTab {
                activeTerminalID = replacementInTab
            } else if let replacementTabID,
                      let replacementTab = terminalTabs.first(where: {
                          $0.id == replacementTabID
                      }) {
                activeTerminalID = replacementTab.focusedTerminalID
            } else {
                activeTerminalID = nil
            }
        }

        // AppKit may finish dismantling the old split containers after SwiftUI
        // has rendered the collapsed tree. Refresh on the next run loop so the
        // surviving session-owned terminal view is attached to its final pane.
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func restoreLastClosedTerminal() {
        while let directory = recentlyClosedTerminalDirectories.popLast() {
            guard Self.validDirectory(directory) != nil,
                  rootDirectory(containing: directory) != nil else { continue }
            openNewTerminal(for: directory)
            return
        }
    }

    func promptRenameTerminal(_ id: UUID) {
        guard let session = terminalSessions.first(where: {
            $0.id == id
        }) else { return }
        let alert = NSAlert()
        alert.messageText = "重命名终端"
        alert.informativeText = "留空即可恢复跟随前台程序的标题。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(
            string: session.customTitle ?? session.currentProcessName
                ?? session.defaultShellName
        )
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field

        let save = { [weak self, weak field] in
            let value = field?.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            session.customTitle = value?.isEmpty == false ? value : nil
            self?.objectWillChange.send()
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { save() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            save()
        }
    }

    func terminalSessionCount(exactlyAt directory: URL) -> Int {
        let path = directory.standardizedFileURL.path
        return terminalSessions.count {
            $0.directory.standardizedFileURL.path == path
        }
    }

    func hasTerminalSession(in directory: URL) -> Bool {
        let path = directory.standardizedFileURL.path
        return terminalSessions.contains { session in
            let sessionPath = session.directory.standardizedFileURL.path
            return sessionPath == path || sessionPath.hasPrefix(path + "/")
        }
    }

    func hasTerminalSession(exactlyAt directory: URL) -> Bool {
        let path = directory.standardizedFileURL.path
        return terminalSessions.contains {
            $0.directory.standardizedFileURL.path == path
        }
    }

    func hasTerminalSessionDescendant(in directory: URL) -> Bool {
        let prefix = directory.standardizedFileURL.path + "/"
        return terminalSessions.contains {
            $0.directory.standardizedFileURL.path.hasPrefix(prefix)
        }
    }

    func selectFile(_ url: URL) {
        let fileURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard rootDirectory(containing: fileURL) != nil,
              FileManager.default.fileExists(
                  atPath: fileURL.path,
                  isDirectory: &isDirectory
              ),
              !isDirectory.boolValue else { return }

        selectedTreeItemURL = fileURL
        selectedFileURL = fileURL
        QuickLookPreviewController.shared.updatePreviewIfPresented(for: fileURL)
    }

    func selectTreeNode(_ node: FileNode) {
        selectedTreeItemURL = node.url.standardizedFileURL
        if node.isDirectory {
            clearFileSelection()
        } else {
            selectFile(node.url)
        }
    }

    func toggleSelectedFilePreview() {
        guard let selectedFileURL else { return }
        QuickLookPreviewController.shared.togglePreview(for: selectedFileURL)
    }

    var visiblePreviewFileURLs: [URL] {
        visibleTreeNodes.filter { !$0.isDirectory }.map(\.url)
    }

    var visibleTreeNodes: [FileNode] {
        var nodes: [FileNode] = []
        for rootNode in rootNodes {
            appendVisibleTree(node: rootNode, to: &nodes)
        }
        return nodes
    }

    @discardableResult
    func moveTreeSelection(offset: Int) -> Bool {
        guard offset != 0 else { return false }
        let nodes = visibleTreeNodes
        guard !nodes.isEmpty else { return false }

        let currentIndex = selectedTreeItemURL.flatMap { selectedURL in
            nodes.firstIndex {
                $0.url.standardizedFileURL == selectedURL.standardizedFileURL
            }
        } ?? nodes.startIndex
        let targetIndex = min(
            max(currentIndex + offset, nodes.startIndex),
            nodes.index(before: nodes.endIndex)
        )
        selectTreeNode(nodes[targetIndex])
        return true
    }

    @discardableResult
    func expandOrEnterSelectedTreeDirectory() -> Bool {
        guard let node = selectedVisibleTreeNode,
              node.isDirectory else { return false }

        if !isDirectoryExpanded(node.url) {
            setDirectoryExpanded(true, url: node.url)
            node.loadChildren()
            return true
        }

        guard let child = visibleChildren(of: node).first else { return true }
        selectTreeNode(child)
        return true
    }

    @discardableResult
    func collapseOrSelectParentTreeDirectory() -> Bool {
        guard let node = selectedVisibleTreeNode else { return false }

        if node.isDirectory, isDirectoryExpanded(node.url) {
            setDirectoryExpanded(false, url: node.url)
            return true
        }

        let parentURL = node.url.deletingLastPathComponent().standardizedFileURL
        guard let parent = visibleTreeNodes.first(where: {
            $0.url.standardizedFileURL == parentURL
        }) else { return true }
        selectTreeNode(parent)
        return true
    }

    @discardableResult
    func activateSelectedTreeDirectory() -> Bool {
        guard let node = selectedVisibleTreeNode,
              node.isDirectory else { return false }
        activateTerminal(for: node.url)
        return true
    }

    @discardableResult
    func openSelectedTreeItemInTerminal() -> Bool {
        guard let node = selectedVisibleTreeNode else { return false }
        if node.isDirectory {
            activateTerminal(for: node.url)
            return true
        }

        let fileURL = node.url.standardizedFileURL
        return makeSplitTerminal(
            direction: .right,
            initialInput: TerminalFileViewer.command(for: fileURL) + "\n",
            customTitle: fileURL.lastPathComponent
        ) != nil
    }

    func clearFileSelection() {
        selectedFileURL = nil
        QuickLookPreviewController.shared.closePreview()
    }

    func isDirectoryExpanded(_ url: URL) -> Bool {
        guard let rootPath = rootDirectory(containing: url)?.path else {
            return false
        }
        return expandedDirectoryPaths[rootPath]?.contains(
            url.standardizedFileURL.path
        ) == true
    }

    func setDirectoryExpanded(_ expanded: Bool, url: URL) {
        guard let rootPath = rootDirectory(containing: url)?.path else { return }
        let path = url.standardizedFileURL.path
        if expanded {
            expandedDirectoryPaths[rootPath, default: []].insert(path)
        } else {
            expandedDirectoryPaths[rootPath]?.remove(path)
        }
    }

    private var selectedVisibleTreeNode: FileNode? {
        guard let selectedTreeItemURL else { return nil }
        return visibleTreeNodes.first {
            $0.url.standardizedFileURL
                == selectedTreeItemURL.standardizedFileURL
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

    private func moveTab(
        containing sourceID: UUID,
        beforeTabContaining targetID: UUID
    ) {
        guard let sourceIndex = terminalTabs.firstIndex(where: {
                  $0.root.contains(sourceID)
              }),
              let targetIndex = terminalTabs.firstIndex(where: {
                  $0.root.contains(targetID)
              }),
              sourceIndex != targetIndex,
              terminalTabs[sourceIndex].directory
                  == terminalTabs[targetIndex].directory else { return }
        let tab = terminalTabs.remove(at: sourceIndex)
        guard let updatedTargetIndex = terminalTabs.firstIndex(where: {
            $0.root.contains(targetID)
        }) else { return }
        terminalTabs.insert(tab, at: updatedTargetIndex)
    }

    private func moveTab(
        containing sourceID: UUID,
        afterTabContaining targetID: UUID
    ) {
        guard let sourceIndex = terminalTabs.firstIndex(where: {
                  $0.root.contains(sourceID)
              }),
              let targetIndex = terminalTabs.firstIndex(where: {
                  $0.root.contains(targetID)
              }),
              sourceIndex != targetIndex,
              terminalTabs[sourceIndex].directory
                  == terminalTabs[targetIndex].directory else { return }
        let tab = terminalTabs.remove(at: sourceIndex)
        guard let updatedTargetIndex = terminalTabs.firstIndex(where: {
            $0.root.contains(targetID)
        }) else { return }
        terminalTabs.insert(tab, at: updatedTargetIndex + 1)
    }

    private func visibleChildren(of node: FileNode) -> [FileNode] {
        guard showTerminalDirectoriesOnly else { return node.children }
        return node.children.filter {
            $0.isDirectory && hasTerminalSession(in: $0.url)
        }
    }

    private func appendVisibleTree(
        node: FileNode,
        to result: inout [FileNode]
    ) {
        result.append(node)
        guard node.isDirectory, isDirectoryExpanded(node.url) else { return }
        for child in visibleChildren(of: node) {
            appendVisibleTree(node: child, to: &result)
        }
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
    }

    private func applyPreferencesToExistingTerminals() {
        for session in terminalSessions {
            session.applyVisualPreferences(terminalPreferences)
        }
    }

    private func handleFileChanges(_ changes: WorkspaceFileChanges) {
        scheduleFileRefresh(
            affectedPaths: changes.requiresFullScan ? nil : changes.paths
        )
    }

    private func scheduleFileRefresh(affectedPaths: Set<String>?) {
        fileRefreshTask?.cancel()
        let rootNodes = rootNodes
        fileRefreshTask = Task {
            for rootNode in rootNodes {
                await rootNode.reloadLoadedTree(affectedPaths: affectedPaths)
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled,
                  let selectedFileURL,
                  !FileManager.default.fileExists(
                      atPath: selectedFileURL.path
                  ) else { return }
            clearFileSelection()
        }
    }

    private func restartFileWatcher() {
        guard watchesFiles else { return }
        fileWatcher.start(watching: rootURLs)
    }

    private func persistWorkspaceState() {
        defaults.set(rootURLs.map(\.path), forKey: Keys.rootDirectoryPaths)
        if let activeDirectory {
            defaults.set(activeDirectory.path, forKey: Keys.activeDirectoryPath)
        } else {
            defaults.removeObject(forKey: Keys.activeDirectoryPath)
        }
    }

    private func presentRootAdditionFailures(
        _ results: [WorkspaceRootAdditionResult]
    ) {
        let messages = results.compactMap { result -> String? in
            switch result {
            case .added:
                nil
            case let .invalid(url):
                "“\(url.path)”不是可用目录。"
            case let .duplicate(url):
                "“\(url.lastPathComponent)”已经在工作区中。"
            case let .overlaps(candidate, existing):
                "“\(candidate.lastPathComponent)”与“\(existing.lastPathComponent)”存在父子关系。"
            }
        }
        guard !messages.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "部分目录未添加"
        alert.informativeText = messages.joined(separator: "\n")
        alert.addButton(withTitle: "好")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func validDirectory(_ url: URL?) -> URL? {
        guard let url else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let descendantPrefix = rootPath == "/" ? "/" : rootPath + "/"
        return path == rootPath || path.hasPrefix(descendantPrefix)
    }

    private static func pathsOverlap(_ left: URL, _ right: URL) -> Bool {
        isInside(left, root: right) || isInside(right, root: left)
    }

    private static func restoredRootDirectories(
        from defaults: UserDefaults
    ) -> [URL] {
        guard let paths = defaults.stringArray(forKey: Keys.rootDirectoryPaths) else {
            return []
        }
        var roots: [URL] = []
        for path in paths {
            guard let directory = validDirectory(URL(fileURLWithPath: path)),
                  !roots.contains(where: { pathsOverlap($0, directory) }) else {
                continue
            }
            roots.append(directory)
        }
        return roots
    }

    private static func restoredActiveDirectory(
        from defaults: UserDefaults,
        roots: [URL]
    ) -> URL? {
        guard let path = defaults.string(forKey: Keys.activeDirectoryPath),
              let directory = validDirectory(URL(fileURLWithPath: path)),
              roots.contains(where: { isInside(directory, root: $0) }) else {
            return nil
        }
        return directory
    }

    private static func makeRootNode(for url: URL) -> FileNode {
        let node = FileNode(url: url, isDirectory: true)
        node.loadChildren()
        return node
    }

    private enum Keys {
        static let rootDirectoryPaths = "workspace.rootDirectoryPaths.v1"
        static let activeDirectoryPath = "workspace.activeDirectoryPath.v1"
        static let obsoletePersistedState = [
            "rootDirectoryPath",
            "workspacePath",
            "lastDirectoryPaths",
            "expandedDirectoryPaths",
            "recentWorkspacePaths",
            "sidebar.isVisible",
            "sidebar.width",
        ]
    }
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let directory: URL
    let terminal: TerminalViewState
    let defaultShellName: String
    let usesGhosttyConfiguration: Bool
    var terminalView: TerminalView?
    @Published var customTitle: String?
    @Published var isSearchPresented = false
    @Published var searchQuery = ""
    private var pendingInput: String?

    init(
        directory: URL,
        preferences: TerminalPreferences? = nil,
        defaultShellPath: String? = nil,
        surfaceContext: TerminalSurfaceContext = .window,
        initialInput: String? = nil
    ) {
        let preferences = preferences ?? TerminalPreferences()
        self.directory = directory.standardizedFileURL
        let shellPath = defaultShellPath ?? preferences.shellPath
        defaultShellName = Self.processName(
            from: shellPath.isEmpty ? Self.loginShellPath : shellPath
        ) ?? "shell"
        usesGhosttyConfiguration = preferences.resolvedGhosttyConfigURL != nil

        let configSource: TerminalController.ConfigSource = preferences
            .resolvedGhosttyConfigURL
            .map { .file($0.path) } ?? .none
        terminal = TerminalViewState(
            configSource: configSource,
            theme: preferences.terminalTheme,
            terminalConfiguration: preferences.terminalConfiguration
        )
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: directory.path,
            context: surfaceContext
        )
        pendingInput = initialInput
    }

    var currentProcessName: String? {
        let pid = terminalView?.foregroundPid.flatMap { value in
            value > 0 ? UInt64(value) : nil
        }
        return Self.processName(for: pid)
    }

    var isRunningForegroundProgram: Bool {
        guard let currentProcessName else { return false }
        return currentProcessName != defaultShellName
    }

    func presentSearch() {
        isSearchPresented = true
    }

    func updateSearch(_ query: String) {
        _ = terminalView?.performBindingAction(
            TerminalSearchAction.update(query: query)
        )
    }

    func navigateSearch(forward: Bool) {
        guard isSearchPresented else { return }
        _ = terminalView?.performBindingAction(
            TerminalSearchAction.navigate(forward: forward)
        )
    }

    func dismissSearch() {
        guard isSearchPresented else { return }
        _ = terminalView?.performBindingAction(TerminalSearchAction.end)
        isSearchPresented = false
    }

    func sendPendingInputIfReady() {
        guard let pendingInput, terminal.send(pendingInput) else { return }
        self.pendingInput = nil
    }

    func displayTitle(foregroundProcessName: String?) -> String {
        if let customTitle,
           !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customTitle
        }
        guard let foregroundProcessName else { return defaultShellName }
        return Self.processName(from: foregroundProcessName) ?? defaultShellName
    }

    func applyVisualPreferences(_ preferences: TerminalPreferences) {
        guard usesGhosttyConfiguration
            == (preferences.resolvedGhosttyConfigURL != nil) else { return }
        _ = terminal.controller.setTheme(preferences.terminalTheme)
        _ = terminal.controller.setTerminalConfiguration(
            preferences.terminalConfiguration
        )
    }

    static func processName(for pidValue: UInt64?) -> String? {
        guard let pidValue, pidValue <= UInt64(Int32.max) else { return nil }
        let pid = pid_t(pidValue)
        var pathBuffer = [UInt8](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLength > 0 {
            let path = String(
                decoding: pathBuffer.prefix(Int(pathLength)),
                as: UTF8.self
            )
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty { return name }
        }

        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        guard nameLength > 0 else { return nil }
        return String(cString: nameBuffer)
    }

    private static var loginShellPath: String {
        if let shellPath = ProcessInfo.processInfo.environment["SHELL"],
           !shellPath.isEmpty {
            return shellPath
        }
        if let user = getpwuid(getuid()),
           let shell = user.pointee.pw_shell {
            return String(cString: shell)
        }
        return "shell"
    }

    private static func processName(from value: String) -> String? {
        let name = URL(fileURLWithPath: value)
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? nil : name
    }
}

enum TerminalFileViewer {
    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn",
    ]

    static func command(for fileURL: URL) -> String {
        let path = shellQuoted(fileURL.standardizedFileURL.path)
        let vim = "vim -- \(path)"
        guard markdownExtensions.contains(fileURL.pathExtension.lowercased()) else {
            return vim + "; exit"
        }

        return "if command -v glow >/dev/null 2>&1; then "
            + "VISUAL=vim EDITOR=vim glow --tui -- \(path) || \(vim); "
            + "else \(vim); fi; exit"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
