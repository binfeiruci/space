import Foundation

struct TerminalWorkspaceStore {
    struct Snapshot: Codable {
        struct SidebarItem: Codable {
            enum Kind: String, Codable {
                case tab
                case divider
            }

            let kind: Kind
            let workingDirectoryPath: String?
            let isActive: Bool

            static let divider = Self(
                kind: .divider,
                workingDirectoryPath: nil,
                isActive: false
            )

            static func tab(
                workingDirectoryPath: String,
                isActive: Bool
            ) -> Self {
                Self(
                    kind: .tab,
                    workingDirectoryPath: workingDirectoryPath,
                    isActive: isActive
                )
            }
        }

        let items: [SidebarItem]
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> Snapshot? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static let key = "terminal.workspace"
}
