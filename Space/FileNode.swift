import Combine
import Foundation

@MainActor
final class FileNode: ObservableObject, Identifiable {
    let url: URL
    let isDirectory: Bool
    @Published private(set) var children: [FileNode] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private var hasLoadedChildren = false
    private var hasCompletedInitialLoad = false
    private var reloadGeneration = 0
    private var reloadTask: Task<Void, Never>?

    var id: String { url.path }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    func loadChildren() {
        guard isDirectory, !hasLoadedChildren else { return }
        hasLoadedChildren = true
        scheduleReload()
    }

    func reloadLoadedTree(affectedPaths: Set<String>? = nil) async {
        guard isDirectory, hasLoadedChildren,
              isAffected(by: affectedPaths) else { return }

        reloadTask?.cancel()
        reloadTask = nil
        await readAndApplyChildren()
        guard !Task.isCancelled else { return }

        for child in children where child.isDirectory {
            await child.reloadLoadedTree(affectedPaths: affectedPaths)
            if Task.isCancelled { return }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.readAndApplyChildren()
        }
    }

    private func readAndApplyChildren() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let isInitialLoad = !hasCompletedInitialLoad
        if isInitialLoad {
            if !isLoading {
                isLoading = true
            }
            if errorMessage != nil {
                errorMessage = nil
            }
        }
        let directoryURL = url
        let result = await Task.detached(priority: .utility) {
            Self.readDirectory(directoryURL)
        }.value
        guard generation == reloadGeneration, !Task.isCancelled else { return }
        if isLoading {
            isLoading = false
        }

        guard !result.failed else {
            // A transient watcher error should not replace an already-rendered
            // subtree. Keep the last successful snapshot on background reloads.
            if isInitialLoad, errorMessage != "无法读取目录" {
                errorMessage = "无法读取目录"
            }
            return
        }
        hasCompletedInitialLoad = true
        if errorMessage != nil {
            errorMessage = nil
        }

        let existingNodes = Dictionary(
            uniqueKeysWithValues: children.map {
                ($0.url.standardizedFileURL.path, $0)
            }
        )
        let nextChildren = result.entries.map { entry in
            let path = entry.url.standardizedFileURL.path
            if let existing = existingNodes[path],
               existing.isDirectory == entry.canExpand {
                return existing
            }
            return FileNode(url: entry.url, isDirectory: entry.canExpand)
        }
        let childrenChanged = children.count != nextChildren.count
            || zip(children, nextChildren).contains { $0 !== $1 }
        if childrenChanged {
            children = nextChildren
        }
    }

    private func isAffected(by paths: Set<String>?) -> Bool {
        guard let paths else { return true }
        let nodePath = url.standardizedFileURL.path
        return paths.contains { changedPath in
            changedPath == nodePath
                || changedPath.hasPrefix(nodePath + "/")
                || nodePath.hasPrefix(changedPath + "/")
        }
    }

    nonisolated private static func readDirectory(
        _ url: URL
    ) -> DirectoryReadResult {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            let entries = urls.compactMap { childURL -> DirectoryReadEntry? in
                guard let values = try? childURL.resourceValues(forKeys: keys) else {
                    return nil
                }
                return DirectoryReadEntry(
                    url: childURL,
                    canExpand: values.isDirectory == true
                        && values.isSymbolicLink != true
                )
            }
            .sorted { left, right in
                if left.canExpand != right.canExpand {
                    return left.canExpand
                }
                return left.url.lastPathComponent.localizedStandardCompare(
                    right.url.lastPathComponent
                ) == .orderedAscending
            }
            return DirectoryReadResult(entries: entries, failed: false)
        } catch {
            return DirectoryReadResult(entries: [], failed: true)
        }
    }
}

private struct DirectoryReadEntry: Sendable {
    let url: URL
    let canExpand: Bool
}

private struct DirectoryReadResult: Sendable {
    let entries: [DirectoryReadEntry]
    let failed: Bool
}
