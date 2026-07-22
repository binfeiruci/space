import Foundation

enum MemoFile {
    nonisolated static func append(
        _ text: String,
        workingDirectoryURL: URL,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        to fileURL: URL
    ) throws {
        guard !text.isEmpty else { return }

        let fileManager = FileManager.default
        let fileURL = fileURL.standardizedFileURL
        let parentURL = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: parentURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: parentURL.path]
            )
        }

        let exists = fileManager.fileExists(atPath: fileURL.path)
        var data = Data()

        if exists {
            let readHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? readHandle.close() }
            let fileSize = try readHandle.seekToEnd()
            if fileSize > 0 {
                let endingSize = min(fileSize, 2)
                try readHandle.seek(toOffset: fileSize - endingSize)
                let ending = try readHandle.read(upToCount: Int(endingSize))
                    ?? Data()
                data.append(contentsOf: newlinePadding(after: ending))
            }
        }

        let entry = memoEntry(
            text: text,
            workingDirectoryURL: workingDirectoryURL,
            date: date,
            timeZone: timeZone
        )
        data.append(contentsOf: entry.utf8)
        let padding = newlinePadding(after: data)
        data.append(contentsOf: padding)

        if exists {
            let writeHandle = try FileHandle(forWritingTo: fileURL)
            defer { try? writeHandle.close() }
            try writeHandle.seekToEnd()
            try writeHandle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    nonisolated private static func newlinePadding(after data: Data) -> [UInt8] {
        let newlineCount = data.suffix(2)
            .reversed()
            .prefix { $0 == 0x0A }
            .count
        return Array(repeating: 0x0A, count: 2 - newlineCount)
    }

    nonisolated private static func memoEntry(
        text: String,
        workingDirectoryURL: URL,
        date: Date,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timestamp = formatter.string(from: date)
        let workingDirectory = displayPath(for: workingDirectoryURL)
        return "---\n\(timestamp)\n"
            + "cwd: \(workingDirectory)\n\n"
            + text
    }

    nonisolated static func displayPath(
        for url: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let path = url.standardizedFileURL.path
        let homePath = homeDirectoryURL.standardizedFileURL.path
        if path == homePath { return "~" }

        let homePrefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(homePrefix) else { return path }
        return "~/" + String(path.dropFirst(homePrefix.count))
    }
}

actor MemoWriter {
    func append(
        _ text: String,
        workingDirectoryURL: URL,
        to fileURL: URL
    ) throws {
        try MemoFile.append(
            text,
            workingDirectoryURL: workingDirectoryURL,
            to: fileURL
        )
    }
}
