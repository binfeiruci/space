import AppKit
import GhosttyTerminal
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model: AppModel

    private var alertRequest: Binding<AlertRequest?> {
        Binding(
            get: { model.alertRequest },
            set: { if $0 == nil { model.dismissAlert() } }
        )
    }

    private var splitViewVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.isSidebarVisible ? .all : .detailOnly },
            set: { model.setSidebarVisible($0 != .detailOnly) }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: splitViewVisibility) {
            TabSidebar()
        } detail: {
            TerminalArea()
                .ignoresSafeArea(.container, edges: .top)
        }
        .modifier(FullScreenToolbarModifier())
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowConfigurator(model: model))
        .alert(item: alertRequest) { state in
            appAlert(state)
        }
    }

    private func appAlert(_ state: AlertRequest) -> Alert {
        Alert(
            title: Text(state.title),
            message: Text(state.message),
            primaryButton: .destructive(Text(state.confirmationTitle)) {
                model.confirmAlert(state)
            },
            secondaryButton: .cancel { model.dismissAlert() }
        )
    }
}

private struct FullScreenToolbarModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(.onHover)
        } else {
            content
        }
    }
}

private struct SidebarRowColors {
    let primary: Color
    let secondary: Color

    init(colorScheme: ColorScheme) {
        // NSApp.effectiveAppearance does not track preferredColorScheme.
        let appearance = NSAppearance(
            named: colorScheme == .dark ? .darkAqua : .aqua
        ) ?? NSApp.effectiveAppearance
        primary = Self.resolve(.labelColor, appearance: appearance)
        secondary = Self.resolve(.secondaryLabelColor, appearance: appearance)
    }

    private static func resolve(
        _ color: NSColor,
        appearance: NSAppearance
    ) -> Color {
        var result = color.cgColor
        appearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return Color(cgColor: result)
    }
}

private struct SidebarStatusDot: View {
    let identifier: String

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Unread terminal activity")
            .accessibilityIdentifier(identifier)
    }
}

private struct TabSidebar: View {
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    private var selection: Binding<TerminalTabSidebarItem?> {
        Binding(
            get: { model.activeTabID.map(TerminalTabSidebarItem.tab) },
            set: {
                guard case let .tab(id)? = $0 else { return }
                model.selectTab(id)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            ForEach(model.tabSidebarItems) { item in
                sidebarItem(item)
            }
            .onMove(perform: model.moveTabSidebarItems)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sidebarItem(_ item: TerminalTabSidebarItem) -> some View {
        switch item {
        case let .tab(id):
            if let tab = model.terminalTab(id: id),
               let session = model.terminalSession(id: tab.focusedTerminalID) {
                SidebarTerminalTabRow(
                    tab: tab,
                    session: session,
                    shortcutLabel: shortcutLabel(for: tab),
                    accessibilityIdentifier: "terminal-tab-row:"
                        + tab.id.uuidString,
                    colors: SidebarRowColors(colorScheme: colorScheme)
                )
                .tag(item)
            }
        case let .divider(id):
            Divider()
                .padding(.vertical, 6)
                .listRowInsets(
                    EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
                )
                .accessibilityLabel("Tab divider")
                .accessibilityIdentifier(
                    "terminal-tab-divider:" + id.uuidString
                )
                .tag(item)
                .contextMenu {
                    Button("Remove Divider") {
                        model.removeTabDivider(id: id)
                    }
                }
        }
    }

    private func shortcutLabel(for tab: TerminalTabState) -> String? {
        guard let index = model.terminalTabs.firstIndex(where: {
            $0.id == tab.id
        }) else { return nil }
        if index < 8 { return "⌘\(index + 1)" }
        if index == model.terminalTabs.count - 1 { return "⌘9" }
        return nil
    }
}

private struct SidebarTerminalTabRow: View {
    @Environment(AppModel.self) private var model: AppModel
    let tab: TerminalTabState
    @ObservedObject var session: TerminalSession
    @ObservedObject private var terminal: TerminalViewState
    let shortcutLabel: String?
    let accessibilityIdentifier: String
    let colors: SidebarRowColors
    @State private var isHovering = false

    init(
        tab: TerminalTabState,
        session: TerminalSession,
        shortcutLabel: String?,
        accessibilityIdentifier: String,
        colors: SidebarRowColors
    ) {
        self.tab = tab
        _session = ObservedObject(wrappedValue: session)
        _terminal = ObservedObject(wrappedValue: session.terminal)
        self.shortcutLabel = shortcutLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.colors = colors
    }

    private var title: String {
        session.displayTitle(terminalTitle: terminal.title)
    }

    private var showsUnread: Bool {
        model.activeTerminalTab?.id != tab.id
            && !model.tabHasActiveTitleActivity(tab.id)
            && model.tabHasUnreadTitleActivity(tab.id)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.requestCloseTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(colors.secondary)
            .help("Close Tab")
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)

            Image(systemName: "terminal")
                .foregroundStyle(colors.secondary)

            Text(title)
                .foregroundStyle(colors.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if showsUnread {
                SidebarStatusDot(
                    identifier: "unread-title-tab:\(tab.id.uuidString)"
                )
            }

            Spacer(minLength: 4)

            if let shortcutLabel {
                Text(shortcutLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(colors.secondary)
            }
        }
        .contentShape(Rectangle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(
            model.activeTerminalTab?.id == tab.id
                ? "Selected" : (showsUnread ? "Unread terminal activity" : "")
        )
        .accessibilityIdentifier(accessibilityIdentifier)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contextMenu {
            Button("Duplicate Tab") {
                model.duplicateTab(tab.id)
            }

            Button("New Tab Below") {
                model.openNewTerminal(after: tab.id)
            }

            Button("New Divider Below") {
                model.addTabDivider(after: tab.id)
            }

            Divider()

            Button("Close Tab") { model.requestCloseTab(tab.id) }
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWindow(for: view)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.tabbingMode = .disallowed
            model.closeWindowHandler = { [weak window] in
                DispatchQueue.main.async { window?.performClose(nil) }
            }
        }
    }
}

#Preview {
    ContentView().environment(AppModel())
}
