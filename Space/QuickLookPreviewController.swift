import AppKit
import QuickLookUI

@MainActor
final class QuickLookPreviewController {
    static let shared = QuickLookPreviewController()

    private init() {}

    var isPresented: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible
    }

    func togglePreview(for url: URL) {
        if isPresented {
            closePreview()
            return
        }

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.orderFront(nil)
        refreshPanel(selecting: url)
    }

    func updatePreviewIfPresented(for url: URL) {
        guard isPresented else { return }
        refreshPanel(selecting: url)
    }

    func closePreview() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
    }

    private func refreshPanel(selecting url: URL) {
        (NSApp.delegate as? SpaceAppDelegate)?
            .refreshPreviewPanel(selecting: url)
    }
}
