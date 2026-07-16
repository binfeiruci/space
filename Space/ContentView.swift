import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @State private var isSidebarVisible = true
    @State private var sidebarWidth = 290.0

    var body: some View {
        ZStack {
            if workspace.rootNodes.isEmpty {
                WorkspaceEmptyView()
            } else {
                HSplitView {
                    if isSidebarVisible {
                        FileSidebar()
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

            if workspace.isCommandPalettePresented {
                DirectoryCommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }

            if workspace.isActionPalettePresented {
                SpaceCommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(2)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowFrameAutosaver(
            title: workspace.activeDirectory?.lastPathComponent ?? "Space"
        ))
        .toolbar {
            if !workspace.rootNodes.isEmpty {
                ToolbarItem(placement: .principal) {
                    TerminalTabStrip()
                        .frame(minWidth: 320, idealWidth: 620, maxWidth: 900)
                }
            }

            ToolbarItemGroup(placement: .navigation) {
                if !workspace.rootNodes.isEmpty {
                    Button {
                        isSidebarVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .help(isSidebarVisible
                        ? "收起文件目录（⌥⌘S）"
                        : "展开文件目录（⌥⌘S）")
                    .accessibilityLabel(isSidebarVisible
                        ? "收起文件目录"
                        : "展开文件目录")
                }

                Button {
                    workspace.chooseRootDirectory()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("添加工作目录")
                .accessibilityLabel("添加工作目录")
            }
        }
        .onPreferenceChange(SidebarWidthPreferenceKey.self) { width in
            guard isSidebarVisible, width >= 230, width <= 420 else { return }
            sidebarWidth = width
        }
        .animation(
            .easeOut(duration: 0.12),
            value: workspace.isCommandPalettePresented
        )
        .animation(
            .easeOut(duration: 0.12),
            value: workspace.isActionPalettePresented
        )
    }
}

private struct FileSidebar: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @FocusState private var isFileTreeFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(
                        Array(workspace.rootNodes.enumerated()),
                        id: \.element.id
                    ) { index, rootNode in
                        DirectoryTreeNode(
                            node: rootNode,
                            depth: 0,
                            showsWorkspaceFilter: index == 0,
                            focusFileTree: { isFileTreeFocused = true }
                        )
                        .id(rootNode.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: workspace.selectedTreeItemURL) { _, url in
                guard let url else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(url.standardizedFileURL.path, anchor: .center)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focused($isFileTreeFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard workspace.selectedFileURL != nil else { return .ignored }
            workspace.toggleSelectedFilePreview()
            return .handled
        }
        .onKeyPress(.escape) {
            guard QuickLookPreviewController.shared.isPresented else {
                return .ignored
            }
            QuickLookPreviewController.shared.closePreview()
            return .handled
        }
        .onKeyPress(.upArrow) {
            workspace.moveTreeSelection(offset: -1)
                ? .handled
                : .ignored
        }
        .onKeyPress(.downArrow) {
            workspace.moveTreeSelection(offset: 1)
                ? .handled
                : .ignored
        }
        .onKeyPress(.leftArrow) {
            workspace.collapseOrSelectParentTreeDirectory()
                ? .handled
                : .ignored
        }
        .onKeyPress(.rightArrow) {
            workspace.expandOrEnterSelectedTreeDirectory()
                ? .handled
                : .ignored
        }
        .onKeyPress(.return) {
            workspace.openSelectedTreeItemInTerminal()
                ? .handled
                : .ignored
        }
    }
}

private struct DirectoryTreeNode: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var node: FileNode
    let depth: Int
    let showsWorkspaceFilter: Bool
    let focusFileTree: () -> Void
    @State private var isHovering = false

    private var isExpanded: Bool {
        workspace.isDirectoryExpanded(node.url)
    }

    private var isSelected: Bool {
        workspace.selectedTreeItemURL?.standardizedFileURL
            == node.url.standardizedFileURL
    }

    private var isActive: Bool {
        workspace.activeDirectory?.standardizedFileURL
            == node.url.standardizedFileURL
    }

    private var ownsTerminal: Bool {
        workspace.hasTerminalSession(exactlyAt: node.url)
    }

    private var terminalCount: Int {
        workspace.terminalSessionCount(exactlyAt: node.url)
    }

    private var visibleChildren: [FileNode] {
        guard workspace.showTerminalDirectoriesOnly else { return node.children }
        return node.children.filter {
            $0.isDirectory && workspace.hasTerminalSession(in: $0.url)
        }
    }

    private var canExpand: Bool {
        !workspace.showTerminalDirectoriesOnly
            || workspace.hasTerminalSessionDescendant(in: node.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Button {
                    workspace.selectTreeNode(node)
                    focusFileTree()
                    guard canExpand else { return }
                    let expanded = !isExpanded
                    workspace.setDirectoryExpanded(expanded, url: node.url)
                    if expanded {
                        node.loadChildren()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(canExpand ? 1 : 0)
                .allowsHitTesting(canExpand)
                .accessibilityLabel(isExpanded ? "收起目录" : "展开目录")

                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .foregroundStyle(isSelected || isActive
                        ? Color.accentColor
                        : Color.secondary)

                Text(node.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(node.url.path)

                Button {
                    focusFileTree()
                    workspace.activateTerminal(for: node.url)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(ownsTerminal ? "切换到此目录的终端" : "在此目录新建终端")
                .accessibilityLabel(ownsTerminal
                    ? "切换到 \(node.url.lastPathComponent) 的终端"
                    : "在 \(node.url.lastPathComponent) 新建终端")
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)

                Spacer(minLength: 4)

                if ownsTerminal {
                    Button {
                        workspace.activateTerminal(for: node.url)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "terminal.fill")
                            if terminalCount > 1 {
                                Text("\(terminalCount)")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("切换到此目录已有的终端")
                    .accessibilityLabel("此目录有 \(terminalCount) 个终端")
                }

                if showsWorkspaceFilter {
                    Button {
                        if !workspace.showTerminalDirectoriesOnly {
                            workspace.selectTreeNode(node)
                        }
                        workspace.showTerminalDirectoriesOnly.toggle()
                    } label: {
                        Image(systemName: workspace.showTerminalDirectoriesOnly
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(workspace.showTerminalDirectoriesOnly
                            ? Color.accentColor
                            : Color.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(workspace.showTerminalDirectoriesOnly
                        ? "显示全部文件"
                        : "仅显示已打开终端的目录")
                    .accessibilityLabel(workspace.showTerminalDirectoriesOnly
                        ? "显示全部文件"
                        : "仅显示已打开终端的目录")
                }
            }
            .padding(.leading, CGFloat(depth) * 16 + 8)
            .padding(.trailing, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.2)
                        : isActive
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear)
            )
            .simultaneousGesture(TapGesture().onEnded {
                workspace.selectTreeNode(node)
                focusFileTree()
            })
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onAppear {
                if workspace.showTerminalDirectoriesOnly,
                   workspace.hasTerminalSessionDescendant(in: node.url) {
                    workspace.setDirectoryExpanded(true, url: node.url)
                }
                if isExpanded {
                    node.loadChildren()
                }
            }
            .onChange(of: workspace.showTerminalDirectoriesOnly) { _, filtered in
                if filtered,
                   workspace.hasTerminalSessionDescendant(in: node.url) {
                    workspace.setDirectoryExpanded(true, url: node.url)
                    node.loadChildren()
                }
            }

            if isExpanded {
                if let errorMessage = node.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, CGFloat(depth + 1) * 16 + 30)
                        .padding(.vertical, 4)
                } else if node.isLoading && visibleChildren.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("正在读取…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, CGFloat(depth + 1) * 16 + 30)
                    .padding(.vertical, 4)
                } else if visibleChildren.isEmpty,
                          !workspace.showTerminalDirectoriesOnly {
                    Text("空目录")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(depth + 1) * 16 + 30)
                        .padding(.vertical, 4)
                } else {
                    ForEach(visibleChildren) { child in
                        if child.isDirectory {
                            DirectoryTreeNode(
                                node: child,
                                depth: depth + 1,
                                showsWorkspaceFilter: false,
                                focusFileTree: focusFileTree
                            )
                        } else {
                            FileTreeRow(
                                node: child,
                                depth: depth + 1,
                                focusFileTree: focusFileTree
                            )
                        }
                    }
                }
            }
        }
        .contextMenu {
            if workspace.isRootDirectory(node.url) {
                Button("从工作区移除文件夹", role: .destructive) {
                    workspace.requestRemoveRootDirectory(node.url)
                }
            }
        }
    }
}

private struct WorkspaceEmptyView: View {
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)

            Text("添加工作目录")
                .font(.title2.weight(.semibold))

            Text("添加一个或多个互不包含的文件夹，开始使用终端工作区。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("添加目录…") {
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

private struct WindowFrameAutosaver: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWindow(for: view)
    }

    private func configureWindow(for view: NSView) {
        let title = title
        DispatchQueue.main.async { [weak view] in
            view?.window?.setFrameAutosaveName("Space.MainWindow")
            view?.window?.title = title
        }
    }
}

private struct FileTreeRow: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    let node: FileNode
    let depth: Int
    let focusFileTree: () -> Void

    private var isSelected: Bool {
        workspace.selectedTreeItemURL?.standardizedFileURL
            == node.url.standardizedFileURL
    }

    var body: some View {
        Button {
            workspace.selectFile(node.url)
            focusFileTree()
        } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: 12, height: 20)
                Image(systemName: "doc")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(node.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.leading, CGFloat(depth) * 16 + 8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .id(node.url.standardizedFileURL.path)
        .help("\(node.url.path)\n回车在终端查看 · 空格快速预览")
        .accessibilityLabel(
            "\(node.url.lastPathComponent)，回车在终端查看，空格快速预览"
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(WorkspaceModel())
        .frame(width: 1_100, height: 720)
}
