import AppKit
import GhosttyTerminal
import SwiftUI

struct TerminalArea: View {
    @Environment(AppModel.self) private var model: AppModel

    var body: some View {
        let _ = model.terminalLayoutRevision
        ZStack {
            ForEach(model.terminalTabs) { tab in
                TerminalSplitTree(
                    node: tab.root,
                    isVisible: model.activeTerminalTab?.id == tab.id,
                    showsFocusBorder: tab.terminalIDs.count > 1
                )
                .opacity(model.activeTerminalTab?.id == tab.id ? 1 : 0)
                .allowsHitTesting(model.activeTerminalTab?.id == tab.id)
                .accessibilityHidden(model.activeTerminalTab?.id != tab.id)
            }
        }
    }
}

private struct TerminalSplitTree: View {
    @Environment(AppModel.self) private var model: AppModel
    let node: TerminalSplitNode
    let isVisible: Bool
    let showsFocusBorder: Bool

    @ViewBuilder
    var body: some View {
        switch node {
        case let .pane(id):
            if let session = model.terminalSession(id: id) {
                let isFocused = model.activeTerminalID == id
                GhosttyTerminalPane(
                    session: session,
                    isVisible: isVisible,
                    isFocused: isFocused
                ) { [weak model] in
                    model?.selectTerminal(id)
                }
                .id(session.id)
                .overlay {
                    Rectangle()
                        .stroke(
                            isVisible && isFocused && showsFocusBorder
                                ? Color.accentColor.opacity(0.7)
                                : Color.clear,
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("terminal-split-pane")
            }
        case let .split(id, axis, ratio, first, second):
            TerminalSplitContainer(
                splitID: id,
                axis: axis,
                ratio: ratio,
                first: first,
                second: second,
                isVisible: isVisible,
                showsFocusBorder: showsFocusBorder
            )
            .id(id)
        }
    }
}

private struct TerminalSplitContainer: View {
    @Environment(AppModel.self) private var model: AppModel
    let splitID: UUID
    let axis: TerminalSplitAxis
    let ratio: CGFloat
    let first: TerminalSplitNode
    let second: TerminalSplitNode
    let isVisible: Bool
    let showsFocusBorder: Bool
    @GestureState private var draggedRatio: CGFloat?
    @State private var isDividerHovered = false

    private let dividerVisibleSize: CGFloat = 1
    private let dividerInvisibleSize: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let containerLength = primaryLength(in: geometry.size)
            let availableLength = max(
                containerLength - dividerVisibleSize,
                0
            )
            let effectiveRatio = clampedRatio(draggedRatio ?? ratio)
            let firstLength = availableLength * effectiveRatio
            let secondLength = availableLength - firstLength

            ZStack(alignment: .topLeading) {
                switch axis {
                case .horizontal:
                    splitChild(first)
                        .frame(
                            width: firstLength,
                            height: geometry.size.height
                        )
                    splitChild(second)
                        .frame(
                            width: secondLength,
                            height: geometry.size.height
                        )
                        .offset(x: firstLength + dividerVisibleSize)
                    divider(containerLength: containerLength)
                        .position(
                            x: firstLength + dividerVisibleSize / 2,
                            y: geometry.size.height / 2
                        )
                case .vertical:
                    splitChild(first)
                        .frame(
                            width: geometry.size.width,
                            height: firstLength
                        )
                    splitChild(second)
                        .frame(
                            width: geometry.size.width,
                            height: secondLength
                        )
                        .offset(y: firstLength + dividerVisibleSize)
                    divider(containerLength: containerLength)
                        .position(
                            x: geometry.size.width / 2,
                            y: firstLength + dividerVisibleSize / 2
                        )
                }
            }
            .coordinateSpace(name: splitID)
        }
    }

    private func splitChild(_ node: TerminalSplitNode) -> some View {
        TerminalSplitTree(
            node: node,
            isVisible: isVisible,
            showsFocusBorder: showsFocusBorder
        )
            .clipped()
    }

