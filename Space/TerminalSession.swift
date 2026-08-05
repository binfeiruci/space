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

    func updateCurrentProcessName(_ name: String?) {
        guard currentProcessName != name else { return }
        currentProcessName = name
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

    func displayTitle(
        terminalTitle: String,
        foregroundProcessName: String?,
        currentWorkingDirectory: String? = nil
    ) -> String {
        let processName = foregroundProcessName.flatMap(Self.processName(from:))
        if processName == defaultShellName {
            return directoryName(
                currentWorkingDirectory: currentWorkingDirectory
            )
        }

        let title = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty,
           !Self.isHomeDirectory(URL(fileURLWithPath: title)) {
            return title
        }
        return processName ?? directoryName(
            currentWorkingDirectory: currentWorkingDirectory
        )
    }

    private func directoryName(currentWorkingDirectory: String?) -> String {
        let value = currentWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentURL: URL? = if let value, !value.isEmpty {
            if let fileURL = URL(string: value), fileURL.isFileURL {
                fileURL
            } else {
                URL(fileURLWithPath: value)
            }
        } else {
            nil
        }
        let url = (currentURL ?? workingDirectoryURL).standardizedFileURL
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        if url.path == homePath {
            return "~"
        }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    private static func isHomeDirectory(_ url: URL) -> Bool {
        return url.standardizedFileURL.path
            == FileManager.default.homeDirectoryForCurrentUser
                .standardizedFileURL.path
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
