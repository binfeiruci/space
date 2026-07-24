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

private struct SidebarStatusDot: View {
    let color: Color
    let label: String
    let identifier: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}

private struct FolderSidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedFolderPaths: Set<String> = []
    @State private var unreadCollapsedFolderPaths: Set<String> = []

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

    private var foldersWithTabs: [Folder] {
        model.foldersWithTabs
    }

    private var foldersWithoutTabs: [Folder] {
        model.foldersWithoutTabs
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                let standaloneTabs = tabs(ownerFolderURL: nil)
                if !standaloneTabs.isEmpty || !foldersWithTabs.isEmpty {
                    Section("Tabs") {
                        if !standaloneTabs.isEmpty {
                            tabRows(
                                standaloneTabs,
                                accessibilityPrefix: "standalone-terminal-tab-row:"
                            )
                        }

                        if !foldersWithTabs.isEmpty {
                            tabbedFolderRows(foldersWithTabs)
                        }
                    }
                }

                if !foldersWithoutTabs.isEmpty {
                    Section {
                        folderRows(foldersWithoutTabs)
                    } header: {
                        Text("Other Folders")
                            .padding(.top)
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear(perform: expandActiveFolder)
            .onChange(of: model.activeFolderURL) { _, url in
                guard let url else { return }
                expandFolder(at: url.standardizedFileURL.path)
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
            .onChange(of: model.latestUnreadTitleActivity) {
                _, activity in
                recordUnreadTitleActivity(activity)
            }
            .onChange(of: model.unreadTitleTabIDs) { _, _ in
                unreadCollapsedFolderPaths.formIntersection(
                    model.unreadTitleFolderPaths
                )
            }
        }
    }

    private func tabbedFolderRows(
        _ folders: [Folder]
    ) -> some View {
        ForEach(folders) { folder in
            let folderTabs = tabs(ownerFolderURL: folder.url)
            DisclosureGroup(
                isExpanded: expansionBinding(for: folder)
            ) {
                if isExpanded(folder) {
                    tabRows(
                        folderTabs,
                        accessibilityPrefix: "terminal-tab-row:"
                    )
                }
            } label: {
                FolderRow(
                    folder: folder,
                    parentPath: disambiguatingParentPath(for: folder),
                    isExpanded: isExpanded(folder),
                    hasUnreadTitleActivity:
                        unreadCollapsedFolderPaths.contains(
                            folder.url.standardizedFileURL.path
                        ),
                    colors: rowColors
                )
            }
            .tag(SidebarSelection.folder(folder.id))
            .id(sidebarItemID(for: folder.url))
        }
        .onMove { source, destination in
            moveFolders(
                folders,
                hasTabs: true,
                fromOffsets: source,
                toOffset: destination
            )
        }
    }

    private func tabRows(
        _ tabs: [TerminalTabState],
        accessibilityPrefix: String
    ) -> some View {
        ForEach(tabs) { tab in
            if let session = model.terminalSession(
                id: tab.focusedTerminalID
            ) {
                SidebarTerminalTabRow(
                    tab: tab,
                    session: session,
                    shortcutLabel: shortcutLabel(for: tab),
                    accessibilityIdentifier:
                        accessibilityPrefix + tab.id.uuidString,
                    colors: rowColors
                )
                .tag(SidebarSelection.tab(tab.id))
                .id(sidebarTabID(tab.id))
            }
        }
        .onMove { source, destination in
            moveTabs(
                tabs,
                fromOffsets: source,
                toOffset: destination
            )
        }
    }

    private func moveFolders(
        _ folders: [Folder],
        hasTabs: Bool,
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        model.setFolderOrder(reordering(
            folders,
            within: model.foldersInSidebarOrder,
            matching: { model.folderHasTabs($0) == hasTabs },
            fromOffsets: source,
            toOffset: destination
        ))
    }

    private func moveTabs(
        _ tabs: [TerminalTabState],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        let ownerPath = tabs.first?.ownerFolderURL?.standardizedFileURL.path
        let allTabs = reordering(
            tabs,
            within: model.terminalTabs,
            matching: {
                $0.ownerFolderURL?.standardizedFileURL.path == ownerPath
            },
            fromOffsets: source,
            toOffset: destination
        )
        model.setTabOrder(allTabs.map(\.id))
    }

    private func reordering<Element>(
        _ groupedElements: [Element],
        within allElements: [Element],
        matching predicate: (Element) -> Bool,
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [Element] {
        var reorderedElements = groupedElements
        reorderedElements.move(
            fromOffsets: source,
            toOffset: destination
        )
        var reordered = reorderedElements.makeIterator()
        return allElements.map { element in
            predicate(element) ? reordered.next() ?? element : element
        }
    }

    private func folderRows(
        _ folders: [Folder]
    ) -> some View {
        ForEach(folders) { folder in
            FolderRow(
                folder: folder,
                parentPath: disambiguatingParentPath(for: folder),
                isExpanded: false,
                hasUnreadTitleActivity: false,
                colors: rowColors
            )
            .tag(SidebarSelection.folder(folder.id))
            .id(sidebarItemID(for: folder.url))
        }
        .onMove { source, destination in
            moveFolders(
                folders,
                hasTabs: false,
                fromOffsets: source,
                toOffset: destination
            )
        }
    }

    private func tabs(
        ownerFolderURL: URL?
    ) -> [TerminalTabState] {
        let ownerPath = ownerFolderURL?.standardizedFileURL.path
        return model.terminalTabs.filter {
            $0.ownerFolderURL?.standardizedFileURL.path == ownerPath
        }
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
                    expandFolder(at: path)
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
        expandFolder(at: path)
    }

    private func expandFolder(at path: String) {
        expandedFolderPaths.insert(path)
        unreadCollapsedFolderPaths.remove(path)
    }

    private func recordUnreadTitleActivity(
        _ activity: UnreadTitleActivityEvent?
    ) {
        guard let activity,
              let tab = model.terminalTab(id: activity.tabID),
              let path = tab.ownerFolderURL?.standardizedFileURL.path,
              !expandedFolderPaths.contains(path)
        else { return }
        unreadCollapsedFolderPaths.insert(path)
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
    let hasUnreadTitleActivity: Bool
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

    private var showsUnreadIndicator: Bool {
        !isExpanded
            && !isActive
            && !needsAgentAttention
            && terminalActivityFrame == nil
            && hasUnreadTitleActivity
    }

    private var accessibilityValue: String {
        if terminalActivityFrame != nil {
            return "Terminal content is updating"
        }
        return showsUnreadIndicator ? "Unread terminal activity" : ""
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
                SidebarStatusDot(
                    color: .orange,
                    label: "Agent needs attention",
                    identifier: "agent-attention-folder:\(folderPath)"
                )
            } else if showsUnreadIndicator {
                SidebarStatusDot(
                    color: .accentColor,
                    label: "Unread terminal activity",
                    identifier: "unread-title-folder:\(folderPath)"
                )
            }
        }
        .contentShape(Rectangle())
        .help(folder.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Switch to folder \(folder.displayName)")
        .accessibilityValue(accessibilityValue)
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

    private var needsAgentAttention: Bool {
        model.tabNeedsAgentAttention(tab.id)
    }

    private var showsUnreadIndicator: Bool {
        model.activeTerminalTab?.id != tab.id
            && !needsAgentAttention
            && !model.tabIsRefreshingTitle(tab.id)
            && model.tabHasUnreadTitleActivity(tab.id)
    }

    private var accessibilityValue: String {
        if model.activeTerminalTab?.id == tab.id {
            return "Selected"
        }
        return showsUnreadIndicator ? "Unread terminal activity" : ""
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

            if needsAgentAttention {
                SidebarStatusDot(
                    color: .orange,
                    label: "Agent needs attention",
                    identifier: "agent-attention-tab:\(tab.id.uuidString)"
                )
            } else if showsUnreadIndicator {
                SidebarStatusDot(
                    color: .accentColor,
                    label: "Unread terminal activity",
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
        .accessibilityValue(accessibilityValue)
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
