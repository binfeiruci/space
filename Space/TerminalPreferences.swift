import Combine
import Foundation
import GhosttyTerminal
import SwiftUI

enum TerminalThemePreference: String, CaseIterable, Identifiable {
    case system
    case spaceDark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .spaceDark: "Space 深色"
        case .light: "浅色"
        }
    }
}

@MainActor
final class TerminalPreferences: ObservableObject {
    @Published var usesGhosttyConfig: Bool {
        didSet { defaults.set(usesGhosttyConfig, forKey: Keys.usesGhosttyConfig) }
    }
    @Published var ghosttyConfigPath: String {
        didSet { defaults.set(ghosttyConfigPath, forKey: Keys.ghosttyConfigPath) }
    }
    @Published var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Keys.fontFamily) }
    }
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }
    @Published var shellPath: String {
        didSet { defaults.set(shellPath, forKey: Keys.shellPath) }
    }
    @Published var theme: TerminalThemePreference {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        usesGhosttyConfig = defaults.object(forKey: Keys.usesGhosttyConfig)
            as? Bool ?? false
        ghosttyConfigPath = defaults.string(forKey: Keys.ghosttyConfigPath)
            ?? "~/.config/ghostty/config"
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? "SF Mono"
        let savedFontSize = defaults.double(forKey: Keys.fontSize)
        fontSize = savedFontSize == 0
            ? 13
            : min(max(savedFontSize, 9), 32)
        shellPath = defaults.string(forKey: Keys.shellPath) ?? ""
        theme = TerminalThemePreference(
            rawValue: defaults.string(forKey: Keys.theme) ?? ""
        ) ?? .spaceDark
    }

    var resolvedGhosttyConfigURL: URL? {
        guard usesGhosttyConfig else { return nil }
        let path = NSString(string: ghosttyConfigPath)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var terminalConfiguration: TerminalConfiguration {
        guard resolvedGhosttyConfigURL == nil else { return .init() }
        return TerminalConfiguration { builder in
            let family = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
            if !family.isEmpty {
                builder.withFontFamily(family)
            }
            builder.withFontSize(Float(min(max(fontSize, 9), 32)))
            builder.withWindowPaddingX(10)
            builder.withWindowPaddingY(8)

            let shell = NSString(string: shellPath)
                .expandingTildeInPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !shell.isEmpty {
                builder.withCustom("command", shell)
            }
        }
    }

    var terminalTheme: TerminalTheme {
        guard resolvedGhosttyConfigURL == nil else { return .init() }
        switch theme {
        case .system:
            return .default
        case .spaceDark:
            let configuration = TerminalConfiguration { builder in
                builder.withBackground("#101312")
                builder.withForeground("#DCE5DE")
                builder.withCursorColor("#72D49B")
                builder.withSelectionBackground("#315E48")
            }
            return TerminalTheme(light: configuration, dark: configuration)
        case .light:
            return TerminalTheme(light: .alabaster, dark: .alabaster)
        }
    }

    func resetCustomAppearance() {
        fontFamily = "SF Mono"
        fontSize = 13
        shellPath = ""
        theme = .spaceDark
    }

    private enum Keys {
        static let usesGhosttyConfig = "terminal.usesGhosttyConfig"
        static let ghosttyConfigPath = "terminal.ghosttyConfigPath"
        static let fontFamily = "terminal.fontFamily"
        static let fontSize = "terminal.fontSize"
        static let shellPath = "terminal.shellPath"
        static let theme = "terminal.theme"
    }
}

struct TerminalSettingsView: View {
    @ObservedObject var preferences: TerminalPreferences

    var body: some View {
        Form {
            Section("Ghostty") {
                Toggle("读取 Ghostty 配置文件", isOn: $preferences.usesGhosttyConfig)
                TextField("配置文件路径", text: $preferences.ghosttyConfigPath)
                    .disabled(!preferences.usesGhosttyConfig)

                if preferences.usesGhosttyConfig,
                   preferences.resolvedGhosttyConfigURL == nil {
                    Label("配置文件不存在，将使用自定义设置", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("自定义终端") {
                TextField("字体", text: $preferences.fontFamily)
                HStack {
                    Text("字号")
                    Slider(value: $preferences.fontSize, in: 9 ... 32, step: 1)
                    Text("\(Int(preferences.fontSize))")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                Picker("主题", selection: $preferences.theme) {
                    ForEach(TerminalThemePreference.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                TextField("默认 Shell（留空使用登录 Shell）", text: $preferences.shellPath)
                Text("工作目录始终使用左侧选中的目录。Shell 或配置来源变更从新终端开始生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("恢复默认设置") {
                    preferences.resetCustomAppearance()
                }
            }
            .disabled(preferences.resolvedGhosttyConfigURL != nil)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 390)
    }
}
