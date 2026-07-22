import AppKit
import Foundation

private struct PasteboardSnapshot {
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        } ?? []
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let pasteboardItems = items.map { values in
            let item = NSPasteboardItem()
            for value in values {
                item.setData(value.data, forType: value.type)
            }
            return item
        }
        if !pasteboardItems.isEmpty {
            pasteboard.writeObjects(pasteboardItems)
        }
    }
}

enum TerminalSelectionReader {
    static func selection(
        from pasteboard: NSPasteboard,
        copyingSelection: () -> Bool
    ) -> String? {
        let snapshot = PasteboardSnapshot(pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        guard copyingSelection() else { return nil }
        return pasteboard.string(forType: .string).flatMap {
            $0.isEmpty ? nil : $0
        }
    }
}
