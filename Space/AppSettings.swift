import Combine
import Foundation
import GhosttyTerminal
import SwiftUI
import UniformTypeIdentifiers

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
    static let ghosttyConfigCandidatePaths = [
        "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        "~/Library/Application Support/com.mitchellh.ghostty/config",
        "~/.config/ghostty/config.ghostty",
        "~/.config/ghostty/config",
    ]

    static var defaultGhosttyConfigPath: String {
        ghosttyConfigCandidatePaths.first {
            resolvedConfigURL(for: $0) != nil
        } ?? ""
    }

    @Published var appearance: AppearancePreference {
        didSet {
            defaults.set(
                appearance.rawValue,
                forKey: Keys.appearance
            )
        }
    }
    @Published var ghosttyConfigPath: String {
        didSet { defaults.set(ghosttyConfigPath, forKey: Keys.ghosttyConfigPath) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearancePreference(
            rawValue: defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? .system
        ghosttyConfigPath = defaults.string(forKey: Keys.ghosttyConfigPath)
            ?? Self.defaultGhosttyConfigPath
    }

    var resolvedGhosttyConfigURL: URL? {
        Self.resolvedConfigURL(for: ghosttyConfigPath)
    }

    var isGhosttyConfigPathValid: Bool {
        Self.normalizedPath(ghosttyConfigPath).isEmpty
            || resolvedGhosttyConfigURL != nil
    }

    private static func resolvedConfigURL(for configPath: String) -> URL? {
        let path = normalizedPath(configPath)
        var isDirectory: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(
                  atPath: path,
                  isDirectory: &isDirectory
              ),
              !isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }

    var ghosttyConfigSource: TerminalController.ConfigSource {
        resolvedGhosttyConfigURL
            .map { .file($0.path) } ?? .none
    }

    private static func normalizedPath(_ value: String) -> String {
        NSString(string: value)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum Keys {
        static let appearance = "application.appearance"
        static let ghosttyConfigPath = "terminal.ghosttyConfigPath"
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var isConfigFileImporterPresented = false
    @State private var configImportError: ConfigImportError?

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearancePreference.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    TextField(
                        "Terminal Configuration",
                        text: $settings.ghosttyConfigPath,
                        prompt: Text("Built-in defaults")
                    )
                    .help("Changes apply to new tabs.")

                    Button("Choose…") {
                        isConfigFileImporterPresented = true
                    }
                }

                if !settings.isGhosttyConfigPathValid {
                    Label(
                        "Configuration file not found.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .preferredColorScheme(settings.appearance.colorScheme)
        .fileImporter(
            isPresented: $isConfigFileImporterPresented,
            allowedContentTypes: [.data]
        ) { result in
            switch result {
            case let .success(url):
                settings.ghosttyConfigPath = url.standardizedFileURL.path
            case let .failure(error):
                guard (error as NSError).code != NSUserCancelledError else {
                    return
                }
                configImportError = ConfigImportError(
                    message: error.localizedDescription
                )
            }
        }
        .alert(item: $configImportError) { error in
            Alert(
                title: Text("Unable to Choose Configuration File"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct ConfigImportError: Identifiable {
    let id = UUID()
    let message: String
}
