import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var windowWidth: CGFloat = 1_220

    private var terminalTabStripMaximumWidth: CGFloat {
        windowWidth * 2 / 3
    }

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

    var body: some View {
        ZStack {
            if model.folders.isEmpty {
                EmptyFolderView()
            } else {
                HSplitView {
                    if model.isSidebarVisible {
                        FolderSidebar()
                            .frame(minWidth: 160)
                    }

                    TerminalArea()
                        .frame(
                            minWidth: 560,
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                        .layoutPriority(1)
                }
            }

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
        .navigationTitle("")
        .background(WindowConfigurator(
            sidebarIsVisible: model.isSidebarVisible
        ))
        .toolbar {
            if !model.folders.isEmpty,
               !model.activeFolderTabs.isEmpty {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .principal) {
                        TerminalTitleBarContent(
                            maximumTabStripWidth: terminalTabStripMaximumWidth
                        )
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) {
                        TerminalTitleBarContent(
                            maximumTabStripWidth: terminalTabStripMaximumWidth
                        )
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            ToolbarItemGroup(placement: .navigation) {
                if !model.folders.isEmpty {
                    Button {
                        model.toggleSidebar()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .help(model.isSidebarVisible
                        ? "Hide Sidebar (⌥⌘S)"
                        : "Show Sidebar (⌥⌘S)")
                    .accessibilityLabel(model.isSidebarVisible
                        ? "Hide Sidebar"
                        : "Show Sidebar")
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            guard width > 0 else { return }
            windowWidth = width
        }
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
            .frame(height: 32)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .padding(.bottom, 18)
            .frame(maxHeight: .infinity, alignment: .bottom)
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
        .frame(width: 380)
        .onAppear {
            isNameFocused = true
        }
    }

    private func save() {
        model.saveTabRename(request, title: title)
    }
}

private struct FolderSidebar: View {
    @EnvironmentObject private var model: AppModel

    private var selection: Binding<String?> {
        Binding(
            get: {
                model.activeFolderURL?.standardizedFileURL.path
            },
            set: { path in
                guard let path,
                      let folder = model.folders.first(where: {
                          $0.id == path
                      }) else { return }
                model.activateFolder(folder.url)
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
                if !foldersWithTabs.wrappedValue.isEmpty {
                    Section {
                        folderRows(foldersWithTabs)
                    }
                }

                if !foldersWithoutTabs.wrappedValue.isEmpty {
                    Section("No Tabs") {
                        folderRows(foldersWithoutTabs)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: model.activeFolderURL) { _, url in
                guard let url else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(url.standardizedFileURL.path, anchor: .center)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
                let allFolders = model.folders.map { folder in
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
                )
            )
            .tag(folder.wrappedValue.id)
            .id(folder.wrappedValue.id)
        }
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
        guard !isActive, !needsAgentAttention else { return nil }
        return model.folderRefreshingTitleFrame(folder.url)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "folder.fill" : "folder")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let terminalActivityFrame {
                        Text(terminalActivityFrame)
                            .font(.system(
                                size: 12,
                                weight: .semibold,
                                design: .monospaced
                            ))
                            .frame(width: 10)
                    }

                    Text(folder.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let parentPath {
                    Text(parentPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if needsAgentAttention {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Agent needs attention")
                    .accessibilityIdentifier(
                        "agent-attention-folder:\(folderPath)"
                    )
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: parentPath == nil ? 24 : 36,
            alignment: .leading
        )
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

private struct EmptyFolderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)

            Text("No Folders")
                .font(.title2.weight(.semibold))

            Button("Add Folder…") {
                model.chooseFolder()
            }
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let sidebarIsVisible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWindow(for: view)
    }

    private func configureWindow(for view: NSView) {
        _ = sidebarIsVisible
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.setFrameAutosaveName("Space.MainWindow")
            window.tabbingMode = .disallowed
            window.title = ""
            window.titleVisibility = .hidden
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
        .frame(width: 1_100, height: 720)
}
