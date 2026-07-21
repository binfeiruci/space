import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import GhosttyTerminal

enum FolderAdditionResult: Equatable {
    case added(URL)
    case invalid(URL)
    case duplicate(URL)
}

struct Folder: Identifiable, Equatable {
    let url: URL

    var id: String {
        url.standardizedFileURL.path
    }

    var displayName: String {
        let folderURL = url.resolvingSymlinksInPath().standardizedFileURL
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return folderURL == homeURL ? "~" : url.lastPathComponent
    }
}

struct AlertRequest: Identifiable, Equatable {
    enum Action: Equatable {
        case removeFolder(URL)
        case closeTerminal(UUID)
        case closeTab(UUID)
    }

    let id = UUID()
    let title: String
    let message: String
    let confirmationTitle: String?
    let action: Action?
}

struct TabRenameRequest: Identifiable, Equatable {
    let id = UUID()
    let tabID: UUID
    let initialTitle: String
    let automaticTitle: String
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
    let systemImage: String
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
        in folderURL: URL
    ) throws {
        guard !text.isEmpty else { return }

        let fileURL = folderURL.appendingPathComponent(filename)
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
                    ? min(max(newRatio, 0), 1)
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
            let clampedRatio = min(max(ratio, 0), 1)
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
    let ownerFolderURL: URL?
    var root: TerminalSplitNode
    var focusedTerminalID: UUID
    var customTitle: String? = nil

    var terminalIDs: [UUID] {
        root.terminalIDs
    }

    func displayTitle(automaticTitle: String) -> String {
        guard let customTitle,
              !customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                  .isEmpty else { return automaticTitle }
        return customTitle
    }
}

private struct ClosedTerminalLocation {
    let workingDirectoryURL: URL
    let ownerFolderURL: URL?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var folders: [Folder]
    @Published private var sidebarFolderPaths: [String]
    @Published private(set) var terminalSessions: [TerminalSession]
    @Published private(set) var terminalTabs: [TerminalTabState]
    @Published private(set) var activeTabID: UUID?
    @Published private(set) var alertRequest: AlertRequest?
    @Published private(set) var renameRequest: TabRenameRequest?
    @Published private(set) var memoSaveNotice: MemoSaveNotice?
    @Published private(set) var isFolderImporterPresented = false
    @Published private(set) var isSidebarVisible = true
    @Published private(set) var agentAttentionByTerminalID:
        [UUID: AgentAttentionNotification] = [:]
    @Published private var refreshingTitleFrameByTerminalID: [UUID: String] = [:]

    let settings: AppSettings
    var agentAttentionHandler:
        ((UUID, URL, AgentAttentionNotification) -> Void)?
    var agentAttentionClearedHandler: ((UUID) -> Void)?
    var closeWindowHandler: (() -> Void)?

    private let defaults: UserDefaults
    private var agentAttentionCancellables: [UUID: AnyCancellable] = [:]
    private var agentAttentionFocusCancellables: [UUID: AnyCancellable] = [:]
    private var terminalTitleCancellables: [UUID: AnyCancellable] = [:]
    private var recentlyClosedTerminalLocations: [ClosedTerminalLocation] = []
    private var lastActiveStandaloneTabID: UUID?
    private var lastActiveTabIDByFolderPath: [String: UUID] = [:]

    init(
        defaults: UserDefaults = .standard,
        initialFolderURL: URL? = nil
    ) {
        self.defaults = defaults
        settings = AppSettings(defaults: defaults)

        let restoredFolders = Self.restoredFolders(from: defaults)
        let requestedInitialFolderURL = Self.validFolderURL(initialFolderURL)
        let folderURLs: [URL]
        if let initialFolder = requestedInitialFolderURL {
            folderURLs = [initialFolder]
        } else {
            folderURLs = restoredFolders
        }

        folders = folderURLs.map { Folder(url: $0) }
        sidebarFolderPaths = folderURLs.map {
            $0.standardizedFileURL.path
        }
        terminalSessions = []
        terminalTabs = []
        activeTabID = nil

        if let initialFolderURL = requestedInitialFolderURL {
            let initialSession = TerminalSession(
                workingDirectoryURL: initialFolderURL,
                settings: settings
            )
            terminalSessions = [initialSession]
            terminalTabs = [TerminalTabState(
                id: initialSession.id,
                ownerFolderURL: initialFolderURL,
                root: .pane(initialSession.id),
                focusedTerminalID: initialSession.id
            )]
            activeTabID = initialSession.id
            lastActiveTabIDByFolderPath[initialFolderURL.path] = initialSession.id
            bindCloseHandler(to: initialSession)
        } else {
            let initialSession = TerminalSession(
                workingDirectoryURL: FileManager.default
                    .homeDirectoryForCurrentUser,
                settings: settings
            )
            terminalSessions = [initialSession]
            terminalTabs = [TerminalTabState(
                id: initialSession.id,
                ownerFolderURL: nil,
                root: .pane(initialSession.id),
                focusedTerminalID: initialSession.id
            )]
            activeTabID = initialSession.id
            lastActiveStandaloneTabID = initialSession.id
            bindCloseHandler(to: initialSession)
        }
        persistFolders()
    }

