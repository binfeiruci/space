import AppKit
import GhosttyTerminal
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    private var folderImporterIsPresented: Binding<Bool> {
        Binding(
            get: { model.isFolderImporterPresented },
            set: { isPresented in
                if !isPresented { model.dismissFolderImporter() }
            }
        )
    }

    private var alertRequest: Binding<AlertRequest?> {
        Binding(
            get: { model.alertRequest },
            set: { state in
                if state == nil { model.dismissAlert() }
            }
        )
    }

    private var renameRequest: Binding<TabRenameRequest?> {
        Binding(
            get: { model.renameRequest },
            set: { request in
                if request == nil { model.dismissRenameRequest() }
            }
        )
    }

    private var navigationSplitViewVisibility:
        Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                model.isSidebarVisible ? .all : .detailOnly
            },
            set: { visibility in
                model.setSidebarVisible(visibility != .detailOnly)
            }
        )
    }

    private var navigationSplitViewContent: some View {
        NavigationSplitView(
            columnVisibility: navigationSplitViewVisibility
        ) {
            FolderSidebar()
        } detail: {
            TerminalArea()
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    @ViewBuilder
    private var navigationSplitView: some View {
        if #available(macOS 15.0, *) {
            navigationSplitViewContent
                .windowToolbarFullScreenVisibility(.onHover)
        } else {
            navigationSplitViewContent
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            navigationSplitView

            if let notice = model.memoSaveNotice {
                MemoSaveToast(
                    message: notice.message,
                    systemImage: notice.systemImage
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    model.dismissMemoSaveNotice(notice.id)
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.memoSaveNotice)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowConfigurator(
            model: model
        ))
        .fileImporter(
            isPresented: folderImporterIsPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            model.dismissFolderImporter()
            switch result {
            case let .success(urls):
                model.addFolders(urls)
            case let .failure(error):
                guard (error as NSError).code != NSUserCancelledError else {
                    return
                }
                model.presentFolderImportError(error)
            }
        }
        .alert(item: alertRequest) { state in
            appAlert(state)
        }
        .sheet(item: renameRequest) { request in
            TabRenameSheet(request: request)
                .environmentObject(model)
        }
    }

    private func appAlert(_ state: AlertRequest) -> Alert {
        guard let confirmationTitle = state.confirmationTitle,
              state.action != nil else {
            return Alert(
                title: Text(state.title),
                message: Text(state.message),
                dismissButton: .default(Text("OK")) {
                    model.dismissAlert()
                }
            )
        }
        return Alert(
            title: Text(state.title),
            message: Text(state.message),
            primaryButton: .destructive(Text(confirmationTitle)) {
                model.confirmAlert(state)
            },
            secondaryButton: .cancel {
                model.dismissAlert()
            }
        )
    }

}

private struct MemoSaveToast: View {
    let message: String
    let systemImage: String

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .padding(.bottom, 18)
            .accessibilityIdentifier("memo-save-toast")
    }
}

private struct TabRenameSheet: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var isNameFocused: Bool
    let request: TabRenameRequest
    @State private var title: String

    init(request: TabRenameRequest) {
        self.request = request
        _title = State(initialValue: request.initialTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Tab")
                .font(.headline)

            TextField(
                "Tab Name",
                text: $title,
                prompt: Text("Automatic: \(request.automaticTitle)")
            )
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(save)

            Text("Leave blank to use the automatic title.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.dismissRenameRequest()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear {
            isNameFocused = true
        }
    }

    private func save() {
        model.saveTabRename(request, title: title)
    }
}

private enum SidebarSelection: Hashable {
    case folder(String)
    case tab(UUID)
}

private struct SidebarRowColors {
    let primary: Color
    let secondary: Color

    init(appearance: NSAppearance = NSApp.effectiveAppearance) {
        primary = Self.resolve(.labelColor, appearance: appearance)
        secondary = Self.resolve(.secondaryLabelColor, appearance: appearance)
    }

    private static func resolve(
        _ color: NSColor,
        appearance: NSAppearance
    ) -> Color {
        var resolvedColor = color.cgColor
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.cgColor
        }
        return Color(cgColor: resolvedColor)
    }
}

