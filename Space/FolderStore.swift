import Foundation

struct FolderStore {
    private static let folderPathsKey = "folders.paths.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func restore() -> [URL] {
        guard let paths = defaults.stringArray(
            forKey: Self.folderPathsKey
        ) else { return [] }

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

    func persist(_ urls: [URL]) {
        defaults.set(urls.map(\.path), forKey: Self.folderPathsKey)
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
}
