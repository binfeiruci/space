import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import GhosttyTerminal

enum WorkspaceRootAdditionResult: Equatable {
    case added(URL)
    case invalid(URL)
    case duplicate(URL)
}

struct WorkspaceFolder: Identifiable, Equatable {
    let url: URL

    var id: String {
        url.standardizedFileURL.path
    }
}

struct WorkspaceAlertState: Identifiable, Equatable {
    enum Action: Equatable {
        case removeRoot(URL)
        case closeTerminal(UUID)
        case closeTab(UUID)
    }

    let id = UUID()
    let title: String
    let message: String
    let confirmationTitle: String?
    let action: Action?
}

struct TerminalRenameRequest: Identifiable, Equatable {
    let id = UUID()
    let terminalID: UUID
    let initialTitle: String
}

struct AgentAttentionNotification: Identifiable, Equatable {
    let id: UUID
    let title: String
    let body: String
    let receivedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.receivedAt = receivedAt
    }
}

struct MemoSaveNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
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

enum FolderMemoFile {
    static let filename = ".memo"

    static func append(
        _ text: String,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        in directory: URL
    ) throws {
        guard !text.isEmpty else { return }

        let fileURL = directory.appendingPathComponent(filename)
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: fileURL.path)
        var data = Data()

        if exists {
            let attributes = try fileManager.attributesOfItem(
                atPath: fileURL.path
            )
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if fileSize > 0 {
                let readHandle = try FileHandle(forReadingFrom: fileURL)
                defer { try? readHandle.close() }
                let endingSize = min(fileSize, 2)
                try readHandle.seek(toOffset: fileSize - endingSize)
                let ending = try readHandle.read(upToCount: Int(endingSize))
                    ?? Data()
                let newlineCount = ending.reversed().prefix { $0 == 0x0A }.count
                for _ in newlineCount ..< 2 {
                    data.append(0x0A)
                }
            }
        }

        let entry = memoEntry(
            text: text,
            date: date,
            timeZone: timeZone
        )
        data.append(contentsOf: entry.utf8)
        let newlineCount = data.reversed().prefix { $0 == 0x0A }.count
        for _ in newlineCount ..< 2 {
            data.append(0x0A)
        }

