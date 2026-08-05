import AppKit
import Combine
import Foundation
import GhosttyTerminal
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var appearance: AppearancePreference {
        didSet {
            defaults.set(
                appearance.rawValue,
                forKey: Keys.appearance
            )
        }
    }
    private let defaults: any PreferencesStoring

    init(defaults: any PreferencesStoring = UserDefaults.standard) {
        self.defaults = defaults
        appearance = AppearancePreference(
            rawValue: defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? .system
    }

    private enum Keys {
        static let appearance = "application.appearance"
    }
}

@MainActor
struct GhosttyConfigurationFile {
    static let system = GhosttyConfigurationFile(
        configURL: { TerminalController.defaultConfigURL },
        editorURL: {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.TextEdit"
            )
        }
    )

    private let resolveConfigURL: () -> URL?
    private let resolveEditorURL: () -> URL?

    init(
        configURL: @escaping () -> URL?,
        editorURL: @escaping () -> URL?
    ) {
        resolveConfigURL = configURL
        resolveEditorURL = editorURL
    }

    var isAvailable: Bool {
        resolveEditorURL() != nil
    }

    func open() {
        guard let configURL = resolveConfigURL(),
              let editorURL = resolveEditorURL()
        else { return }
        NSWorkspace.shared.open(
            [configURL],
            withApplicationAt: editorURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