    var folderURLs: [URL] {
        folders.map(\.url)
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
        sidebarOrderedFolders.filter(folderHasTabs)
    }

    var foldersWithoutTabs: [Folder] {
        sidebarOrderedFolders.filter { !folderHasTabs($0) }
    }

    var foldersInSidebarOrder: [Folder] {
        foldersWithTabs + foldersWithoutTabs
    }

    var tabGroupCount: Int {
        folders.count + 1
    }

    private var sidebarOrderedFolders: [Folder] {
        let orderByPath = Dictionary(
            uniqueKeysWithValues: sidebarFolderPaths.enumerated().map {
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
        return terminalTabs.first { $0.id == activeTabID }
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
        return terminalSessions.first { $0.id == activeTerminalID }
    }

    var canRestoreClosedTerminal: Bool {
        !recentlyClosedTerminalLocations.isEmpty
    }

    func chooseFolder() {
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
        guard terminalView.copySelectedTextToPasteboard() else {
            memoSaveNotice = MemoSaveNotice(
                message: "No text selected.",
                systemImage: "exclamationmark.circle"
            )
            return false
        }
        defer { pasteboardSnapshot.restore(to: pasteboard) }
        guard let selection = pasteboard.string(forType: .string),
              !selection.isEmpty else {
            memoSaveNotice = MemoSaveNotice(
                message: "No text selected.",
                systemImage: "exclamationmark.circle"
            )
            return false
        }

        do {
            try FolderMemoFile.append(
                selection,
                in: session.workingDirectoryURL
            )
            memoSaveNotice = MemoSaveNotice(
                message: "Added to .memo",
                systemImage: "checkmark"
            )
            return true
        } catch {
            alertRequest = AlertRequest(
                title: "Unable to Update .memo",
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
        guard let folderURL = Self.validFolderURL(url) else {
            return .invalid(url.standardizedFileURL)
        }
        if folderURLs.contains(where: {
            $0.standardizedFileURL.path == folderURL.path
        }) {
            return .duplicate(folderURL)
        }
        folders.append(Folder(url: folderURL))
        sidebarFolderPaths.append(folderURL.path)
        persistFolders()

        if activate {
            activateFolder(folderURL)
        }
        return .added(folderURL)
    }

    func folderURL(containing url: URL) -> URL? {
        folderURLs
            .filter { Self.isInside(url, folder: $0) }
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
            agentAttentionCancellables.removeValue(forKey: session.id)
            agentAttentionFocusCancellables.removeValue(forKey: session.id)
            stopTrackingTerminalTitle(for: session.id)
            clearAgentAttention(for: session.id)
        }
        terminalSessions.removeAll { removedSessionIDs.contains($0.id) }
        terminalTabs.removeAll {
            $0.ownerFolderURL?.standardizedFileURL.path == folder.path
        }
        recentlyClosedTerminalLocations.removeAll {
            $0.ownerFolderURL?.standardizedFileURL.path == folder.path
        }
        folders.remove(at: folderIndex)
        sidebarFolderPaths.removeAll { $0 == folder.path }
        lastActiveTabIDByFolderPath.removeValue(forKey: folder.path)

        if activeTabID.map(removedTabIDs.contains) == true {
            activeTabID = terminalTabs.last?.id
        }

        persistFolders()
    }

    func setFolderOrder(_ orderedFolders: [Folder]) {
        guard orderedFolders.count == folders.count,
              Set(orderedFolders.map(\.id)) == Set(folders.map(\.id)) else {
            return
        }
        folders = orderedFolders
        sidebarFolderPaths = orderedFolders.map {
            $0.url.standardizedFileURL.path
        }
        persistFolders()
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
            rememberedID in terminalTabs.first(where: {
                $0.id == rememberedID
                    && $0.ownerFolderURL?.standardizedFileURL.path == folderPath
            })
        }
        if let existing = rememberedTab ?? terminalTabs.last(where: {
            $0.ownerFolderURL?.standardizedFileURL.path == folderPath
        }) {
            activeTabID = existing.id
            lastActiveTabIDByFolderPath[folderPath] = existing.id
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

        let isOpeningFirstTab = !terminalTabs.contains {
            $0.ownerFolderURL?.standardizedFileURL.path == folderURL.path
        }
        let session = TerminalSession(
            workingDirectoryURL: folderURL,
            settings: settings
        )
        bindCloseHandler(to: session)
        terminalSessions.append(session)
        terminalTabs.append(TerminalTabState(
            id: session.id,
            ownerFolderURL: folderURL,
            root: .pane(session.id),
            focusedTerminalID: session.id
        ))
        if isOpeningFirstTab {
            moveFolderToEndOfCurrentGroup(folderURL)
        }
        activeTabID = session.id
        lastActiveTabIDByFolderPath[folderURL.path] = session.id
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
        guard let workingDirectoryURL = Self.validFolderURL(
            workingDirectoryURL
        ) else { return }
        let session = TerminalSession(
            workingDirectoryURL: workingDirectoryURL,
            settings: settings
        )
        bindCloseHandler(to: session)
        terminalSessions.append(session)
        terminalTabs.append(TerminalTabState(
            id: session.id,
            ownerFolderURL: nil,
            root: .pane(session.id),
            focusedTerminalID: session.id
        ))
        activeTabID = session.id
        lastActiveStandaloneTabID = session.id
    }

    private func moveFolderToEndOfCurrentGroup(_ folderURL: URL) {
        var orderedFolders = sidebarOrderedFolders
        guard let sourceIndex = orderedFolders.firstIndex(where: {
            $0.url.standardizedFileURL.path == folderURL.path
        }) else { return }

        let hasTabs = folderHasTabs(orderedFolders[sourceIndex])
        let folder = orderedFolders.remove(at: sourceIndex)
        let insertionIndex: Int
        if hasTabs {
            insertionIndex = orderedFolders.lastIndex(where: folderHasTabs)
                .map { $0 + 1 } ?? 0
        } else {
            insertionIndex = orderedFolders.endIndex
        }
        orderedFolders.insert(folder, at: insertionIndex)
        sidebarFolderPaths = orderedFolders.map {
            $0.url.standardizedFileURL.path
        }
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
        guard terminalSessions.contains(where: { $0.id == id }),
              let tabIndex = terminalTabs.firstIndex(where: {
                  $0.root.contains(id)
              }) else { return }
        terminalTabs[tabIndex].focusedTerminalID = id
        let tab = terminalTabs[tabIndex]
        activeTabID = tab.id
        clearAgentAttention(for: id)
        if let folderURL = tab.ownerFolderURL {
            lastActiveTabIDByFolderPath[folderURL.standardizedFileURL.path] =
                tab.id
        } else {
            lastActiveStandaloneTabID = tab.id
        }
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
        agentAttentionHandler?(
            terminalID,
            session.workingDirectoryURL,
            notification
        )
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
    func selectTab(at index: Int) -> Bool {
        let tabs = activeScopeTabs
        guard tabs.indices.contains(index) else { return false }
        selectTab(tabs[index].id)
        return true
    }

    @discardableResult
    func selectLastTab() -> Bool {
        guard let tab = activeScopeTabs.last else { return false }
        selectTab(tab.id)
        return true
    }

    @discardableResult
    func selectAdjacentTab(offset: Int) -> Bool {
        let tabs = activeScopeTabs
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
        let orderedFolders = foldersInSidebarOrder
        let groupCount = orderedFolders.count + 1
        guard groupCount > 1 else { return false }

        let activeIndex: Int
        if let activeFolderURL,
           let activeFolder = folderURL(containing: activeFolderURL),
           let folderIndex = orderedFolders.firstIndex(where: {
               $0.url.standardizedFileURL.path == activeFolder.path
           }) {
            activeIndex = folderIndex + 1
        } else {
            activeIndex = 0
        }

        let next = (activeIndex + offset + groupCount) % groupCount
        if next == 0 {
            activateStandaloneTabGroup()
        } else {
            activateFolder(orderedFolders[next - 1].url)
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
        guard let session = terminalSessions.first(where: {
            $0.id == id
        }) else { return }
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
        guard let tab = terminalTabs.first(where: { $0.id == id }) else { return }
        let runningPrograms = tab.terminalIDs.compactMap { terminalID in
            terminalSessions.first(where: { $0.id == terminalID }).flatMap {
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
                moveFolderToEndOfCurrentGroup(folderURL)
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

        // AppKit may finish dismantling the old split containers after SwiftUI
        // has rendered the collapsed tree. Refresh on the next run loop so the
        // surviving session-owned terminal view is attached to its final pane.
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func restoreLastClosedTerminal() {
        while let location = recentlyClosedTerminalLocations.popLast() {
            guard Self.validFolderURL(location.workingDirectoryURL) != nil else {
                continue
            }
            if let folderURL = location.ownerFolderURL {
                guard self.folderURL(containing: folderURL) != nil else {
                    continue
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
        guard let tab = terminalTabs.first(where: { $0.id == id }),
              let session = terminalSessions.first(where: {
                  $0.id == tab.focusedTerminalID
              }) else { return }
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
        guard let tabIndex = terminalTabs.firstIndex(where: {
            $0.id == request.tabID
        }) else {
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
        guard agentAttentionByTerminalID.removeValue(
            forKey: terminalID
        ) != nil else { return }
        agentAttentionClearedHandler?(terminalID)
    }

    private func persistFolders() {
        defaults.set(folderURLs.map(\.path), forKey: Keys.folderPaths)
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

    private static func validFolderURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isInside(_ url: URL, folder: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        let descendantPrefix = folderPath == "/" ? "/" : folderPath + "/"
        return path == folderPath || path.hasPrefix(descendantPrefix)
    }

    private static func restoredFolders(
        from defaults: UserDefaults
    ) -> [URL] {
        guard let paths = defaults.stringArray(forKey: Keys.folderPaths) else {
            return []
        }
        var folders: [URL] = []
        for path in paths {
            guard let folderURL = validFolderURL(URL(fileURLWithPath: path)),
                  !folders.contains(where: {
                      $0.standardizedFileURL.path == folderURL.path
                  }) else {
                continue
            }
            folders.append(folderURL)
        }
        return folders
    }

    private enum Keys {
        static let folderPaths = "folders.paths.v1"
    }
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    struct ProcessSnapshot {
        let processID: pid_t
        let parentProcessID: pid_t
        let processGroupID: pid_t
        let ttyDevice: UInt64?
        let terminalForegroundProcessGroupID: pid_t
        let name: String

        init(
            processID: pid_t,
            parentProcessID: pid_t,
            processGroupID: pid_t,
            ttyDevice: UInt64?,
            terminalForegroundProcessGroupID: pid_t? = nil,
            name: String
        ) {
            self.processID = processID
            self.parentProcessID = parentProcessID
            self.processGroupID = processGroupID
            self.ttyDevice = ttyDevice
            self.terminalForegroundProcessGroupID =
                terminalForegroundProcessGroupID ?? processGroupID
            self.name = name
        }
    }

    private struct ProcessIdentitySnapshot {
        let processID: pid_t
        let parentProcessID: pid_t
        let processGroupID: pid_t
        let ttyDevice: UInt64?
        let terminalForegroundProcessGroupID: pid_t
    }

    let id = UUID()
    let workingDirectoryURL: URL
    let terminal: TerminalViewState
    let defaultShellName: String
    var terminalView: TerminalView?
    @Published var isSearchPresented = false
    @Published var searchQuery = ""
    @Published private(set) var searchFocusRequest = 0
    private var pendingInput: String?
    private static var cachedProcessSnapshots:
        (capturedAt: TimeInterval, snapshots: [ProcessIdentitySnapshot])?
    private static let processSnapshotCacheLifetime: TimeInterval = 0.2

    init(
        workingDirectoryURL: URL,
        settings: AppSettings? = nil,
        defaultShellPath: String? = nil,
        surfaceContext: TerminalSurfaceContext = .window,
        initialInput: String? = nil
    ) {
        let settings = settings ?? AppSettings()
        self.workingDirectoryURL = workingDirectoryURL.standardizedFileURL
        let shellPath = defaultShellPath ?? Self.loginShellPath
        defaultShellName = Self.processName(
            from: shellPath
        ) ?? "shell"

        terminal = TerminalViewState(
            configSource: settings.ghosttyConfigSource
        )
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectoryURL.path,
            context: surfaceContext
        )
        pendingInput = initialInput
    }

    private var currentForegroundProcess: ProcessSnapshot? {
        guard let terminalView,
              let processGroupID = terminalView.foregroundPid,
              processGroupID > 0,
              let ttyName = terminalView.ttyName,
              let ttyDevice = Self.ttyDevice(for: ttyName)
        else { return nil }

        return Self.resolveForegroundProcess(
            processGroupID: processGroupID,
            ttyDevice: ttyDevice,
            processes: Self.processSnapshots(
                processGroupID: processGroupID,
                ttyDevice: ttyDevice
            )
        )
    }

    var currentProcessName: String? {
        currentForegroundProcess?.name
    }

    var isRunningForegroundProgram: Bool {
        runningForegroundProcessName != nil
    }

    var runningForegroundProcessName: String? {
        guard let process = currentForegroundProcess,
              process.name != defaultShellName
        else { return nil }
        return process.name
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
        let processName = foregroundProcessName.flatMap(Self.processName(from:))
        if processName == defaultShellName { return defaultShellName }

        let title = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !Self.isPathTitle(title) {
            return title
        }
        return processName ?? defaultShellName
    }

    private static func isPathTitle(_ title: String) -> Bool {
        title == "~"
            || title.hasPrefix("~/")
            || title.hasPrefix("/")
            || title.hasPrefix("file://")
    }

    static func resolveForegroundProcess(
        processGroupID: pid_t,
        ttyDevice: UInt64,
        processes: [ProcessSnapshot]
    ) -> ProcessSnapshot? {
        guard processGroupID > 0 else { return nil }
        let candidates = processes.filter {
            $0.processGroupID == processGroupID
                && $0.ttyDevice == ttyDevice
        }
        guard !candidates.isEmpty else { return nil }

        let processByID = Dictionary(
            uniqueKeysWithValues: processes.map { ($0.processID, $0) }
        )
        let selected: ProcessSnapshot
        if let leader = candidates.first(where: {
            $0.processID == processGroupID
        }), leader.name != "login", !leader.name.isEmpty {
            selected = leader
        } else {
            let usableCandidates = candidates.filter {
                $0.name != "login" && !$0.name.isEmpty
            }
            guard let candidate = usableCandidates.max(by: { lhs, rhs in
                let lhsDepth = processDepth(lhs, processByID: processByID)
                let rhsDepth = processDepth(rhs, processByID: processByID)
                if lhsDepth == rhsDepth {
                    return lhs.processID < rhs.processID
                }
                return lhsDepth < rhsDepth
            }) else { return nil }
            selected = candidate
        }

        let nestedForegroundProcesses = processes.filter { process in
            guard process.ttyDevice != nil,
                  process.ttyDevice != ttyDevice,
                  process.processGroupID
                    == process.terminalForegroundProcessGroupID,
                  !process.name.isEmpty
            else { return false }
            return isDescendant(
                process,
                of: selected.processID,
                processByID: processByID
            )
        }

        return nestedForegroundProcesses.max(by: { lhs, rhs in
            let lhsDepth = foregroundGroupDepth(
                lhs,
                processByID: processByID
            )
            let rhsDepth = foregroundGroupDepth(
                rhs,
                processByID: processByID
            )
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }

            let sameGroup = lhs.ttyDevice == rhs.ttyDevice
                && lhs.processGroupID == rhs.processGroupID
            if sameGroup {
                let lhsIsLeader = lhs.processID == lhs.processGroupID
                    && lhs.name != "login"
                let rhsIsLeader = rhs.processID == rhs.processGroupID
                    && rhs.name != "login"
                if lhsIsLeader != rhsIsLeader { return !lhsIsLeader }
            }
            return lhs.processID < rhs.processID
        }) ?? selected
    }

    private static func foregroundGroupDepth(
        _ process: ProcessSnapshot,
        processByID: [pid_t: ProcessSnapshot]
    ) -> Int {
        let groupLeader = processByID[process.processGroupID] ?? process
        return processDepth(groupLeader, processByID: processByID)
    }

    private static func isDescendant(
        _ process: ProcessSnapshot,
        of ancestorProcessID: pid_t,
        processByID: [pid_t: ProcessSnapshot]
    ) -> Bool {
        var parentProcessID = process.parentProcessID
        var visited = Set([process.processID])
        while parentProcessID > 0, !visited.contains(parentProcessID) {
            if parentProcessID == ancestorProcessID { return true }
            visited.insert(parentProcessID)
            guard let parent = processByID[parentProcessID] else {
                return false
            }
            parentProcessID = parent.parentProcessID
        }
        return false
    }

    private static func processDepth(
        _ process: ProcessSnapshot,
        processByID: [pid_t: ProcessSnapshot]
    ) -> Int {
        var depth = 0
        var parentProcessID = process.parentProcessID
        var visited = Set([process.processID])
        while parentProcessID > 0,
              !visited.contains(parentProcessID),
              let parent = processByID[parentProcessID] {
            visited.insert(parentProcessID)
            depth += 1
            parentProcessID = parent.parentProcessID
        }
        return depth
    }

    private static func ttyDevice(for ttyName: String) -> UInt64? {
        var fileStatus = stat()
        guard Darwin.lstat(ttyName, &fileStatus) == 0 else { return nil }
        return UInt64(fileStatus.st_rdev)
    }

    private static func processSnapshots(
        processGroupID: pid_t,
        ttyDevice: UInt64
    ) -> [ProcessSnapshot] {
        let identities = processIdentitySnapshots()
        let rootProcessIDs = identities.compactMap { process in
            process.processGroupID == processGroupID
                && process.ttyDevice == ttyDevice
                ? process.processID
                : nil
        }
        guard !rootProcessIDs.isEmpty else { return [] }

        let childrenByParent = Dictionary(grouping: identities) {
            $0.parentProcessID
        }
        var relevantProcessIDs = Set(rootProcessIDs)
        var pendingProcessIDs = rootProcessIDs
        while let parentProcessID = pendingProcessIDs.popLast() {
            for child in childrenByParent[parentProcessID] ?? []
            where relevantProcessIDs.insert(child.processID).inserted {
                pendingProcessIDs.append(child.processID)
            }
        }

        return identities.compactMap { process in
            guard relevantProcessIDs.contains(process.processID) else {
                return nil
            }
            return ProcessSnapshot(
                processID: process.processID,
                parentProcessID: process.parentProcessID,
                processGroupID: process.processGroupID,
                ttyDevice: process.ttyDevice,
                terminalForegroundProcessGroupID:
                    process.terminalForegroundProcessGroupID,
                name: processName(for: UInt64(process.processID)) ?? ""
            )
        }
    }

    private static func processIdentitySnapshots() -> [ProcessIdentitySnapshot] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = cachedProcessSnapshots,
           now - cache.capturedAt < processSnapshotCacheLifetime {
            return cache.snapshots
        }

        var query = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var byteCount = 0
        guard sysctl(&query, u_int(query.count), nil, &byteCount, nil, 0) == 0,
              byteCount >= MemoryLayout<kinfo_proc>.stride
        else { return [] }

        var entries = [kinfo_proc](
            repeating: kinfo_proc(),
            count: byteCount / MemoryLayout<kinfo_proc>.stride
        )
        let result = entries.withUnsafeMutableBytes { buffer in
            sysctl(
                &query,
                u_int(query.count),
                buffer.baseAddress,
                &byteCount,
                nil,
                0
            )
        }
        guard result == 0 else { return [] }

        let entryCount = min(
            entries.count,
            byteCount / MemoryLayout<kinfo_proc>.stride
        )
        let snapshots: [ProcessIdentitySnapshot] = entries.prefix(entryCount).compactMap {
            entry -> ProcessIdentitySnapshot? in
            let processID = entry.kp_proc.p_pid
            let ttyDevice = entry.kp_eproc.e_tdev
            guard processID > 0 else { return nil }
            return ProcessIdentitySnapshot(
                processID: processID,
                parentProcessID: entry.kp_eproc.e_ppid,
                processGroupID: entry.kp_eproc.e_pgid,
                ttyDevice: ttyDevice >= 0 ? UInt64(ttyDevice) : nil,
                terminalForegroundProcessGroupID: entry.kp_eproc.e_tpgid
            )
        }
        cachedProcessSnapshots = (now, snapshots)
        return snapshots
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