        if exists {
            let writeHandle = try FileHandle(forWritingTo: fileURL)
            defer { try? writeHandle.close() }
            try writeHandle.seekToEnd()
            try writeHandle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private static func memoEntry(
        text: String,
        date: Date,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "---\n\(formatter.string(from: date))\n\n\(text)"
    }
}

private struct PasteboardSnapshot {
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        } ?? []
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let pasteboardItems = items.map { values in
            let item = NSPasteboardItem()
            for value in values {
                item.setData(value.data, forType: value.type)
            }
            return item
        }
        if !pasteboardItems.isEmpty {
            pasteboard.writeObjects(pasteboardItems)
        }
    }
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

    func settingRatio(_ newRatio: CGFloat, for splitID: UUID)
        -> TerminalSplitNode {
        switch self {
        case .pane:
            return self
        case let .split(id, axis, ratio, first, second):
            return .split(
                id: id,
                axis: axis,
                ratio: id == splitID
                    ? min(max(newRatio, 0.1), 0.9)
                    : ratio,
                first: first.settingRatio(newRatio, for: splitID),
                second: second.settingRatio(newRatio, for: splitID)
            )
        }
    }

    func balancedForEqualSplits() -> TerminalSplitNode {
        switch self {
        case .pane:
            return self
        case let .split(id, axis, _, first, second):
            let balancedFirst = first.balancedForEqualSplits()
            let balancedSecond = second.balancedForEqualSplits()
            let firstSpan = balancedFirst.spanCount(along: axis)
            let secondSpan = balancedSecond.spanCount(along: axis)
            return .split(
                id: id,
                axis: axis,
                ratio: CGFloat(firstSpan) / CGFloat(firstSpan + secondSpan),
                first: balancedFirst,
                second: balancedSecond
            )
        }
    }

    private func spanCount(along axis: TerminalSplitAxis) -> Int {
        switch self {
        case .pane:
            return 1
        case let .split(_, splitAxis, _, first, second):
            guard splitAxis == axis else { return 1 }
            return first.spanCount(along: axis)
                + second.spanCount(along: axis)
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
final class AppModel: ObservableObject {
    @Published private(set) var folders: [WorkspaceFolder]
    @Published private(set) var activeDirectory: URL?
    @Published private(set) var terminalSessions: [TerminalSession]
    @Published private(set) var terminalTabs: [TerminalTabState]
    @Published private(set) var activeTerminalID: UUID?
    @Published private(set) var alertState: WorkspaceAlertState?
    @Published private(set) var renameRequest: TerminalRenameRequest?
    @Published private(set) var memoSaveNotice: MemoSaveNotice?
    @Published private(set) var isFolderImporterPresented = false
    @Published private(set) var isSidebarVisible = true
    @Published private(set) var agentAttentionByTerminalID:
        [UUID: AgentAttentionNotification] = [:]
    @Published private var refreshingTitleFrameByTerminalID: [UUID: String] = [:]

    let terminalPreferences: TerminalPreferences
    var agentAttentionHandler:
        ((UUID, URL, AgentAttentionNotification) -> Void)?
    var agentAttentionClearedHandler: ((UUID) -> Void)?

    private let defaults: UserDefaults
    private var agentAttentionCancellables: [UUID: AnyCancellable] = [:]
    private var agentAttentionFocusCancellables: [UUID: AnyCancellable] = [:]
    private var terminalTitleCancellables: [UUID: AnyCancellable] = [:]
    private var recentlyClosedTerminalDirectories: [URL] = []
    private var lastActiveTabIDByDirectory: [String: UUID] = [:]

    init(
        defaults: UserDefaults = .standard,
        initialRootURL: URL? = nil,
        defaultRootURL: URL? = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.defaults = defaults
        terminalPreferences = TerminalPreferences(defaults: defaults)

        let restoredRoots = Self.restoredRootDirectories(from: defaults)
        var roots: [URL]
        if let initialRoot = Self.validDirectory(initialRootURL) {
            roots = [initialRoot]
        } else {
            roots = restoredRoots
            if !defaults.bool(forKey: Keys.didAddDefaultFolder) {
                if let defaultRoot = Self.validDirectory(defaultRootURL),
                   !roots.contains(where: {
                       $0.standardizedFileURL.path == defaultRoot.path
                   }) {
                    roots.insert(defaultRoot, at: 0)
                }
                defaults.set(true, forKey: Keys.didAddDefaultFolder)
            }
        }
        let restoredActiveDirectory = Self.restoredActiveDirectory(
            from: defaults,
            roots: roots
        )
        let initialDirectory = restoredActiveDirectory ?? roots.first

        folders = roots.map { WorkspaceFolder(url: $0) }
        activeDirectory = initialDirectory
        terminalSessions = []
        terminalTabs = []
        activeTerminalID = nil

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
            lastActiveTabIDByDirectory[initialDirectory.path] = initialSession.id
            bindCloseHandler(to: initialSession)
        }
        persistWorkspaceState()
    }

    var rootURLs: [URL] {
        folders.map(\.url)
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

    var activeTerminalSession: TerminalSession? {
        guard let activeTerminalID else { return nil }
        return terminalSessions.first { $0.id == activeTerminalID }
    }

    var canRestoreClosedTerminal: Bool {
        !recentlyClosedTerminalDirectories.isEmpty
    }

    func chooseRootDirectory() {
        isFolderImporterPresented = true
    }

    func dismissFolderImporter() {
        isFolderImporterPresented = false
    }

    @discardableResult
    func sendActiveSelectionToMemo() -> Bool {
        guard let session = activeTerminalSession,
              let terminalView = session.terminalView else { return false }

        let pasteboard = NSPasteboard.general
        let pasteboardSnapshot = PasteboardSnapshot(pasteboard)
        guard terminalView.copySelectedTextToPasteboard() else { return false }
        defer { pasteboardSnapshot.restore(to: pasteboard) }
        guard let selection = pasteboard.string(forType: .string),
              !selection.isEmpty else { return false }

        do {
            try FolderMemoFile.append(
                selection,
                in: session.directory
            )
            memoSaveNotice = MemoSaveNotice(message: "Saved to .memo")
            return true
        } catch {
            alertState = WorkspaceAlertState(
                title: "无法写入备忘录",
                message: error.localizedDescription,
                confirmationTitle: nil,
                action: nil
            )
            return false
        }
    }

    func dismissMemoSaveNotice(_ id: UUID) {
        guard memoSaveNotice?.id == id else { return }
        memoSaveNotice = nil
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func addRootDirectories(_ urls: [URL]) {
        var results: [WorkspaceRootAdditionResult] = []
        var lastAddedFolder: URL?
        for url in urls {
            let result = addRootDirectory(url, activate: false)
            results.append(result)
            if case let .added(folder) = result {
                lastAddedFolder = folder
            }
        }
        if let lastAddedFolder {
            activateTerminal(for: lastAddedFolder)
        }
        presentRootAdditionFailures(results)
    }

    func presentFolderImportError(_ error: Error) {
        alertState = WorkspaceAlertState(
            title: "无法添加文件夹",
            message: error.localizedDescription,
            confirmationTitle: nil,
            action: nil
        )
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
        folders.append(WorkspaceFolder(url: directory))
        persistWorkspaceState()

        if activate {
            activateTerminal(for: directory)
        }
        return .added(directory)
    }

    func rootDirectory(containing url: URL) -> URL? {
        rootURLs
            .filter { Self.isInside(url, root: $0) }
            .max { $0.path.count < $1.path.count }
    }

    func requestRemoveRootDirectory(_ url: URL) {
        guard let root = rootURLs.first(where: {
            $0.standardizedFileURL.path == url.standardizedFileURL.path
        }) else { return }
        let rootPath = root.standardizedFileURL.path
        let sessionCount = terminalSessions.count {
            $0.directory.standardizedFileURL.path == rootPath
        }
        guard sessionCount > 0 else {
            removeRootDirectory(root)
            return
        }

        alertState = WorkspaceAlertState(
            title: "移除文件夹“\(root.lastPathComponent)”？",
            message: "将关闭该文件夹的 \(sessionCount) 个终端及正在运行的程序。",
            confirmationTitle: "移除并关闭终端",
            action: .removeRoot(root)
        )
    }

    func removeRootDirectory(_ url: URL) {
        let root = url.standardizedFileURL
        guard let rootIndex = folders.firstIndex(where: {
            $0.url.standardizedFileURL.path == root.path
        }) else { return }

        let removedSessionIDs = Set(terminalSessions.compactMap { session in
            session.directory.standardizedFileURL.path == root.path
                ? session.id
                : nil
        })
        for session in terminalSessions where removedSessionIDs.contains(session.id) {
            session.terminal.onClose = nil
            agentAttentionCancellables.removeValue(forKey: session.id)
            agentAttentionFocusCancellables.removeValue(forKey: session.id)
            stopTrackingTerminalTitle(for: session.id)
            clearAgentAttention(for: session.id)
        }
        terminalSessions.removeAll { removedSessionIDs.contains($0.id) }
        terminalTabs.removeAll {
            $0.directory.standardizedFileURL.path == root.path
        }
        recentlyClosedTerminalDirectories.removeAll {
            $0.standardizedFileURL.path == root.path
        }
        folders.remove(at: rootIndex)
        lastActiveTabIDByDirectory.removeValue(forKey: root.path)

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
        }

        persistWorkspaceState()
    }

    func setFolderOrder(_ orderedFolders: [WorkspaceFolder]) {
        guard orderedFolders.count == folders.count,
              Set(orderedFolders.map(\.id)) == Set(folders.map(\.id)) else {
            return
        }
        folders = orderedFolders
        persistWorkspaceState()
    }

    func activateTerminal(for url: URL) {
        guard let folder = rootDirectory(containing: url.standardizedFileURL)
        else { return }

        let folderPath = folder.path
        if let terminalID = latestAgentAttentionTerminalID(in: folder) {
            selectTerminal(terminalID)
            return
        }
        let rememberedTab = lastActiveTabIDByDirectory[folderPath].flatMap {
            rememberedID in terminalTabs.first(where: {
                $0.id == rememberedID
                    && $0.directory.standardizedFileURL.path == folderPath
            })
        }
        if let existing = rememberedTab ?? terminalTabs.last(where: {
            $0.directory.standardizedFileURL.path == folderPath
        }) {
            activeDirectory = folder
            activeTerminalID = existing.focusedTerminalID
            lastActiveTabIDByDirectory[folderPath] = existing.id
            persistWorkspaceState()
            return
        }

        openNewTerminal(for: folder)
    }

    func openNewTerminal(for url: URL) {
        guard let folder = rootDirectory(containing: url.standardizedFileURL)
        else { return }

        let session = TerminalSession(
            directory: folder,
            preferences: terminalPreferences
        )
        bindCloseHandler(to: session)
        activeDirectory = folder
        terminalSessions.append(session)
        terminalTabs.append(TerminalTabState(
            id: session.id,
            directory: folder,
            root: .pane(session.id),
            focusedTerminalID: session.id
        ))
        activeTerminalID = session.id
        lastActiveTabIDByDirectory[folder.path] = session.id
        persistWorkspaceState()
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
              let tabIndex = terminalTabs.firstIndex(where: {
                  $0.root.contains(activeTerminalID)
              }) else { return nil }

        let session = TerminalSession(
            directory: activeSession.directory,
            preferences: terminalPreferences,
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
        self.activeTerminalID = session.id
        lastActiveTabIDByDirectory[activeSession.directory.path] =
            terminalTabs[tabIndex].id
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
        terminalTabs[tabIndex].focusedTerminalID = id
        activeDirectory = session.directory
        activeTerminalID = session.id
        clearAgentAttention(for: id)
        lastActiveTabIDByDirectory[session.directory.standardizedFileURL.path] =
            terminalTabs[tabIndex].id
        persistWorkspaceState()
    }

    func selectTab(_ id: UUID) {
        guard let tab = terminalTabs.first(where: { $0.id == id }) else { return }
        selectTerminal(
            latestAgentAttentionTerminalID(in: tab.terminalIDs)
                ?? tab.focusedTerminalID
        )
    }

    func tabNeedsAgentAttention(_ id: UUID) -> Bool {
        guard let tab = terminalTabs.first(where: { $0.id == id }) else {
            return false
        }
        return latestAgentAttentionTerminalID(in: tab.terminalIDs) != nil
    }

    func folderNeedsAgentAttention(_ url: URL) -> Bool {
        latestAgentAttentionTerminalID(in: url.standardizedFileURL) != nil
    }

    func folderRefreshingTitleFrame(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        for session in terminalSessions.reversed()
        where session.directory.standardizedFileURL.path == path {
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
        } else {
            refreshingTitleFrameByTerminalID.removeValue(forKey: terminalID)
        }
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
        guard let session = terminalSessions.first(where: {
            $0.id == terminalID
        }) else { return }

        if applicationIsActive,
           activeTerminalID == terminalID,
           terminalIsFocused {
            clearAgentAttention(for: terminalID)
            return
        }

        agentAttentionByTerminalID[terminalID] = notification
        agentAttentionHandler?(terminalID, session.directory, notification)
    }

    func clearVisibleAgentAttention() {
        guard NSApp.isActive,
              let terminalID = activeTerminalID,
              let session = terminalSessions.first(where: {
                  $0.id == terminalID
              }),
              session.terminal.isFocused else { return }
        clearAgentAttention(for: terminalID)
    }

    @discardableResult
    func selectTerminal(at index: Int) -> Bool {
        let tabs = activeDirectoryTabs
        guard tabs.indices.contains(index) else { return false }
        selectTab(tabs[index].id)
        return true
    }

    @discardableResult
    func selectLastTerminal() -> Bool {
        guard let tab = activeDirectoryTabs.last else { return false }
        selectTab(tab.id)
        return true
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
    func selectAdjacentFolder(offset: Int) -> Bool {
        guard folders.count > 1,
              let activeDirectory,
              let activeFolder = rootDirectory(containing: activeDirectory),
              let index = folders.firstIndex(where: {
                  $0.url.standardizedFileURL.path == activeFolder.path
              }) else { return false }
        let next = (index + offset + folders.count) % folders.count
        activateTerminal(for: folders[next].url)
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

        alertState = WorkspaceAlertState(
            title: "关闭正在运行的终端？",
            message: (session.currentProcessName ?? "程序")
                + " 仍在运行，关闭终端会结束该进程。",
            confirmationTitle: "关闭终端",
            action: .closeTerminal(id)
        )
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

        alertState = WorkspaceAlertState(
            title: "关闭正在运行的终端标签？",
            message: "\(runningPrograms.count) 个分屏仍在运行命令："
                + Array(Set(runningPrograms)).sorted().joined(separator: "、")
                + "。关闭标签会结束这些进程。",
            confirmationTitle: "关闭标签",
            action: .closeTab(id)
        )
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
        let directoryPath = closingTab.directory.standardizedFileURL.path
        if recordsForRestoration {
            recentlyClosedTerminalDirectories.append(closingSession.directory)
            if recentlyClosedTerminalDirectories.count > 20 {
                recentlyClosedTerminalDirectories.removeFirst()
            }
        }
        closingSession.terminal.onClose = nil
        agentAttentionCancellables.removeValue(forKey: id)
        agentAttentionFocusCancellables.removeValue(forKey: id)
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
        if terminalTabs.contains(where: { $0.id == closingTab.id }) {
            lastActiveTabIDByDirectory[directoryPath] = closingTab.id
        } else if let replacementTabID {
            lastActiveTabIDByDirectory[directoryPath] = replacementTabID
        } else {
            lastActiveTabIDByDirectory.removeValue(forKey: directoryPath)
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
        renameRequest = TerminalRenameRequest(
            terminalID: id,
            initialTitle: session.displayTitle(
                terminalTitle: session.terminal.title,
                foregroundProcessName: session.currentProcessName
            )
        )
    }

    func saveTerminalRename(_ request: TerminalRenameRequest, title: String) {
        guard let session = terminalSessions.first(where: {
            $0.id == request.terminalID
        }) else {
            renameRequest = nil
            return
        }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customTitle = value.isEmpty ? nil : value
        renameRequest = nil
        objectWillChange.send()
    }

    func dismissRenameRequest() {
        renameRequest = nil
    }

    func dismissAlert() {
        alertState = nil
    }

    func confirmAlert(_ alert: WorkspaceAlertState) {
        guard alertState?.id == alert.id else { return }
        alertState = nil
        switch alert.action {
        case let .removeRoot(url):
            removeRootDirectory(url)
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

        agentAttentionCancellables[sessionID] = session.terminal
            .$lastDesktopNotificationAt
            .compactMap { $0 }
            .sink { [weak self, weak session] receivedAt in
                guard let self, let session else { return }
                self.receiveAgentAttention(
                    AgentAttentionNotification(
                        title: session.terminal.lastDesktopNotificationTitle ?? "",
                        body: session.terminal.lastDesktopNotificationBody ?? "",
                        receivedAt: receivedAt
                    ),
                    from: sessionID,
                    terminalIsFocused: session.terminal.isFocused
                )
            }

        agentAttentionFocusCancellables[sessionID] = session.terminal
            .$isFocused
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.clearVisibleAgentAttention()
            }

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
        in directory: URL
    ) -> UUID? {
        let path = directory.standardizedFileURL.path
        let terminalIDs = terminalTabs
            .filter { $0.directory.standardizedFileURL.path == path }
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
        guard agentAttentionByTerminalID.removeValue(
            forKey: terminalID
        ) != nil else { return }
        agentAttentionClearedHandler?(terminalID)
    }

    private func persistWorkspaceState() {
        defaults.set(rootURLs.map(\.path), forKey: Keys.folderPaths)
        if let activeDirectory {
            defaults.set(activeDirectory.path, forKey: Keys.activeFolderPath)
        } else {
            defaults.removeObject(forKey: Keys.activeFolderPath)
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
                "“\(url.path)”不是可用文件夹。"
            case let .duplicate(url):
                "文件夹“\(url.lastPathComponent)”已经添加。"
            }
        }
        guard !messages.isEmpty else { return }

        alertState = WorkspaceAlertState(
            title: "部分文件夹未添加",
            message: messages.joined(separator: "\n"),
            confirmationTitle: nil,
            action: nil
        )
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

    private static func restoredRootDirectories(
        from defaults: UserDefaults
    ) -> [URL] {
        guard let paths = defaults.stringArray(
            forKey: Keys.folderPaths
        ) else {
            return []
        }
        var roots: [URL] = []
        for path in paths {
            guard let directory = validDirectory(URL(fileURLWithPath: path)),
                  !roots.contains(where: {
                      $0.standardizedFileURL.path == directory.path
                  }) else {
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
        guard let path = defaults.string(forKey: Keys.activeFolderPath),
              let directory = validDirectory(URL(fileURLWithPath: path)),
              roots.contains(where: {
                  $0.standardizedFileURL.path == directory.path
              }) else {
            return nil
        }
        return directory
    }

    private enum Keys {
        static let folderPaths = "workspace.folderPaths.v1"
        static let activeFolderPath = "workspace.activeFolderPath.v1"
        static let didAddDefaultFolder = "workspace.didAddDefaultFolder.v1"
    }
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let directory: URL
    let terminal: TerminalViewState
    let defaultShellName: String
    var terminalView: TerminalView?
    @Published var customTitle: String?
    @Published var isSearchPresented = false
    @Published var searchQuery = ""
    @Published private(set) var searchFocusRequest = 0
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
        let shellPath = defaultShellPath ?? Self.loginShellPath
        defaultShellName = Self.processName(
            from: shellPath
        ) ?? "shell"

        terminal = TerminalViewState(
            configSource: preferences.ghosttyConfigSource
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
        searchFocusRequest &+= 1
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

    func displayTitle(
        terminalTitle: String,
        foregroundProcessName: String?
    ) -> String {
        if let customTitle,
           !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customTitle
        }
        let title = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !Self.isPathTitle(title) {
            return title
        }
        guard let foregroundProcessName else { return defaultShellName }
        return Self.processName(from: foregroundProcessName) ?? defaultShellName
    }

    private static func isPathTitle(_ title: String) -> Bool {
        title == "~"
            || title.hasPrefix("~/")
            || title.hasPrefix("/")
            || title.hasPrefix("file://")
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
