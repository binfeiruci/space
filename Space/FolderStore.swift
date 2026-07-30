import Foundation

struct FolderWorkspaceState {
    let openFolders: [URL]
    let activeFolder: URL?
}

struct FolderStore {
    private static let folderPathsKey = "folders.paths.v1"
    private static let openFolderPathsKey = "folders.openPaths.v1"
    private static let activeFolderPathKey = "folders.activePath.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func restoreRecentFolders(limit: Int) -> [URL] {
        Array(restoreFolders(forKey: Self.folderPathsKey).prefix(limit))
    }

    func persistRecentFolders(_ urls: [URL]) {
        defaults.set(urls.map(\.path), forKey: Self.folderPathsKey)
    }

    func restoreWorkspace() -> FolderWorkspaceState {
        let activeFolder = defaults.string(
            forKey: Self.activeFolderPathKey
        ).flatMap {
            Self.validFolderURL(URL(fileURLWithPath: $0))
        }
        return FolderWorkspaceState(
            openFolders: restoreFolders(forKey: Self.openFolderPathsKey),
            activeFolder: activeFolder
        )
    }

    func persistWorkspace(_ state: FolderWorkspaceState) {
        defaults.set(
            state.openFolders.map(\.path),
            forKey: Self.openFolderPathsKey
        )
        if let activeFolder = state.activeFolder {
            defaults.set(
                activeFolder.standardizedFileURL.path,
                forKey: Self.activeFolderPathKey
            )
        } else {
            defaults.removeObject(forKey: Self.activeFolderPathKey)
        }
    }

    static func validFolderURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func contains(_ url: URL, in folder: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        let descendantPrefix = folderPath == "/" ? "/" : folderPath + "/"
        return path == folderPath || path.hasPrefix(descendantPrefix)
    }

    private func restoreFolders(forKey key: String) -> [URL] {
        guard let paths = defaults.stringArray(forKey: key) else { return [] }

        var folders: [URL] = []
        for path in paths {
            guard let folderURL = Self.validFolderURL(
                URL(fileURLWithPath: path)
            ), !folders.contains(where: {
                $0.standardizedFileURL.path == folderURL.path
            }) else { continue }
            folders.append(folderURL)
        }
        return folders
    }
}
