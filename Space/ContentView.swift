import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var workspace: AppModel
    @State private var sidebarWidth = 290.0
    @State private var windowWidth: CGFloat = 1_220

    private var terminalTabStripMaximumWidth: CGFloat {
        windowWidth * 2 / 3
    }

    private var folderImporterIsPresented: Binding<Bool> {
        Binding(
            get: { workspace.isFolderImporterPresented },
            set: { isPresented in
                if !isPresented { workspace.dismissFolderImporter() }
            }
        )
    }

    private var alertState: Binding<WorkspaceAlertState?> {
        Binding(
            get: { workspace.alertState },
            set: { state in
                if state == nil { workspace.dismissAlert() }
            }
        )
    }

    private var renameRequest: Binding<TerminalRenameRequest?> {
        Binding(
            get: { workspace.renameRequest },
            set: { request in
                if request == nil { workspace.dismissRenameRequest() }
            }
        )
    }

    var body: some View {
        ZStack {
            if workspace.folders.isEmpty {
                WorkspaceEmptyView()
            } else {
                HSplitView {
                    if workspace.isSidebarVisible {
                        DirectorySidebar()
                        .frame(
                            minWidth: 230,
                            idealWidth: sidebarWidth,
                            maxWidth: 420
                        )
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: SidebarWidthPreferenceKey.self,
                                    value: geometry.size.width
                                )
                            }
                        }
                    }

                    TerminalWorkspacePane()
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .background(WindowConfigurator(
            sidebarIsVisible: workspace.isSidebarVisible
        ))
        .toolbar {
            if !workspace.folders.isEmpty,
               !workspace.activeDirectoryTabs.isEmpty {
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
                if !workspace.folders.isEmpty {
                    Button {
                        workspace.toggleSidebar()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .help(workspace.isSidebarVisible
                        ? "收起文件夹列表（⌥⌘S）"
                        : "展开文件夹列表（⌥⌘S）")
                    .accessibilityLabel(workspace.isSidebarVisible
                        ? "收起文件夹列表"
                        : "展开文件夹列表")
                }
            }
        }
        .onPreferenceChange(SidebarWidthPreferenceKey.self) { width in
            guard workspace.isSidebarVisible,
                  width >= 230,
                  width <= 420 else { return }
            sidebarWidth = width
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
            workspace.dismissFolderImporter()
            switch result {
            case let .success(urls):
                workspace.addRootDirectories(urls)
            case let .failure(error):
                guard (error as NSError).code != NSUserCancelledError else {
                    return
                }
                workspace.presentFolderImportError(error)
            }
        }
        .alert(item: alertState) { state in
            workspaceAlert(state)
        }
        .sheet(item: renameRequest) { request in
            TerminalRenameSheet(request: request)
                .environmentObject(workspace)
        }
    }

    private func workspaceAlert(_ state: WorkspaceAlertState) -> Alert {
        guard let confirmationTitle = state.confirmationTitle,
              state.action != nil else {
            return Alert(
                title: Text(state.title),
                message: Text(state.message),
                dismissButton: .default(Text("好")) {
                    workspace.dismissAlert()
                }
            )
        }
        return Alert(
            title: Text(state.title),
            message: Text(state.message),
            primaryButton: .destructive(Text(confirmationTitle)) {
                workspace.confirmAlert(state)
            },
            secondaryButton: .cancel {
                workspace.dismissAlert()
            }
        )
    }
}

private struct TerminalRenameSheet: View {
    @EnvironmentObject private var workspace: AppModel
    @FocusState private var isNameFocused: Bool
    let request: TerminalRenameRequest
    @State private var title: String

    init(request: TerminalRenameRequest) {
        self.request = request
        _title = State(initialValue: request.initialTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名终端")
                .font(.headline)

            TextField("终端名称", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(save)

            Text("留空即可恢复跟随前台程序的标题。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    workspace.dismissRenameRequest()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存", action: save)
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
        workspace.saveTerminalRename(request, title: title)
    }
}

private struct DirectorySidebar: View {
    @EnvironmentObject private var workspace: AppModel

    private var selection: Binding<String?> {
        Binding(
            get: {
                workspace.activeDirectory?.standardizedFileURL.path
            },
            set: { path in
                guard let path,
                      let folder = workspace.folders.first(where: {
                          $0.id == path
                      }) else { return }
                workspace.activateTerminal(for: folder.url)
            }
        )
    }

    private var folders: Binding<[WorkspaceFolder]> {
        Binding(
            get: { workspace.folders },
            set: workspace.setFolderOrder
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("文件夹")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)

            Divider()

            ScrollViewReader { proxy in
                List(
                    folders,
                    editActions: .move,
                    selection: selection
                ) { folder in
                    DirectoryRow(
                        folder: folder.wrappedValue,
                        parentPath: disambiguatingParentPath(
                            for: folder.wrappedValue
                        )
                    )
                    .tag(folder.wrappedValue.id)
                    .id(folder.wrappedValue.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: workspace.activeDirectory) { _, url in
                    guard let url else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(url.standardizedFileURL.path, anchor: .center)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func disambiguatingParentPath(
        for folder: WorkspaceFolder
    ) -> String? {
        let name = folder.url.lastPathComponent
        guard workspace.folders.filter({
            $0.url.lastPathComponent == name
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

private struct DirectoryRow: View {
    @EnvironmentObject private var workspace: AppModel
    let folder: WorkspaceFolder
    let parentPath: String?

    private var folderPath: String {
        folder.url.standardizedFileURL.path
    }

    private var isActive: Bool {
        workspace.activeDirectory?.standardizedFileURL
            == folder.url.standardizedFileURL
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "folder.fill" : "folder")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(folder.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let parentPath {
                    Text(parentPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if workspace.folderNeedsAgentAttention(folder.url) {
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
        .accessibilityLabel("切换到文件夹 \(folder.url.lastPathComponent)")
        .accessibilityIdentifier(
            "folder-row:\(folderPath)"
        )
        .contextMenu {
            Button("Reveal in Finder") {
                _ = NSWorkspace.shared.open(folder.url)
            }

            Divider()

            Button("Remove Folder", role: .destructive) {
                workspace.requestRemoveRootDirectory(folder.url)
            }
        }
    }
}

private struct WorkspaceEmptyView: View {
    @EnvironmentObject private var workspace: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)

            Text("添加文件夹")
                .font(.title2.weight(.semibold))

            Text("添加一个或多个文件夹，开始使用 Space。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("添加文件夹…") {
                workspace.chooseRootDirectory()
            }
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SidebarWidthPreferenceKey: PreferenceKey {
    static var defaultValue = 290.0

    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = nextValue()
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
