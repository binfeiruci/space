import CoreGraphics
import Foundation

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

    func settingRatio(
        _ newRatio: CGFloat,
        for splitID: UUID
    ) -> TerminalSplitNode {
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

    func paneFrames(
        in bounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> [UUID: CGRect] {
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

struct ClosedTerminalLocation {
    let workingDirectoryURL: URL
    let ownerFolderURL: URL?
}

@MainActor
struct TerminalWorkspaceIndex {
    private var sessionByID: [UUID: TerminalSession] = [:]
    private var sessionIndexByID: [UUID: Int] = [:]
    private var tabIndexByID: [UUID: Int] = [:]
    private var tabIDByTerminalID: [UUID: UUID] = [:]

    mutating func indexSessions(_ sessions: [TerminalSession]) {
        sessionByID = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, $0) }
        )
        sessionIndexByID = Dictionary(
            uniqueKeysWithValues: sessions.indices.map {
                (sessions[$0].id, $0)
            }
        )
    }

    mutating func indexTabs(_ tabs: [TerminalTabState]) {
        tabIndexByID = Dictionary(
            uniqueKeysWithValues: tabs.indices.map { (tabs[$0].id, $0) }
        )
        tabIDByTerminalID = Dictionary(
            uniqueKeysWithValues: tabs.flatMap { tab in
                tab.terminalIDs.map { ($0, tab.id) }
            }
        )
    }

    func session(id: UUID) -> TerminalSession? {
        sessionByID[id]
    }

    func sessionIndex(id: UUID) -> Int? {
        sessionIndexByID[id]
    }

    func tabIndex(id: UUID) -> Int? {
        tabIndexByID[id]
    }

    func tabIndex(containing terminalID: UUID) -> Int? {
        tabIDByTerminalID[terminalID].flatMap { tabIndexByID[$0] }
    }
}