    private func divider(containerLength: CGFloat) -> some View {
        ZStack {
            Color.clear
                .frame(
                    width: axis == .horizontal
                        ? dividerVisibleSize + dividerInvisibleSize
                        : nil,
                    height: axis == .vertical
                        ? dividerVisibleSize + dividerInvisibleSize
                        : nil
                )
                .contentShape(Rectangle())

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(
                    width: axis == .horizontal ? dividerVisibleSize : nil,
                    height: axis == .vertical ? dividerVisibleSize : nil
                )
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(splitID))
                .updating($draggedRatio) { value, draggedRatio, _ in
                    let length = primaryLength(in: value.location)
                    draggedRatio = ratioForDividerLocation(
                        length,
                        containerLength: containerLength
                    )
                }
                .onEnded { value in
                    let length = primaryLength(in: value.location)
                    model.updateSplitRatio(
                        ratioForDividerLocation(
                            length,
                            containerLength: containerLength
                        ),
                        for: splitID
                    )
                }
        )
        .onHover(perform: updateDividerHover)
        .onDisappear {
            updateDividerHover(false)
        }
        .accessibilityElement()
        .accessibilityLabel(
            axis == .horizontal
                ? "Resize Horizontal Split"
                : "Resize Vertical Split"
        )
        .accessibilityIdentifier("terminal-split-divider")
    }

    private func primaryLength(in size: CGSize) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    private func updateDividerHover(_ isHovered: Bool) {
        guard isDividerHovered != isHovered else { return }
        isDividerHovered = isHovered
        if isHovered {
            switch axis {
            case .horizontal:
                NSCursor.resizeLeftRight.push()
            case .vertical:
                NSCursor.resizeUpDown.push()
            }
        } else {
            NSCursor.pop()
        }
    }

    private func primaryLength(in point: CGPoint) -> CGFloat {
        axis == .horizontal ? point.x : point.y
    }

    private func ratioForDividerLocation(
        _ location: CGFloat,
        containerLength: CGFloat
    ) -> CGFloat {
        let availableLength = max(containerLength - dividerVisibleSize, 1)
        return clampedRatio(
            (location - dividerVisibleSize / 2) / availableLength
        )
    }

    private func clampedRatio(_ proposedRatio: CGFloat) -> CGFloat {
        min(max(proposedRatio, 0), 1)
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
                focusRequest: session.terminalFocusRequest,
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
            TerminalSearchField(
                text: $session.searchQuery,
                focusRequest: session.searchFocusRequest,
                onChange: session.updateSearch,
                onSubmit: {
                    session.navigateSearch(forward: true)
                },
                onCancel: session.dismissSearch
            )
            .frame(width: 210)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            searchButton(
                systemName: "chevron.up",
                help: "Previous Match (⇧⌘G)"
            ) {
                session.navigateSearch(forward: false)
            }

            searchButton(
                systemName: "chevron.down",
                help: "Next Match (⌘G)"
            ) {
                session.navigateSearch(forward: true)
            }

            searchButton(systemName: "xmark", help: "Close Find (Esc)") {
                session.dismissSearch()
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityLabel("Find in Terminal")
        .accessibilityIdentifier("terminal-search-bar")
    }

    private func searchButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption2.weight(.semibold))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct TerminalSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FocusableSearchField {
        let searchField = FocusableSearchField()
        searchField.placeholderString = "Find in Terminal"
        searchField.delegate = context.coordinator
        searchField.setAccessibilityIdentifier("terminal-search-field")
        return searchField
    }

    func updateNSView(
        _ searchField: FocusableSearchField,
        context: Context
    ) {
        context.coordinator.parent = self
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        searchField.requestFocus(focusRequest)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TerminalSearchField

        init(parent: TerminalSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }
            let query = searchField.stringValue
            parent.text = query
            parent.onChange(query)
        }

        func control(
            _: NSControl,
            textView _: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
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
}

private final class FocusableSearchField: NSSearchField {
    private var pendingFocusRequest: Int?
    private var completedFocusRequest: Int?
    private var focusAttemptCount = 0

    func requestFocus(_ request: Int) {
        if pendingFocusRequest != request {
            focusAttemptCount = 0
        }
        pendingFocusRequest = request
        focusIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfPossible()
    }

    private func focusIfPossible() {
        guard let request = pendingFocusRequest,
              request != completedFocusRequest,
              let window,
              focusAttemptCount < 5 else { return }
        focusAttemptCount += 1
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window,
                  self.pendingFocusRequest == request else { return }
            window.makeFirstResponder(self)
            self.selectText(nil)
            if self.currentEditor() != nil {
                self.completedFocusRequest = request
            } else {
                // SwiftUI may attach the view before AppKit installs its field
                // editor. Retry briefly so Command-F reliably receives input.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.focusIfPossible()
                }
            }
        }
    }
}

private struct SpaceTerminalViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let isVisible: Bool
    let requestsFocus: Bool
    let focusRequest: Int
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

    static func dismantleNSView(
        _ container: SpaceTerminalContainerView,
        coordinator: ()
    ) {
        container.prepareForRemoval()
    }

    private func configure(_ container: SpaceTerminalContainerView) {
        let view: SpaceTerminalView
        if let existing = session.terminalView as? SpaceTerminalView {
            view = existing
        } else {
            view = SpaceTerminalView(frame: .zero)
            session.terminalView = view
        }
        view.delegate = session.terminal
        view.controller = session.terminal.controller
        view.configuration = session.terminal.configuration
        container.configure(
            view,
            for: session,
            isVisible: isVisible,
            requestsFocus: requestsFocus,
            focusRequest: focusRequest,
            onActivate: onActivate
        )
    }
}

@MainActor
final class SpaceTerminalContainerView: NSView {
    private static let attachmentRetryDelay: TimeInterval = 0.01
    private static let maximumAttachmentRetries = 20

