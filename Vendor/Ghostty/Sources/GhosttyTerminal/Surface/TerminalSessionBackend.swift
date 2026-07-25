public enum TerminalSessionBackend: Sendable {
    case exec

    func isEquivalent(to other: TerminalSessionBackend) -> Bool {
        switch (self, other) {
        case (.exec, .exec):
            true
        }
    }
}
