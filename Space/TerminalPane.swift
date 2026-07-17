import AppKit
import GhosttyTerminal
import SwiftUI

struct TerminalWorkspacePane: View {
    @EnvironmentObject private var workspace: AppModel

    var body: some View {
        ZStack {
            ForEach(workspace.terminalTabs) { tab in
                TerminalSplitTree(
                    node: tab.root,
                    isVisible: workspace.activeTerminalTab?.id == tab.id
                )
                .opacity(workspace.activeTerminalTab?.id == tab.id ? 1 : 0)
                .allowsHitTesting(workspace.activeTerminalTab?.id == tab.id)
                .accessibilityHidden(workspace.activeTerminalTab?.id != tab.id)
            }

            if workspace.activeDirectoryTabs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("此文件夹没有打开的终端")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("新建终端") {
                        if let directory = workspace.activeDirectory {
                            workspace.openNewTerminal(for: directory)
                        }
                    }
                }
            }
        }
    }
}

private struct TerminalSplitTree: View {
    @EnvironmentObject private var workspace: AppModel
    let node: TerminalSplitNode
    let isVisible: Bool

    var body: some View {
        renderedNode
    }

    private var renderedNode: AnyView {
        switch node {
        case let .pane(id):
            guard let session = workspace.terminalSessions.first(where: {
                $0.id == id
            }) else {
                return AnyView(EmptyView())
            }
            let isFocused = workspace.activeTerminalID == id
            return AnyView(
                GhosttyTerminalPane(
                    session: session,
                    isVisible: isVisible,
                    isFocused: isFocused
                ) { [weak workspace] in
                    workspace?.selectTerminal(id)
                }
                .id(session.id)
                .frame(
                    minWidth: 160,
                    maxWidth: .infinity,
                    minHeight: 100,
                    maxHeight: .infinity
                )
                .overlay {
                    Rectangle()
                        .stroke(
                            isVisible && isFocused
                                ? Color.accentColor.opacity(0.7)
                                : Color.clear,
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("terminal-split-pane")
            )
        case let .split(id, axis, ratio, first, second):
            return AnyView(
                TerminalSplitContainer(
                    splitID: id,
                    axis: axis,
                    ratio: ratio,
                    first: first,
                    second: second,
                    isVisible: isVisible
                )
            )
        }
    }
}

private struct TerminalSplitContainer: View {
    @EnvironmentObject private var workspace: AppModel
    let splitID: UUID
    let axis: TerminalSplitAxis
    let ratio: CGFloat
    let first: TerminalSplitNode
    let second: TerminalSplitNode
    let isVisible: Bool
    @State private var displayedRatio: CGFloat

    private let dividerThickness: CGFloat = 5

    init(
        splitID: UUID,
        axis: TerminalSplitAxis,
        ratio: CGFloat,
        first: TerminalSplitNode,
        second: TerminalSplitNode,
        isVisible: Bool
    ) {
        self.splitID = splitID
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
        self.isVisible = isVisible
        _displayedRatio = State(initialValue: ratio)
    }

    var body: some View {
        GeometryReader { geometry in
            let containerLength = primaryLength(in: geometry.size)
            let availableLength = max(
                containerLength - dividerThickness,
                0
            )
            let effectiveRatio = clampedRatio(
                displayedRatio,
                availableLength: availableLength
            )
            let firstLength = availableLength * effectiveRatio
            let secondLength = availableLength - firstLength

            Group {
                switch axis {
                case .horizontal:
                    HStack(spacing: 0) {
                        splitChild(first)
                            .frame(width: firstLength)
                        divider(containerLength: containerLength)
                            .frame(width: dividerThickness)
                        splitChild(second)
                            .frame(width: secondLength)
                    }
                case .vertical:
                    VStack(spacing: 0) {
                        splitChild(first)
                            .frame(height: firstLength)
                        divider(containerLength: containerLength)
                            .frame(height: dividerThickness)
                        splitChild(second)
                            .frame(height: secondLength)
                    }
                }
            }
            .coordinateSpace(name: splitID)
        }
        .onChange(of: ratio) { _, newRatio in
            displayedRatio = newRatio
        }
    }

    private func splitChild(_ node: TerminalSplitNode) -> some View {
        TerminalSplitTree(node: node, isVisible: isVisible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    private func divider(containerLength: CGFloat) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(
                    width: axis == .horizontal ? 1 : nil,
                    height: axis == .vertical ? 1 : nil
                )
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(splitID))
                .onChanged { value in
                    let length = primaryLength(in: value.location)
                    displayedRatio = ratioForDividerLocation(
                        length,
                        containerLength: containerLength
                    )
                }
                .onEnded { _ in
                    workspace.updateSplitRatio(displayedRatio, for: splitID)
                }
        )
        .accessibilityElement()
        .accessibilityLabel(axis == .horizontal ? "调整左右分屏" : "调整上下分屏")
        .accessibilityIdentifier("terminal-split-divider")
    }

    private func primaryLength(in size: CGSize) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    private func primaryLength(in point: CGPoint) -> CGFloat {
        axis == .horizontal ? point.x : point.y
    }

    private func ratioForDividerLocation(
        _ location: CGFloat,
        containerLength: CGFloat
    ) -> CGFloat {
        let availableLength = max(containerLength - dividerThickness, 1)
        return clampedRatio(
            (location - dividerThickness / 2) / availableLength,
            availableLength: availableLength
        )
    }

    private func clampedRatio(
        _ proposedRatio: CGFloat,
        availableLength: CGFloat
    ) -> CGFloat {
        guard availableLength > 0 else { return 0.5 }
        let minimumLength: CGFloat = axis == .horizontal ? 160 : 100
        let minimumRatio = min(minimumLength / availableLength, 0.5)
        return min(max(proposedRatio, minimumRatio), 1 - minimumRatio)
    }
}

struct TerminalTitleBarContent: View {
    @EnvironmentObject private var workspace: AppModel
    let maximumTabStripWidth: CGFloat

