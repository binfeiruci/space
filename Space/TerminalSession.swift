import Combine
import Darwin
import Foundation
import GhosttyTerminal

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let workingDirectoryURL: URL
    let terminal: TerminalViewState
    let defaultShellName: String
    var terminalView: TerminalView?
    weak var terminalContainer: SpaceTerminalContainerView?
    @Published var isSearchPresented = false
    @Published var searchQuery = ""
    @Published private(set) var terminalFocusRequest = 0
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var currentProcessName: String?
    @Published private var processWorkingDirectory: String?

    init(
        workingDirectoryURL: URL,
        defaultShellPath: String? = nil,
        surfaceContext: TerminalSurfaceContext = .window
    ) {
        self.workingDirectoryURL = workingDirectoryURL.standardizedFileURL
        let shellPath = defaultShellPath ?? Self.loginShellPath
        defaultShellName = Self.processName(
            from: shellPath
        ) ?? "shell"

        terminal = TerminalViewState(
            configSource: .defaultFiles,
            theme: TerminalTheme()
        )
        terminal.configuration = TerminalSurfaceOptions(
            workingDirectory: workingDirectoryURL.path,
            context: surfaceContext
        )
    }

    var processInspectionRequest: TerminalProcessInspector.Request? {
        guard let terminalView,
              let processGroupID = terminalView.foregroundPid,
              processGroupID > 0,
              let ttyName = terminalView.ttyName
        else { return nil }
        return TerminalProcessInspector.Request(
            sessionID: id,
            processGroupID: processGroupID,
            ttyName: ttyName
        )
    }

    func updateProcessState(_ state: TerminalProcessState?) {
        let name = state?.name
        if currentProcessName != name {
            currentProcessName = name
        }

        if let workingDirectory = nonEmpty(state?.workingDirectory),
           processWorkingDirectory != workingDirectory {
            processWorkingDirectory = workingDirectory
        }
    }

    var currentWorkingDirectoryURL: URL {
        directoryURL(from: processWorkingDirectory)
            ?? directoryURL(from: terminal.workingDirectory)
            ?? workingDirectoryURL
    }

    var runningForegroundProcessName: String? {
        guard let currentProcessName,
              currentProcessName != defaultShellName
        else { return nil }
        return currentProcessName
    }

    func requestTerminalFocus() {
        terminalFocusRequest &+= 1
    }

    func presentSearch() {
        isSearchPresented = true
        searchFocusRequest &+= 1
    }

    func updateSearch(_ query: String) {
        _ = terminalView?.performBindingAction(
            TerminalSearchAction.update(query: query)
        )
    }

    func navigateSearch(forward: Bool) {
        guard isSearchPresented else { return }
        _ = terminalView?.performBindingAction(
            TerminalSearchAction.navigate(forward: forward)
        )
    }

    func dismissSearch() {
        guard isSearchPresented else { return }
        _ = terminalView?.performBindingAction(TerminalSearchAction.end)
        isSearchPresented = false
    }

    func displayTitle(terminalTitle: String = "") -> String {
        let processName = currentProcessName.flatMap(Self.processName(from:))
        guard !isShellProcess(processName) else {
            return currentDirectoryName
        }

        let title = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return processName ?? currentDirectoryName
        }
        if let pathURL = Self.fileURL(fromTitle: title) {
            return processName ?? Self.directoryDisplayName(for: pathURL)
        }
        return title
    }

    private var currentDirectoryName: String {
        Self.directoryDisplayName(for: currentWorkingDirectoryURL)
    }

    private func directoryURL(from value: String?) -> URL? {
        guard let value = nonEmpty(value) else { return nil }
        if let fileURL = URL(string: value), fileURL.isFileURL {
            return fileURL.standardizedFileURL
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func isShellProcess(_ processName: String?) -> Bool {
        guard let processName else { return false }
        return processName == defaultShellName
            || Self.shellProcessNames.contains(processName)
    }

    private static func fileURL(fromTitle title: String) -> URL? {
        if title == "~" {
            return homeDirectoryURL
        }
        if title.hasPrefix("/") {
            return URL(fileURLWithPath: title)
        }
        if title.hasPrefix("~/") {
            return homeDirectoryURL
                .appendingPathComponent(String(title.dropFirst(2)))
        }
        if let candidate = URL(string: title), candidate.isFileURL {
            return candidate
        }
        return nil
    }

    private static func directoryDisplayName(for url: URL) -> String {
        let url = url.standardizedFileURL
        if url.path == homeDirectoryURL.path { return "~" }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    private static let homeDirectoryURL = FileManager.default
        .homeDirectoryForCurrentUser.standardizedFileURL

    private static let shellProcessNames: Set<String> = {
        var names: Set<String> = [
            "ash", "bash", "csh", "dash", "elvish", "fish", "ksh",
            "mksh", "nu", "pwsh", "sh", "tcsh", "xonsh", "zsh",
        ]
        if let contents = try? String(
            contentsOfFile: "/etc/shells",
            encoding: .utf8
        ) {
            for line in contents.split(whereSeparator: \.isNewline) {
                let path = line.trimmingCharacters(in: .whitespaces)
                guard path.hasPrefix("/") else { continue }
                if let name = processName(from: path) {
                    names.insert(name)
                }
            }
        }
        return names
    }()

    private static var loginShellPath: String {
        if let shellPath = ProcessInfo.processInfo.environment["SHELL"],
           !shellPath.isEmpty {
            return shellPath
        }
        if let user = getpwuid(getuid()),
           let shell = user.pointee.pw_shell {
            return String(cString: shell)
        }
        return "shell"
    }

    private static func processName(from value: String) -> String? {
        let name = URL(fileURLWithPath: value)
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? nil : name
    }
}
