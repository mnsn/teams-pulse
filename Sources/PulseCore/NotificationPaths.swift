import Foundation

/// Where Notification Center keeps its database, and where Teams Pulse keeps its own state.
public struct NotificationPaths: Sendable, Equatable {
    /// Notification Center's SQLite database (`db2/db`).
    public var database: URL
    /// Teams Pulse's own files: when it last ran, and the encrypted unread chats.
    public var stateDirectory: URL
    /// Whether `database` is this Mac's real Notification Center database, rather than a fixture or
    /// the demo data. Real chats are only ever saved with the key in the keychain.
    public var isSystemDatabase: Bool

    /// Points Teams Pulse at another Notification Center database, such as a fixture or the demo data.
    public static let databaseVariable = "TEAMS_PULSE_DB"
    /// Where Teams Pulse keeps its state. Defaults to a `state` folder next to an overridden database.
    public static let stateVariable = "TEAMS_PULSE_STATE_DIR"

    public init(database: URL, stateDirectory: URL, isSystemDatabase: Bool = false) {
        self.database = database
        self.stateDirectory = stateDirectory
        self.isSystemDatabase = isSystemDatabase
    }

    public var directory: URL { database.deletingLastPathComponent() }
    public var writeAheadLog: URL { URL(fileURLWithPath: database.path + "-wal") }
    public var stateFile: URL { stateDirectory.appendingPathComponent("state.json") }
    public var unreadFile: URL { stateDirectory.appendingPathComponent("unread") }

    public static func systemDatabase(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> NotificationPaths {
        let system = systemDatabase(home: home)
        let databaseOverride = environment[databaseVariable].flatMap { $0.isEmpty ? nil : expand($0) }
        let stateOverride = environment[stateVariable].flatMap { $0.isEmpty ? nil : expand($0) }
        let database = databaseOverride ?? system
        let isSystemDatabase = isSameFile(database, system)
        let state = stateOverride
            ?? (isSystemDatabase ? nil : database.deletingLastPathComponent().appendingPathComponent("state", isDirectory: true))
            ?? home.appendingPathComponent("Library/Application Support/Teams Pulse", isDirectory: true)
        return NotificationPaths(database: database, stateDirectory: state, isSystemDatabase: isSystemDatabase)
    }

    /// Whether two paths name the same file, allowing for symbolic links and letter case (APFS is
    /// usually case-insensitive). Errs toward "the same", which only makes Teams Pulse more careful.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let first = a.standardizedFileURL.resolvingSymlinksInPath().path
        let second = b.standardizedFileURL.resolvingSymlinksInPath().path
        if first.compare(second, options: .caseInsensitive) == .orderedSame { return true }
        var one = stat()
        var other = stat()
        guard stat(a.path, &one) == 0, stat(b.path, &other) == 0 else { return false }
        return one.st_dev == other.st_dev && one.st_ino == other.st_ino
    }

    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
