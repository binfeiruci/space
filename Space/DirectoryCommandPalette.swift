import AppKit
import Foundation
import SwiftUI

struct WorkspaceDirectoryEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let relativePath: String
    let normalizedName: String
    let normalizedRelativePath: String
    let normalizedAbsolutePath: String

    nonisolated init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
        normalizedName = Self.normalize(url.lastPathComponent)
        normalizedRelativePath = Self.normalize(relativePath)
        normalizedAbsolutePath = Self.normalize(url.path)
    }

    var id: String { url.standardizedFileURL.path }

    private nonisolated static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        ).lowercased()
    }
}

struct WorkspaceDirectoryScanResult: Sendable {
    let entries: [WorkspaceDirectoryEntry]
    let isTruncated: Bool
}

enum WorkspaceDirectorySearch {
    nonisolated private static let ignoredDirectoryNames: Set<String> = [
        "build",
        "carthage",
        "DerivedData",
        "dist",
        "node_modules",
        "pods",
        "target",
        "thirdparty",
        "vendor",
        "venv",
    ]
    .map { $0.lowercased() }
    .reduce(into: Set<String>()) { $0.insert($1) }

    nonisolated static func scan(
        rootURL: URL,
        maximumCount: Int = 20_000,
        maximumDepth: Int = 8
    ) -> [WorkspaceDirectoryEntry] {
        scanResult(
            rootURL: rootURL,
            maximumCount: maximumCount,
            maximumDepth: maximumDepth
        ).entries
    }

    nonisolated static func scanResult(
        rootURL: URL,
        maximumCount: Int = 20_000,
        maximumDepth: Int = 8
    ) -> WorkspaceDirectoryScanResult {
        scanBreadthFirst(
            rootURL: rootURL,
            maximumCount: maximumCount,
            maximumDepth: maximumDepth
        )
    }

    nonisolated private static func scanBreadthFirst(
        rootURL: URL,
        maximumCount: Int,
        maximumDepth: Int
    ) -> WorkspaceDirectoryScanResult {
        let root = rootURL.standardizedFileURL
        var entries = [entry(for: root, root: root)]
        let countLimit = max(maximumCount, 1)
        var isTruncated = false
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var queueIndex = 0

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isPackageKey,
        ]
        while queueIndex < queue.count {
            if Task.isCancelled { break }
            let current = queue[queueIndex]
            queueIndex += 1

            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: current.url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let childDirectories = urls.compactMap { url -> URL? in
                guard let values = try? url.resourceValues(forKeys: resourceKeys),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      values.isPackage != true,
                      !ignoredDirectoryNames.contains(
                        url.lastPathComponent.lowercased()
                      ) else {
                    return nil
                }
                return url.standardizedFileURL
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }

            let childDepth = current.depth + 1
            for childURL in childDirectories {
                if Task.isCancelled { break }
                guard childDepth <= maximumDepth else {
                    isTruncated = true
                    continue
                }
                guard entries.count < countLimit else {
                    return WorkspaceDirectoryScanResult(
                        entries: entries,
                        isTruncated: true
                    )
                }
                entries.append(entry(for: childURL, root: root))
                queue.append((childURL, childDepth))
            }
        }

