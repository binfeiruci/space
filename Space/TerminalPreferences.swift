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
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
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
            Section("外观") {
                Picker("配色模式", selection: $preferences.applicationAppearance) {
                    ForEach(ApplicationAppearancePreference.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("终端配置") {
                HStack {
                    TextField(
                        "配置文件",
                        text: $preferences.ghosttyConfigPath
                    )

                    Button("选择…") {
                        isConfigFileImporterPresented = true
                    }
                }

                Button("使用 Ghostty 配置") {
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