    @ViewBuilder
    var body: some View {
        if workspace.activeDirectoryTabs.count == 1,
           let session = workspace.activeTerminalSession {
            TerminalTitleBarTitle(session: session)
        } else {
            TerminalTabStrip(maximumWidth: maximumTabStripWidth)
        }
    }
}

private struct TerminalTitleBarTitle: View {
    @EnvironmentObject private var workspace: AppModel
    @ObservedObject var session: TerminalSession
    @ObservedObject private var terminal: TerminalViewState
    @State private var foregroundProcessName: String?

    init(session: TerminalSession) {
        _session = ObservedObject(wrappedValue: session)
        _terminal = ObservedObject(wrappedValue: session.terminal)
        _foregroundProcessName = State(initialValue: session.currentProcessName)
    }

    private var title: String {
        session.displayTitle(
            terminalTitle: terminal.title,
            foregroundProcessName: foregroundProcessName
        )
    }

    var body: some View {
        ZStack {
            Color.clear
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 240)
        .frame(height: 28)
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityIdentifier("terminal-title")
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                workspace.promptRenameTerminal(session.id)
            }
        )
        .task {
            while !Task.isCancelled {
                foregroundProcessName = session.currentProcessName
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

struct TerminalTabStrip: View {
    @EnvironmentObject private var workspace: AppModel
    let maximumWidth: CGFloat
    @State private var contentWidth: CGFloat = 1

    private let newTabButtonWidth: CGFloat = 28
    private let spacing: CGFloat = 4

    private var width: CGFloat {
        min(contentWidth + spacing + newTabButtonWidth, maximumWidth)
    }

    private var scrollWidth: CGFloat {
        max(1, width - spacing - newTabButtonWidth)
    }

    var body: some View {
        HStack(spacing: spacing) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    tabRow
                        .fixedSize(horizontal: true, vertical: false)
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            geometry.size.width
                        } action: { measuredWidth in
                            guard measuredWidth > 0 else { return }
                            contentWidth = measuredWidth
                        }
                }
                .frame(width: scrollWidth)
                .onAppear {
                    scrollToActiveTab(using: proxy, animated: false)
                }
                .onChange(of: workspace.activeTerminalTab?.id) { _, _ in
                    scrollToActiveTab(using: proxy, animated: true)
                }
                .onChange(of: maximumWidth) { _, _ in
                    scrollToActiveTab(using: proxy, animated: false)
                }
            }

            Button {
                guard let directory = workspace.activeDirectory else { return }
                workspace.openNewTerminal(for: directory)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: newTabButtonWidth, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Terminal (⌘T)")
            .accessibilityLabel("New Terminal")
            .accessibilityIdentifier("new-terminal-tab-button")
        }
        .frame(width: width)
        .frame(height: 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-tabs-container")
    }

    private var tabRow: some View {
        let tabs = workspace.activeDirectoryTabs

        return HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if let session = workspace.terminalSessions.first(where: {
                    $0.id == tab.focusedTerminalID
                }) {
                    TerminalTab(
                        tabID: tab.id,
                        session: session,
                        isActive: workspace.activeTerminalTab?.id == tab.id,
                        shortcutLabel: shortcutLabel(
                            at: index,
                            tabCount: tabs.count
                        )
                    ) {
                        workspace.selectTab(tab.id)
                    } close: {
                        workspace.requestCloseTab(tab.id)
                    }
                    .id(tab.id)
                }
            }
        }
    }

    private func shortcutLabel(at index: Int, tabCount: Int) -> String? {
        if index < 8 { return "⌘\(index + 1)" }
        if index == tabCount - 1 { return "⌘9" }
        return nil
    }

    private func scrollToActiveTab(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let tabID = workspace.activeTerminalTab?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(tabID, anchor: .center)
            }
        } else {
            proxy.scrollTo(tabID, anchor: .center)
        }
    }
}

