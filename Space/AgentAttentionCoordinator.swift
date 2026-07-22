import Combine
import Foundation
import GhosttyTerminal

@MainActor
final class AgentAttentionCoordinator {
    private var notificationCancellables: [UUID: AnyCancellable] = [:]
    private var focusCancellables: [UUID: AnyCancellable] = [:]

    func bind(
        to session: TerminalSession,
        notificationHandler: @escaping (
            AgentAttentionNotification,
            UUID,
            Bool
        ) -> Void,
        focusHandler: @escaping () -> Void
    ) {
        let sessionID = session.id
        notificationCancellables[sessionID] = session.terminal
            .$lastDesktopNotificationAt
            .compactMap { $0 }
            .sink { [weak session] receivedAt in
                guard let session else { return }
                notificationHandler(
                    AgentAttentionNotification(
                        title: session.terminal.lastDesktopNotificationTitle
                            ?? "",
                        body: session.terminal.lastDesktopNotificationBody
                            ?? "",
                        receivedAt: receivedAt
                    ),
                    sessionID,
                    session.terminal.isFocused
                )
            }

        focusCancellables[sessionID] = session.terminal
            .$isFocused
            .removeDuplicates()
            .filter { $0 }
            .sink { _ in focusHandler() }
    }

    func unbind(terminalID: UUID) {
        notificationCancellables.removeValue(forKey: terminalID)
        focusCancellables.removeValue(forKey: terminalID)
    }
}
