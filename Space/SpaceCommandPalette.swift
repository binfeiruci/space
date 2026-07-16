import AppKit
import SwiftUI

private struct SpacePaletteCommand: Identifiable {
    let id: String
    let title: String
    let shortcut: String?
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void
}

struct SpaceCommandPalette: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var workspace: WorkspaceModel
    @FocusState private var isSearchFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0

    private var commands: [SpacePaletteCommand] {
        [
            command(
                "quick-directory",
                "快速切换目录",
                shortcut: "⌘O",
                systemImage: "folder"
            ) {
                dismiss()
                workspace.isCommandPalettePresented = true
            },
            command(
                "new-terminal",
                "新建终端",
                shortcut: "⌘T",
                systemImage: "plus.rectangle.on.rectangle",
                isEnabled: workspace.activeDirectory != nil
            ) {
                guard let directory = workspace.activeDirectory else { return }
                workspace.openNewTerminal(for: directory)
            },
            command(
                "split-right",
                "向右分屏",
                shortcut: "⌘D",
                systemImage: "rectangle.split.2x1",
                isEnabled: workspace.activeTerminalSession != nil
            ) {
                workspace.splitActiveTerminal(direction: .right)
            },
            command(
                "split-down",
                "向下分屏",
                shortcut: "⇧⌘D",
                systemImage: "rectangle.split.1x2",
                isEnabled: workspace.activeTerminalSession != nil
            ) {
                workspace.splitActiveTerminal(direction: .down)
            },
            command(
                "close-terminal",
                "关闭当前终端",
                shortcut: "⌘W",
                systemImage: "xmark.rectangle",
                isEnabled: workspace.activeTerminalSession != nil
            ) {
                workspace.requestCloseActiveTerminal()
            },
            command(
                "restore-terminal",
                "恢复最近关闭的终端",
                shortcut: "⇧⌘T",
                systemImage: "arrow.uturn.backward",
                isEnabled: workspace.canRestoreClosedTerminal
            ) {
                workspace.restoreLastClosedTerminal()
            },
            command(
                "find",
                "查找终端内容",
                shortcut: "⌘F",
                systemImage: "magnifyingglass",
                isEnabled: workspace.activeTerminalSession != nil
            ) {
                workspace.activeTerminalSession?.presentSearch()
            },
            command(
                "previous-terminal",
                "上一个终端标签",
                shortcut: "⇧⌘[",
                systemImage: "chevron.left",
                isEnabled: workspace.activeDirectoryTabs.count > 1
            ) {
                workspace.selectAdjacentTerminal(offset: -1)
            },
            command(
                "next-terminal",
                "下一个终端标签",
                shortcut: "⇧⌘]",
                systemImage: "chevron.right",
                isEnabled: workspace.activeDirectoryTabs.count > 1
            ) {
                workspace.selectAdjacentTerminal(offset: 1)
            },
            command(
                "add-folder",
                "添加文件夹…",
                shortcut: nil,
                systemImage: "folder.badge.plus"
            ) {
                workspace.chooseRootDirectory()
            },
        ]
    }

    private var filteredCommands: [SpacePaletteCommand] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .light ? 0.22 : 0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)

                    TextField("搜索命令", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($isSearchFocused)
                        .onSubmit(performSelectedCommand)
                        .onKeyPress(.downArrow) {
                            moveSelection(1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            moveSelection(-1)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            dismiss()
                            return .handled
                        }

                    Text("esc")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 50)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if filteredCommands.isEmpty {
                                Text("没有匹配的命令")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 260)
                            } else {
                                ForEach(Array(filteredCommands.enumerated()), id: \.element.id) {
                                    index, item in
                                    commandRow(item, index: index)
                                        .id(item.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selectedIndex) { _, index in
                        guard filteredCommands.indices.contains(index) else { return }
                        proxy.scrollTo(filteredCommands[index].id, anchor: .center)
                    }
                }

                Divider()

                HStack {
                    Text("\(filteredCommands.count) 个命令")
                    Spacer()
                    Text("↑↓ 选择   ↩ 执行")
                }
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.72))
                .padding(.horizontal, 14)
                .frame(height: 34)
            }
            .frame(width: 560, height: 420)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 28, y: 12)
            .onExitCommand(perform: dismiss)
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .task {
            await Task.yield()
            isSearchFocused = true
        }
    }

    private func commandRow(
        _ item: SpacePaletteCommand,
        index: Int
    ) -> some View {
        Button {
            perform(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(item.title)
                Spacer()
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(index == selectedIndex
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .onHover { if $0 { selectedIndex = index } }
    }

    private func command(
        _ id: String,
        _ title: String,
        shortcut: String?,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> SpacePaletteCommand {
        SpacePaletteCommand(
            id: id,
            title: title,
            shortcut: shortcut,
            systemImage: systemImage,
            isEnabled: isEnabled,
            action: action
        )
    }

    private func moveSelection(_ offset: Int) {
        guard !filteredCommands.isEmpty else { return }
        selectedIndex = min(
            max(selectedIndex + offset, 0),
            filteredCommands.count - 1
        )
    }

    private func performSelectedCommand() {
        guard filteredCommands.indices.contains(selectedIndex) else { return }
        perform(filteredCommands[selectedIndex])
    }

    private func perform(_ item: SpacePaletteCommand) {
        guard item.isEnabled else { return }
        dismiss()
        item.action()
    }

    private func dismiss() {
        workspace.isActionPalettePresented = false
    }
}