private struct TerminalTab: View {
    @EnvironmentObject private var workspace: AppModel
    let tabID: UUID
    @ObservedObject var session: TerminalSession
    @ObservedObject private var terminal: TerminalViewState
    let isActive: Bool
    let shortcutLabel: String?
    let select: () -> Void
    let close: () -> Void
    @State private var foregroundProcessName: String?
    @State private var isHovering = false

    init(
        tabID: UUID,
        session: TerminalSession,
        isActive: Bool,
        shortcutLabel: String?,
        select: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.tabID = tabID
        _session = ObservedObject(wrappedValue: session)
        _terminal = ObservedObject(wrappedValue: session.terminal)
        self.isActive = isActive
        self.shortcutLabel = shortcutLabel
        self.select = select
        self.close = close
        _foregroundProcessName = State(initialValue: session.currentProcessName)
    }

    private var title: String {
        session.displayTitle(
            terminalTitle: terminal.title,
            foregroundProcessName: foregroundProcessName
        )
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(
                            size: 12,
                            weight: isActive ? .semibold : .regular
                        ))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if workspace.tabNeedsAgentAttention(tabID) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Agent needs attention")
                            .accessibilityIdentifier(
                                "agent-attention-tab:\(tabID.uuidString)"
                            )
                    }

                    if let shortcutLabel {
                        Text(shortcutLabel)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Color.clear
                        .frame(width: 16, height: 16)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(maxWidth: 180, minHeight: 28, maxHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭终端标签")
            .accessibilityLabel("关闭终端标签 \(title)")
            .padding(.trailing, 5)
            .opacity(isActive || isHovering ? 1 : 0)
            .allowsHitTesting(isActive || isHovering)
        }
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 6)
                .opacity(isActive ? 1 : 0)
        }
        .help(title)
        .accessibilityLabel(title)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .draggable(tabID.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first,
                  let sourceID = UUID(uuidString: value) else { return false }
            workspace.moveTab(sourceID, to: tabID)
            return true
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                workspace.promptRenameTerminal(session.id)
            }
        )
        .contextMenu {
            Button("Rename Tab…") {
                workspace.promptRenameTerminal(session.id)
            }
            Button("Duplicate Tab") {
                workspace.selectTerminal(session.id)
                workspace.duplicateActiveTerminal()
            }
            Divider()
            Button("Close Tab") {
                workspace.requestCloseTab(tabID)
            }
        }
        .task {
            while !Task.isCancelled {
                foregroundProcessName = session.currentProcessName
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

}

private struct GhosttyTerminalPane: View {
    @ObservedObject var session: TerminalSession
    let isVisible: Bool
    let isFocused: Bool
    let activate: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SpaceTerminalViewRepresentable(
                session: session,
                isVisible: isVisible,
                requestsFocus: isFocused && !session.isSearchPresented,
                onActivate: activate
            )

            if session.isSearchPresented {
                TerminalSearchBar(session: session)
                    .padding(8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
            .background(Color(nsColor: .textBackgroundColor))
            .animation(
                .easeOut(duration: 0.12),
                value: session.isSearchPresented
            )
    }
}

private struct TerminalSearchBar: View {
    @ObservedObject var session: TerminalSession
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("查找终端内容", text: $session.searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityIdentifier("terminal-search-field")
                .onSubmit {
                    session.navigateSearch(forward: true)
                }
                .frame(width: 210)
                .onChange(of: session.searchQuery) { _, query in
                    session.updateSearch(query)
                }

            Divider()
                .frame(height: 16)

            searchButton(
                systemName: "chevron.up",
                help: "上一个匹配项（⇧⌘G）"
            ) {
                session.navigateSearch(forward: false)
            }

            searchButton(
                systemName: "chevron.down",
                help: "下一个匹配项（⌘G）"
            ) {
                session.navigateSearch(forward: true)
            }

            searchButton(systemName: "xmark", help: "关闭查找（Esc）") {
                session.dismissSearch()
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        .onAppear {
            session.updateSearch(session.searchQuery)
        }
        .task(id: session.searchFocusRequest) {
            // Let SwiftUI install the TextField in its AppKit hierarchy before
            // asking it to become first responder. This also handles repeated
            // Command-F presses while the search bar is already visible.
            await Task.yield()
            guard session.isSearchPresented else { return }
            isSearchFocused = true
        }
        .onExitCommand {
            session.dismissSearch()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("终端内容查找")
    }

    private func searchButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct SpaceTerminalViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let isVisible: Bool
    let requestsFocus: Bool
    let onActivate: () -> Void

    func makeNSView(context: Context) -> SpaceTerminalContainerView {
        let container = SpaceTerminalContainerView(frame: .zero)
        configure(container)
        return container
    }

    func updateNSView(
        _ container: SpaceTerminalContainerView,
        context: Context
    ) {
        configure(container)
    }

    private func configure(_ container: SpaceTerminalContainerView) {
        let view: SpaceTerminalView
        if let existing = session.terminalView as? SpaceTerminalView {
            view = existing
        } else {
            view = SpaceTerminalView(frame: .zero)
            session.terminalView = view
        }
        view.session = session
        view.delegate = session.terminal
        view.controller = session.terminal.controller
        view.configuration = session.terminal.configuration
        container.attach(view)
        view.setSurfaceVisible(isVisible)
        view.onActivate = onActivate
        view.requestsFocus = requestsFocus
        session.sendPendingInputIfReady()
    }
}

@MainActor
private final class SpaceTerminalContainerView: NSView {
    weak var terminalView: SpaceTerminalView?

    func attach(_ view: SpaceTerminalView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        terminalView = view
    }

}

@MainActor
private final class SpaceTerminalView: TerminalView {
    weak var session: TerminalSession?
    var onActivate: (() -> Void)?
    var requestsFocus = false {
        didSet {
            guard requestsFocus, requestsFocus != oldValue else { return }
            applyFocusRequest()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        session?.sendPendingInputIfReady()
        if requestsFocus {
            applyFocusRequest()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
    }

    private func applyFocusRequest() {
        guard let window else { return }
        window.initialFirstResponder = self
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }
}