    private weak var terminalView: NSView?
    private weak var terminalSession: TerminalSession?
    private var attachmentRequest = 0
    private var attachmentRetryCount = 0
    private var isVisible = false
    private var requestsFocus = false
    private var focusRequest = 0
    private var onActivate: (() -> Void)?

    func configure(
        _ view: NSView,
        for session: TerminalSession,
        isVisible: Bool,
        requestsFocus: Bool,
        focusRequest: Int,
        onActivate: @escaping () -> Void
    ) {
        self.isVisible = isVisible
        self.requestsFocus = requestsFocus
        self.focusRequest = focusRequest
        self.onActivate = onActivate
        attach(view, for: session)
    }

    func attach(_ view: NSView, for session: TerminalSession) {
        if terminalSession !== session {
            attachmentRequest &+= 1
            attachmentRetryCount = 0
            if terminalSession?.terminalContainer === self {
                terminalSession?.terminalContainer = nil
            }
            if terminalView?.superview === self {
                terminalView?.removeFromSuperview()
            }
        }
        terminalView = view
        terminalSession = session
        guard window != nil else { return }
        scheduleAttachment()
    }

    func prepareForRemoval() {
        attachmentRequest &+= 1
        attachmentRetryCount = 0
        if terminalSession?.terminalContainer === self {
            terminalSession?.terminalContainer = nil
        }
        if terminalView?.superview === self {
            terminalView?.removeFromSuperview()
        }
        terminalView = nil
        terminalSession = nil
        onActivate = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            attachmentRequest &+= 1
            attachmentRetryCount = 0
            if terminalSession?.terminalContainer === self {
                terminalSession?.terminalContainer = nil
            }
            return
        }
        scheduleAttachment()
    }

    private func scheduleAttachment(after delay: TimeInterval = 0) {
        attachmentRequest &+= 1
        let request = attachmentRequest
        // Collapsing a split temporarily creates both the old and new
        // representable containers. Wait for SwiftUI to dismantle the old
        // hierarchy so a detached container cannot reclaim this terminal.
        if delay == 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self, attachmentRequest == request else { return }
                attachIfReady()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self, attachmentRequest == request else { return }
                attachIfReady()
            }
        }
    }

    private func attachIfReady() {
        guard window != nil,
              let terminalSession,
              let terminalView
        else { return }
        if let owner = terminalSession.terminalContainer,
           owner !== self,
           owner.window != nil {
            guard attachmentRetryCount < Self.maximumAttachmentRetries else {
                return
            }
            attachmentRetryCount += 1
            scheduleAttachment(after: Self.attachmentRetryDelay)
            return
        }
        attachmentRetryCount = 0
        terminalSession.terminalContainer = self
        guard terminalView.superview !== self else {
            applyPresentation(to: terminalView)
            return
        }
        terminalView.removeFromSuperview()
        terminalView.frame = bounds
        terminalView.autoresizingMask = [.width, .height]
        addSubview(terminalView)
        applyPresentation(to: terminalView)
        guard let terminalView = terminalView as? SpaceTerminalView else {
            return
        }
        DispatchQueue.main.async { [weak self, weak terminalView] in
            guard let self, let terminalView,
                  terminalView.superview === self
            else { return }
            terminalView.finishAttachment()
        }
    }

    private func applyPresentation(to view: NSView) {
        guard let view = view as? SpaceTerminalView else { return }
        view.setSurfaceVisible(isVisible)
        view.onActivate = onActivate
        view.requestFocus(focusRequest, enabled: requestsFocus)
    }
}

@MainActor
private final class SpaceTerminalView: TerminalView {
    private static let maximumFocusAttempts = 5
    private static let focusRetryDelay: TimeInterval = 0.05

    var onActivate: (() -> Void)?
    private var requestsFocus = false
    private var pendingFocusRequest: Int?
    private var completedFocusRequest: Int?
    private var focusAttemptCount = 0

    func requestFocus(_ request: Int, enabled: Bool) {
        requestsFocus = enabled
        guard enabled else {
            pendingFocusRequest = nil
            completedFocusRequest = nil
            focusAttemptCount = 0
            return
        }
        if pendingFocusRequest != request {
            pendingFocusRequest = request
            focusAttemptCount = 0
        }
        focusIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfPossible()
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
    }

    func finishAttachment() {
        fitToSize()
        focusIfPossible()
    }

    private func focusIfPossible() {
        guard requestsFocus,
              let request = pendingFocusRequest,
              completedFocusRequest != request,
              let window,
              focusAttemptCount < Self.maximumFocusAttempts
        else { return }
        focusAttemptCount += 1
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window,
                  requestsFocus,
                  pendingFocusRequest == request
            else { return }
            window.initialFirstResponder = self
            if window.firstResponder === self
                || window.makeFirstResponder(self) {
                completedFocusRequest = request
            } else {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.focusRetryDelay
                ) {
                    self.focusIfPossible()
                }
            }
        }
    }
}