private struct FolderSidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedFolderPaths: Set<String> = []

    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: {
                model.activeTerminalTab.map { .tab($0.id) }
            },
            set: { selection in
                switch selection {
                case let .folder(path):
                    guard let folder = model.folders.first(where: {
                        $0.id == path
                    }) else { return }
                    model.activateFolder(folder.url)
                case let .tab(id):
                    model.selectTab(id)
                case nil:
                    break
                }
            }
        )
    }

    private var foldersWithTabs: Binding<[Folder]> {
        groupedFolders(hasTabs: true)
    }

    private var foldersWithoutTabs: Binding<[Folder]> {
        groupedFolders(hasTabs: false)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                let standaloneTabs = tabs(ownerFolderURL: nil)
                if !standaloneTabs.wrappedValue.isEmpty {
                    Section("Tabs") {
                        tabRows(
                            standaloneTabs,
                            accessibilityPrefix: "standalone-terminal-tab-row:"
                        )
                    }
                }

                if !foldersWithTabs.wrappedValue.isEmpty {
                    Section {
                        tabbedFolderRows(foldersWithTabs)
                    }
                }

                if !foldersWithoutTabs.wrappedValue.isEmpty {
                    Section("Other Folders") {
                        folderRows(foldersWithoutTabs)
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear(perform: expandActiveFolder)
            .onChange(of: model.activeFolderURL) { _, url in
                guard let url else { return }
                expandedFolderPaths.insert(url.standardizedFileURL.path)
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(
                        sidebarItemID(for: url),
                        anchor: .center
                    )
                }
            }
            .onChange(of: model.activeTerminalTab?.id) { _, _ in
                expandActiveFolder()
            }
        }
    }

    private func tabbedFolderRows(
        _ folders: Binding<[Folder]>
    ) -> some View {
        ForEach(folders, editActions: .move) { folder in
            let value = folder.wrappedValue
            let folderTabs = tabs(ownerFolderURL: value.url)
            DisclosureGroup(
                isExpanded: expansionBinding(for: value)
            ) {
                if isExpanded(value) {
                    tabRows(
                        folderTabs,
                        accessibilityPrefix: "terminal-tab-row:"
                    )
                }
            } label: {
                FolderRow(
                    folder: value,
                    parentPath: disambiguatingParentPath(for: value),
                    isExpanded: isExpanded(value),
                    colors: rowColors
                )
            }
            .tag(SidebarSelection.folder(value.id))
            .id(sidebarItemID(for: value.url))
        }
    }

    private func tabRows(
        _ tabs: Binding<[TerminalTabState]>,
        accessibilityPrefix: String
    ) -> some View {
        ForEach(tabs, editActions: .move) { tab in
            let value = tab.wrappedValue
            if let session = model.terminalSession(
                id: value.focusedTerminalID
            ) {
                SidebarTerminalTabRow(
                    tab: value,
                    session: session,
                    shortcutLabel: shortcutLabel(for: value),
                    accessibilityIdentifier:
                        accessibilityPrefix + value.id.uuidString,
                    colors: rowColors
                )
                .tag(SidebarSelection.tab(value.id))
                .id(sidebarTabID(value.id))
            }
        }
    }

    private func groupedFolders(
        hasTabs: Bool
    ) -> Binding<[Folder]> {
        Binding(
            get: {
                hasTabs ? model.foldersWithTabs : model.foldersWithoutTabs
            },
            set: { reorderedFolders in
                var reordered = reorderedFolders.makeIterator()
                let allFolders = model.foldersInSidebarOrder.map { folder in
                    guard model.folderHasTabs(folder) == hasTabs
                    else { return folder }
                    return reordered.next() ?? folder
                }
                model.setFolderOrder(allFolders)
            }
        )
    }

    private func folderRows(
        _ folders: Binding<[Folder]>
    ) -> some View {
        ForEach(folders, editActions: .move) { folder in
            FolderRow(
                folder: folder.wrappedValue,
                parentPath: disambiguatingParentPath(
                    for: folder.wrappedValue
                ),
                isExpanded: false,
                colors: rowColors
            )
            .tag(SidebarSelection.folder(folder.wrappedValue.id))
            .id(sidebarItemID(for: folder.wrappedValue.url))
        }
    }

    private func tabs(
        ownerFolderURL: URL?
    ) -> Binding<[TerminalTabState]> {
        let ownerPath = ownerFolderURL?.standardizedFileURL.path
        return Binding(
            get: {
                model.terminalTabs.filter {
                    $0.ownerFolderURL?.standardizedFileURL.path == ownerPath
                }
            },
            set: { reorderedTabs in
                var reordered = reorderedTabs.makeIterator()
                let allTabs = model.terminalTabs.map { tab in
                    guard tab.ownerFolderURL?.standardizedFileURL.path
                            == ownerPath
                    else { return tab }
                    return reordered.next() ?? tab
                }
                model.setTabOrder(allTabs.map(\.id))
            }
        )
    }

    private var rowColors: SidebarRowColors {
        SidebarRowColors()
    }

    private func expansionBinding(for folder: Folder) -> Binding<Bool> {
        let path = folder.url.standardizedFileURL.path
        return Binding(
            get: { isExpanded(folder) },
            set: { expanded in
                if expanded {
                    expandedFolderPaths.insert(path)
                } else {
                    expandedFolderPaths.remove(path)
                }
            }
        )
    }

    private func isExpanded(_ folder: Folder) -> Bool {
        expandedFolderPaths.contains(folder.url.standardizedFileURL.path)
    }

    private func expandActiveFolder() {
        guard let path = model.activeFolderURL?.standardizedFileURL.path,
              model.activeTerminalTab != nil else { return }
        expandedFolderPaths.insert(path)
    }

    private func shortcutLabel(for tab: TerminalTabState) -> String? {
        let tabs = model.tabsInSidebarOrder
        guard let index = tabs.firstIndex(where: { $0.id == tab.id })
        else { return nil }
        if index < 8 { return "⌘\(index + 1)" }
        if index == tabs.count - 1 { return "⌘9" }
        return nil
    }

    private func sidebarItemID(for url: URL) -> String {
        "folder:\(url.standardizedFileURL.path)"
    }

    private func sidebarTabID(_ id: UUID) -> String {
        "tab:\(id.uuidString)"
    }

    private func disambiguatingParentPath(
        for folder: Folder
    ) -> String? {
        let name = folder.displayName
        guard model.folders.filter({
            $0.displayName == name
        }).count > 1 else { return nil }

        let parent = folder.url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") {
            return "~" + parent.dropFirst(home.count)
        }
        return parent
    }
}