        return WorkspaceDirectoryScanResult(
            entries: entries,
            isTruncated: isTruncated
        )
    }

    nonisolated static func topMatches(
        _ entries: [WorkspaceDirectoryEntry],
        query: String,
        limit: Int = 20,
        preferredPaths: Set<String> = []
    ) -> [WorkspaceDirectoryEntry] {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty, limit > 0 else { return [] }

        var top: [(entry: WorkspaceDirectoryEntry, score: Int)] = []
        top.reserveCapacity(limit)

        for entry in entries {
            if Task.isCancelled { break }
            guard var score = matchScore(entry, tokens: tokens) else { continue }
            if preferredPaths.contains(entry.url.standardizedFileURL.path) {
                score += 10_000
            }

            let insertionIndex = top.firstIndex { candidate in
                if score != candidate.score { return score > candidate.score }
                return entry.relativePath.localizedStandardCompare(
                    candidate.entry.relativePath
                ) == .orderedAscending
            } ?? top.count

            guard insertionIndex < limit else { continue }
            top.insert((entry, score), at: insertionIndex)
            if top.count > limit {
                top.removeLast()
            }
        }

        return top.map(\.entry)
    }

    private nonisolated static func matchScore(
        _ entry: WorkspaceDirectoryEntry,
        tokens: [String]
    ) -> Int? {
        var total = 0

        for token in tokens {
            let nameScore = fuzzyScore(
                token,
                candidate: entry.normalizedName
            ).map { $0 + 320 }
            let relativeScore = fuzzyScore(
                token,
                candidate: entry.normalizedRelativePath
            )
            let absoluteScore = token.hasPrefix("/")
                ? fuzzyScore(token, candidate: entry.normalizedAbsolutePath)
                    .map { $0 - 80 }
                : nil
            let best = [nameScore, relativeScore, absoluteScore]
                .compactMap { $0 }
                .max()
            guard let best else { return nil }
            total += best
        }

        let depth = entry.relativePath.reduce(into: 0) { count, character in
            if character == "/" { count += 1 }
        }
        total -= depth * 8
        total -= min(entry.relativePath.count / 4, 80)
        return total
    }

    private nonisolated static func fuzzyScore(
        _ token: String,
        candidate: String
    ) -> Int? {
        guard !token.isEmpty, !candidate.isEmpty else { return nil }
        let candidateLength = candidate.count

        if candidate == token {
            return 2_000 - candidateLength
        }
        if candidate.hasPrefix(token) {
            return 1_700 - max(candidateLength - token.count, 0)
        }
        if let range = candidate.range(of: token) {
            let offset = candidate.distance(
                from: candidate.startIndex,
                to: range.lowerBound
            )
            let atBoundary: Bool
            if range.lowerBound == candidate.startIndex {
                atBoundary = true
            } else {
                let previousIndex = candidate.index(before: range.lowerBound)
                atBoundary = isSeparator(candidate[previousIndex])
            }
            return 1_350
                + (atBoundary ? 180 : 0)
                - offset * 4
                - max(candidateLength - token.count, 0)
        }

        let tokenCharacters = Array(token)
        var tokenIndex = 0
        var previousCharacter: Character?
        var firstMatchOffset: Int?
        var lastMatchOffset: Int?
        var consecutiveCount = 0
        var score = 0

        for (offset, character) in candidate.enumerated() {
            guard tokenIndex < tokenCharacters.count else { break }
            if character == tokenCharacters[tokenIndex] {
                if firstMatchOffset == nil { firstMatchOffset = offset }
                score += 100

                if offset == 0 || previousCharacter.map(isSeparator) == true {
                    score += 90
                }

                if let lastMatchOffset, lastMatchOffset + 1 == offset {
                    consecutiveCount += 1
                    score += 45 + min(consecutiveCount, 4) * 12
                } else {
                    if let lastMatchOffset {
                        score -= min((offset - lastMatchOffset - 1) * 3, 36)
                    }
                    consecutiveCount = 0
                }

                lastMatchOffset = offset
                tokenIndex += 1
            }
            previousCharacter = character
        }

        guard tokenIndex == tokenCharacters.count,
              let firstMatchOffset else { return nil }
        score -= firstMatchOffset * 5
        score -= max(candidateLength - tokenCharacters.count, 0)
        return score
    }

    private nonisolated static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        ).lowercased()
    }

    private nonisolated static func isSeparator(_ character: Character) -> Bool {
        switch character {
        case "/", "_", "-", ".", " ":
            true
        default:
            false
        }
    }

    private nonisolated static func entry(
        for url: URL,
        root: URL
    ) -> WorkspaceDirectoryEntry {
        let rootPath = root.path
        let path = url.path
        let relativePath: String
        if path == rootPath {
            relativePath = "."
        } else if path.hasPrefix(rootPath + "/") {
            relativePath = String(path.dropFirst(rootPath.count + 1))
        } else {
            relativePath = path
        }
        return WorkspaceDirectoryEntry(url: url, relativePath: relativePath)
    }
}

