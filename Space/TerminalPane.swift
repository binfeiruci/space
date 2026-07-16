import AppKit
import GhosttyTerminal
import SwiftUI

struct TerminalWorkspacePane: View {
    @EnvironmentObject private var workspace: WorkspaceModel

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
                    Text("此目录没有打开的终端")
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
    @EnvironmentObject private var workspace: WorkspaceModel
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
                .frame(minWidth: 160, minHeight: 100)
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
            )
        case let .split(_, axis, _, first, second):
            switch axis {
            case .horizontal:
                return AnyView(
                    HSplitView {
                        TerminalSplitTree(node: first, isVisible: isVisible)
                        TerminalSplitTree(node: second, isVisible: isVisible)
                    }
                )
            case .vertical:
                return AnyView(
                    VSplitView {
                        TerminalSplitTree(node: first, isVisible: isVisible)
                        TerminalSplitTree(node: second, isVisible: isVisible)
                    }
                )
            }
        }
    }
}

struct TerminalTabStrip: View {
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.activeDirectoryTabs) { tab in
                        if let session = workspace.terminalSessions.first(where: {
                            $0.id == tab.focusedTerminalID
                        }) {
                            TerminalTab(
                                tabID: tab.id,
                                paneCount: tab.terminalIDs.count,
                                session: session,
                                isActive: workspace.activeTerminalTab?.id == tab.id
                            ) {
                                workspace.selectTab(tab.id)
                            } close: {
                                workspace.requestCloseTab(tab.id)
                            }
                        }
                    }
                }
            }

            Button {
                if let directory = workspace.activeDirectory {
                    workspace.openNewTerminal(for: directory)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("在当前目录新建终端")
            .accessibilityLabel("新建终端")
        }
        .frame(height: 28)
    }
}

private struct TerminalTab: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    let tabID: UUID
    let paneCount: Int
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isOutputActive: Bool
    @State private var foregroundProcessName: String?
    @State private var isHovering = false

    init(
        tabID: UUID,
        paneCount: Int,
        session: TerminalSession,
        isActive: Bool,
        select: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.tabID = tabID
        self.paneCount = paneCount
        _session = ObservedObject(wrappedValue: session)
        self.isActive = isActive
        self.select = select
        self.close = close
        _isOutputActive = State(initialValue: false)
        _foregroundProcessName = State(initialValue: nil)
    }

    private var title: String {
        session.displayTitle(foregroundProcessName: foregroundProcessName)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 5) {
                    if isOutputActive {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.65)
                            .frame(width: 10, height: 10)
                            .help("终端正在运行 \(title)")
                            .accessibilityLabel("终端持续输出")
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if paneCount > 1 {
                        Text("×\(paneCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isActive || isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关闭终端标签")
                .accessibilityLabel("关闭终端标签 \(title)")
                .transition(.opacity)
            }
        }
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .padding(.leading, 9)
        .padding(.trailing, (isActive || isHovering) ? 4 : 9)
        .frame(maxWidth: 190, minHeight: 26, maxHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive
                    ? Color(nsColor: .selectedControlColor).opacity(0.25)
                    : Color.clear)
        )
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
            Button("重命名…") {
                workspace.promptRenameTerminal(session.id)
            }
            Button("复制终端") {
                workspace.selectTerminal(session.id)
                workspace.duplicateActiveTerminal()
            }
            Divider()
            Button("关闭标签") {
                workspace.requestCloseTab(tabID)
            }
        }
        .task {
            while !Task.isCancelled {
                foregroundProcessName = session.currentProcessName
                isOutputActive = session.isRunningForegroundProgram

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

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TerminalSearchField(
                text: $session.searchQuery,
                onSubmit: { session.navigateSearch(forward: true) },
                onCancel: { session.dismissSearch() }
            )
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

private struct TerminalSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField()
        field.placeholderString = "查找终端内容"
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: AutoFocusTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.requestFocusIfPossible()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TerminalSearchField

        init(parent: TerminalSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }

    final class AutoFocusTextField: NSTextField {
        private var didRequestFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            requestFocusIfPossible()
        }

        func requestFocusIfPossible() {
            guard !didRequestFocus, window != nil else { return }
            didRequestFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                currentEditor()?.selectedRange = NSRange(
                    location: stringValue.utf16.count,
                    length: 0
                )
            }
        }
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
