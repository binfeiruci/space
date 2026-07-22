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
    @Published var isSearchPresented = false
    @Published var searchQuery = ""
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var currentProcessName: String?
    private var pendingInput: String?

    init(
        workingDirectoryURL: URL,
        settings: AppSettings? = nil,
        defaultShellPath: String? = nil,
        surfaceContext: TerminalSurfaceContext = .window,
        initialInput: String? = nil
    ) {
        let settings = settings ?? AppSettings()
        self.workingDirectoryURL = workingDirectoryURL.standardizedFileURL
        let shellPath = defaultShellPath ?? Self.loginShellPath
        defaultShellName = Self.processName(
            from: shellPath
        ) ?? "shell"

        terminal = TerminalViewState(
            configSource: settings.ghosttyConfigSource
        )
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectoryURL.path,
            context: surfaceContext
        )
        pendingInput = initialInput
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

    func updateCurrentProcessName(_ name: String?) {
        guard currentProcessName != name else { return }
        currentProcessName = name
    }

    var isRunningForegroundProgram: Bool {
        runningForegroundProcessName != nil
    }

    var runningForegroundProcessName: String? {
        guard let currentProcessName,
              currentProcessName != defaultShellName
        else { return nil }
        return currentProcessName
    }

    var currentWorkingDirectoryURL: URL {
        Self.workingDirectoryURL(
            reportedPath: terminal.workingDirectory,
            fallback: workingDirectoryURL
        )
    }

    nonisolated static func workingDirectoryURL(
        reportedPath: String?,
        fallback: URL
    ) -> URL {
        guard let reportedPath else {
            return fallback.standardizedFileURL
        }
        let path = reportedPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if path.hasPrefix("file://"),
           let fileURL = URL(string: path),
           fileURL.isFileURL {
            return fileURL.standardizedFileURL
        }
        if path == "~" || path.hasPrefix("~/") {
            let expandedPath = NSString(string: path).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return fallback.standardizedFileURL
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

    func sendPendingInputIfReady() {
        guard let pendingInput, terminal.send(pendingInput) else { return }
        self.pendingInput = nil
    }

    func displayTitle(
        terminalTitle: String,
        foregroundProcessName: String?
    ) -> String {
        let processName = foregroundProcessName.flatMap(Self.processName(from:))
        if processName == defaultShellName { return defaultShellName }

        let title = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !Self.isPathTitle(title) {
            return title
        }
        return processName ?? defaultShellName
    }

    private static func isPathTitle(_ title: String) -> Bool {
        title == "~"
            || title.hasPrefix("~/")
            || title.hasPrefix("/")
            || title.hasPrefix("file://")
    }

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