private struct FolderRow: View {
    @EnvironmentObject private var model: AppModel
    let folder: Folder
    let parentPath: String?
    let isExpanded: Bool
    let colors: SidebarRowColors

    private var folderPath: String {
        folder.url.standardizedFileURL.path
    }

    private var isActive: Bool {
        model.activeFolderURL?.standardizedFileURL
            == folder.url.standardizedFileURL
    }

    private var needsAgentAttention: Bool {
        model.folderNeedsAgentAttention(folder.url)
    }

    private var terminalActivityFrame: String? {
        guard !isExpanded, !isActive, !needsAgentAttention else { return nil }
        return model.folderRefreshingTitleFrame(folder.url)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "folder.fill" : "folder")
                .foregroundStyle(
                    isActive ? Color.accentColor : colors.secondary
                )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let terminalActivityFrame {
                        Text(terminalActivityFrame)
                            .font(.caption.weight(.semibold).monospaced())
                            .foregroundStyle(colors.primary)
                    }

                    Text(folder.displayName)
                        .foregroundStyle(colors.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let parentPath {
                    Text(parentPath)
                        .font(.caption2)
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if needsAgentAttention {
                Circle()
                    .fill(.orange)
                    .accessibilityLabel("Agent needs attention")
                    .accessibilityIdentifier(
                        "agent-attention-folder:\(folderPath)"
                    )
            }
        }
        .contentShape(Rectangle())
        .help(folder.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Switch to folder \(folder.displayName)")
        .accessibilityValue(
            terminalActivityFrame == nil ? "" : "Terminal content is updating"
        )
        .accessibilityIdentifier(
            "folder-row:\(folderPath)"
        )
        .contextMenu {
            Button("New Tab") {
                model.openNewTerminal(for: folder.url)
            }

            Divider()

            Button("Reveal in Finder") {
                _ = NSWorkspace.shared.open(folder.url)
            }

            Divider()

            Button("Remove Folder", role: .destructive) {
                model.requestRemoveFolder(folder.url)
            }
        }
    }
}

private struct SidebarTerminalTabRow: View {
    @EnvironmentObject private var model: AppModel
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
        tab.displayTitle(
            automaticTitle: session.displayTitle(
                terminalTitle: terminal.title,
                foregroundProcessName: session.currentProcessName
            )
        )
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
            .accessibilityLabel("Close tab \(title)")
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)

            Image(systemName: "terminal")
                .foregroundStyle(colors.secondary)

            Text(title)
                .foregroundStyle(colors.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if model.tabNeedsAgentAttention(tab.id) {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Agent needs attention")
                    .accessibilityIdentifier(
                        "agent-attention-tab:\(tab.id.uuidString)"
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
            model.activeTerminalTab?.id == tab.id ? "Selected" : ""
        )
        .accessibilityIdentifier(accessibilityIdentifier)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contextMenu {
            Button("Rename Tab…") {
                model.promptRenameTab(tab.id)
            }
            Button("Close Tab") {
                model.requestCloseTab(tab.id)
            }
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
                DispatchQueue.main.async { [weak window] in
                    window?.performClose(nil)
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
