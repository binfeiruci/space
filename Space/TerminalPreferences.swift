import Combine
import Foundation
import GhosttyTerminal
import SwiftUI
import UniformTypeIdentifiers

enum ApplicationAppearancePreference: String, CaseIterable, Identifiable {
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
final class TerminalPreferences: ObservableObject {
    static let ghosttyConfigCandidatePaths = [
        "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        "~/Library/Application Support/com.mitchellh.ghostty/config",
        "~/.config/ghostty/config.ghostty",
        "~/.config/ghostty/config",
    ]

    static var defaultGhosttyConfigPath: String {
        ghosttyConfigCandidatePaths.first {
            resolvedConfigURL(for: $0) != nil
        } ?? ghosttyConfigCandidatePaths[0]
    }

    @Published var applicationAppearance: ApplicationAppearancePreference {
        didSet {
            defaults.set(
                applicationAppearance.rawValue,
                forKey: Keys.applicationAppearance
            )
        }
    }
    @Published var ghosttyConfigPath: String {
        didSet { defaults.set(ghosttyConfigPath, forKey: Keys.ghosttyConfigPath) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        applicationAppearance = ApplicationAppearancePreference(
            rawValue: defaults.string(forKey: Keys.applicationAppearance) ?? ""
        ) ?? .system
        let savedPath = defaults.string(forKey: Keys.ghosttyConfigPath)
        if let savedPath,
           savedPath == "~/.config/ghostty/config",
           Self.resolvedConfigURL(for: savedPath) == nil {
            ghosttyConfigPath = Self.defaultGhosttyConfigPath
            defaults.set(
                ghosttyConfigPath,
                forKey: Keys.ghosttyConfigPath
            )
        } else {
            ghosttyConfigPath = savedPath ?? Self.defaultGhosttyConfigPath
        }
    }

    var resolvedGhosttyConfigURL: URL? {
        Self.resolvedConfigURL(for: ghosttyConfigPath)
    }

    private static func resolvedConfigURL(for configPath: String) -> URL? {
        let path = NSString(string: configPath)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    func useDefaultGhosttyConfigPath() {
        ghosttyConfigPath = Self.defaultGhosttyConfigPath
    }

    private enum Keys {
        static let applicationAppearance = "application.appearance"
        static let ghosttyConfigPath = "terminal.ghosttyConfigPath"
    }
}

struct TerminalSettingsView: View {
    @ObservedObject var preferences: TerminalPreferences
    @State private var isConfigFileImporterPresented = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Color Scheme", selection: $preferences.applicationAppearance) {
                    ForEach(ApplicationAppearancePreference.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Terminal Configuration") {
                HStack {
                    TextField(
                        "Configuration File",
                        text: $preferences.ghosttyConfigPath
                    )

                    Button("Choose…") {
                        isConfigFileImporterPresented = true
                    }
                }

                Button("Use Ghostty Configuration") {
                    preferences.useDefaultGhosttyConfigPath()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 240)
        .preferredColorScheme(preferences.applicationAppearance.colorScheme)
        .fileImporter(
            isPresented: $isConfigFileImporterPresented,
            allowedContentTypes: [.data]
        ) { result in
            guard case let .success(url) = result else { return }
            preferences.ghosttyConfigPath = url.standardizedFileURL.path
        }
    }
}
