import Foundation

enum FolderMemoFile {
    static let filename = ".memo"

    static func append(
        _ text: String,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        in folderURL: URL
    ) throws {
        guard !text.isEmpty else { return }

        let fileURL = folderURL.appendingPathComponent(filename)
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: fileURL.path)
        var data = Data()

        if exists {
            let attributes = try fileManager.attributesOfItem(
                atPath: fileURL.path
            )
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if fileSize > 0 {
                let readHandle = try FileHandle(forReadingFrom: fileURL)
                defer { try? readHandle.close() }
                let endingSize = min(fileSize, 2)
                try readHandle.seek(toOffset: fileSize - endingSize)
                let ending = try readHandle.read(upToCount: Int(endingSize))
                    ?? Data()
                let newlineCount = ending.reversed().prefix { $0 == 0x0A }.count
                for _ in newlineCount ..< 2 {
                    data.append(0x0A)
                }
            }
        }

        let entry = memoEntry(
            text: text,
            date: date,
            timeZone: timeZone
        )
        data.append(contentsOf: entry.utf8)
        let newlineCount = data.reversed().prefix { $0 == 0x0A }.count
        for _ in newlineCount ..< 2 {
            data.append(0x0A)
        }

        if exists {
            let writeHandle = try FileHandle(forWritingTo: fileURL)
            defer { try? writeHandle.close() }
            try writeHandle.seekToEnd()
            try writeHandle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private static func memoEntry(
        text: String,
        date: Date,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "---\n\(formatter.string(from: date))\n\n\(text)"
    }
}

actor FolderMemoWriter {
    func append(_ text: String, in folderURL: URL) throws {
        try FolderMemoFile.append(text, in: folderURL)
    }
}