struct DirectoryCommandPalette: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var workspace: WorkspaceModel
    @FocusState private var isSearchFocused: Bool
    @State private var query = ""
    @State private var displayedResults: [WorkspaceDirectoryEntry] = []
    @State private var selectedIndex = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var scanTask: Task<Void, Never>?
    @State private var scannedEntries: [WorkspaceDirectoryEntry] = []
    @State private var isScanning = false
    @State private var isScanTruncated = false

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .light ? 0.22 : 0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("输入目录名或路径", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($isSearchFocused)
                        .onSubmit(activateSelectedDirectory)
                        .onKeyPress(.downArrow) {
                            moveSelection(.down)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            moveSelection(.up)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            dismiss()
                            return .handled
                        }

                    Text("esc")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                .padding(.horizontal, 16)
                .frame(height: 50)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if displayedResults.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "folder.badge.questionmark")
                                        .font(.title2)
                                        .foregroundStyle(.tertiary)
                                    Text(isScanning
                                        ? "正在扫描目录…"
                                        : "没有匹配的目录")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 260)
                            } else {
                                ForEach(
                                    Array(displayedResults.enumerated()),
                                    id: \.element.id
                                ) {
                                    index, entry in
                                    directoryRow(entry, index: index)
                                        .id(entry.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selectedIndex) { _, index in
                        guard displayedResults.indices.contains(index) else {
                            return
                        }
                        proxy.scrollTo(displayedResults[index].id, anchor: .center)
                    }
                }

                Divider()

                HStack {
                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在扫描目录")
                    } else if isScanTruncated {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("扫描已达到数量或深度上限，结果可能不完整")
                    } else {
                        Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                            ? "当前及已打开的目录"
                            : "\(displayedResults.count) 个匹配目录")
                    }

                    Spacer()

                    Text("↑↓ 选择   ↩ 打开")
                }
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.72))
                .padding(.horizontal, 14)
                .frame(height: 34)
            }
            .frame(width: 620, height: 430)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        Color.primary.opacity(colorScheme == .light ? 0.14 : 0.22),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: .black.opacity(colorScheme == .light ? 0.22 : 0.5),
                radius: 28,
                y: 12
            )
            .onMoveCommand(perform: moveSelection)
            .onExitCommand(perform: dismiss)
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            refreshDisplayedResults()
        }
        .task {
            refreshDisplayedResults()
            startDirectoryScan()
        }
        .task {
            await Task.yield()
            isSearchFocused = true
        }
        .onDisappear {
            searchTask?.cancel()
            scanTask?.cancel()
        }
    }

    private func directoryRow(
        _ entry: WorkspaceDirectoryEntry,
        index: Int
    ) -> some View {
        let isSelected = index == selectedIndex
        let hasTerminal = workspace.hasTerminalSession(exactlyAt: entry.url)

        return Button {
            activate(entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: hasTerminal ? "terminal.fill" : "folder")
                    .frame(width: 18)
                    .foregroundStyle(hasTerminal ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(workspace.rootURLs.count > 1
                        ? entry.url.path
                        : entry.relativePath == "."
                            ? entry.url.path
                            : entry.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if hasTerminal {
                    Text("已有终端")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                        ? Color.accentColor.opacity(colorScheme == .light ? 0.16 : 0.24)
                        : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        isSelected
                            ? Color.accentColor.opacity(
                                colorScheme == .light ? 0.34 : 0.46
                            )
                            : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedIndex = index }
        }
    }

    private func refreshDisplayedResults() {
        searchTask?.cancel()
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !searchQuery.isEmpty else {
            displayedResults = immediateDirectoryEntries()
            selectedIndex = min(
                selectedIndex,
                max(displayedResults.count - 1, 0)
            )
            return
        }

        displayedResults = []
        let source = scannedEntries
        var preferredPaths = Set(workspace.terminalSessions.map {
            $0.directory.standardizedFileURL.path
        })
        if let activeDirectory = workspace.activeDirectory {
            preferredPaths.insert(activeDirectory.standardizedFileURL.path)
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }

            let filterTask = Task.detached(priority: .userInitiated) {
                WorkspaceDirectorySearch.topMatches(
                    source,
                    query: searchQuery,
                    limit: 20,
                    preferredPaths: preferredPaths
                )
            }
            let filtered = await withTaskCancellationHandler {
                await filterTask.value
            } onCancel: {
                filterTask.cancel()
            }
            guard !Task.isCancelled,
                  query.trimmingCharacters(in: .whitespacesAndNewlines)
                    == searchQuery else { return }
            displayedResults = filtered
            selectedIndex = 0
        }
    }

    private func startDirectoryScan() {
        scanTask?.cancel()
        scannedEntries = []
        isScanTruncated = false
        let roots = workspace.rootURLs
        guard !roots.isEmpty else {
            isScanning = false
            return
        }
        isScanning = true

        scanTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                var entries: [WorkspaceDirectoryEntry] = []
                var isTruncated = false
                for root in roots {
                    guard !Task.isCancelled else { break }
                    let result = WorkspaceDirectorySearch.scanResult(rootURL: root)
                    entries.append(contentsOf: result.entries)
                    isTruncated = isTruncated || result.isTruncated
                }
                return WorkspaceDirectoryScanResult(
                    entries: entries,
                    isTruncated: isTruncated
                )
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            scannedEntries = result.entries
            isScanTruncated = result.isTruncated
            isScanning = false
            refreshDisplayedResults()
        }
    }

    private func immediateDirectoryEntries() -> [WorkspaceDirectoryEntry] {
        var urls: [URL] = []
        if let activeDirectory = workspace.activeDirectory {
            urls.append(activeDirectory.standardizedFileURL)
        }
        urls.append(contentsOf: workspace.terminalSessions.reversed().map {
            $0.directory.standardizedFileURL
        })

        var seen = Set<String>()
        return urls.compactMap { url in
            guard let root = workspace.rootDirectory(containing: url),
                  seen.insert(url.path).inserted else {
                return nil
            }
            let relativePath = url.path == root.path
                ? "."
                : String(url.path.dropFirst(root.path.count + 1))
            return WorkspaceDirectoryEntry(url: url, relativePath: relativePath)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !displayedResults.isEmpty else { return }
        switch direction {
        case .down:
            selectedIndex = min(selectedIndex + 1, displayedResults.count - 1)
        case .up:
            selectedIndex = max(selectedIndex - 1, 0)
        default:
            break
        }
    }

    private func activateSelectedDirectory() {
        guard displayedResults.indices.contains(selectedIndex) else { return }
        activate(displayedResults[selectedIndex])
    }

    private func activate(_ entry: WorkspaceDirectoryEntry) {
        workspace.activateTerminal(for: entry.url)
        dismiss()
    }

    private func dismiss() {
        workspace.isCommandPalettePresented = false
    }
}
