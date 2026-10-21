import Foundation
import PulseCore

/// Command-line modes, mainly for checking what the menu bar would show.
enum CLI {
    static let usage = """
        Teams Pulse: your unread Microsoft Teams chats in the menu bar.

        Usage: TeamsPulse [option]
          (no option)      Run the menu-bar app
          --dump           Print unread and recent chats, with names and messages
          --json           Print the same as JSON
          --watch          Print messages as they arrive and chats as they're read (Ctrl-C to stop)
          --summaries      Summarize each unread chat in a sentence, with Apple's on-device model
          --diagnose       Describe Notification Center's database and Teams' notifications by their
                           structure only, without names, messages or IDs, for an issue report
          --render <dir>   Draw the menu bar and both lists into PNGs (light and dark)
          --help           Show this help

        --dump, --json, --watch and --summaries print names and messages, so keep their output private.
        Set TEAMS_PULSE_DB to read another Notification Center database, such as the demo data,
        and TEAMS_PULSE_STATE_DIR for the state that goes with it.
        """

    /// Returns an exit code for command-line modes, or nil to launch the app.
    static func run(_ arguments: [String]) -> Int32? {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        if arguments.contains("--diagnose") {
            print(Diagnostics.report(paths: .default(), appVersion: Diagnose.appVersion))
            return 0
        }
        if arguments.contains("--json") {
            return printJSON()
        }
        if arguments.contains("--dump") {
            return printTable()
        }
        if arguments.contains("--watch") {
            watch()
        }
        if arguments.contains("--summaries") {
            printSummaries()
        }
        return nil
    }

    static var trackerSettings: TrackerSettings {
        TrackerSettings(keepUnreadFor: AppSettings.KeepUnread.saved().interval)
    }

    private static func load() -> (UnreadState, EngineSnapshot) {
        StorageMode.current().readOnly.loadState(settings: trackerSettings)
    }

    private struct ChatOutput: Encodable {
        var name: String
        var kind: String
        var unread: Int
        var lastActivity: Date
        var latest: String?
        var link: String?

        init(_ conversation: ConversationSummary) {
            name = conversation.name
            kind = conversation.kind.rawValue
            unread = conversation.unreadCount
            lastActivity = conversation.lastActivity
            latest = (conversation.unread.last ?? conversation.latest)?.preview
            link = conversation.link?.absoluteString
        }
    }

    private struct Output: Encodable {
        var access: String
        var problem: String?
        var counts: [String: Int]
        var unread: [String: [ChatOutput]]
        var recent: [String: [ChatOutput]]
    }

    private static func printJSON() -> Int32 {
        let (state, snapshot) = load()
        let groups = ChatGroup.allCases
        let output = Output(
            access: snapshot.access.rawValue,
            problem: snapshot.problem.map { "\($0.title). \($0.message)" },
            counts: Dictionary(uniqueKeysWithValues: groups.map { ($0.rawValue, state.count($0)) }),
            unread: Dictionary(uniqueKeysWithValues: groups.map { ($0.rawValue, state.unread(in: $0).map(ChatOutput.init)) }),
            recent: Dictionary(uniqueKeysWithValues: groups.map { ($0.rawValue, state.recent(in: $0).map(ChatOutput.init)) })
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(output) else { return 1 }
        FileHandle.standardOutput.write(data)
        print()
        return 0
    }

    private static func printTable() -> Int32 {
        let (state, snapshot) = load()
        let now = Date()
        if let problem = snapshot.problem {
            print("! \(problem.title). \(problem.message)")
        }
        print(ChatGroup.allCases.map { "\($0.title): \(state.count($0)) unread" }.joined(separator: " · "))
        for group in ChatGroup.allCases {
            print("\nUNREAD \(group.title.uppercased())")
            for conversation in state.unread(in: group) {
                print(row(conversation, now: now))
            }
            let recent = state.recent(in: group)
            if !recent.isEmpty {
                print("RECENT \(group.title.uppercased())")
                for conversation in recent {
                    print(row(conversation, now: now))
                }
            }
        }
        return 0
    }

    private static func row(_ conversation: ConversationSummary, now: Date) -> String {
        let latest = (conversation.unread.last ?? conversation.latest)?.preview ?? ""
        let since = RelativeTime.short(conversation.unread.last?.deliveredAt ?? conversation.lastActivity, now: now)
        return "  " + [pad(conversation.name, 32), pad(conversation.unreadCount > 0 ? "\(conversation.unreadCount)" : "", 3),
                       pad(since, 4), String(latest.replacingOccurrences(of: "\n", with: " ").prefix(70))]
            .joined(separator: " ")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    /// Summarizes the unread chats one after the other, on this Mac, and prints how long each took.
    private static func printSummaries() -> Never {
        let (state, snapshot) = load()
        if let problem = snapshot.problem {
            print("! \(problem.title). \(problem.message)")
        }
        if let reason = Summarizer.unavailableReason {
            print(reason)
            exit(1)
        }
        let conversations = ChatGroup.allCases.flatMap { state.unread(in: $0) }
        if conversations.isEmpty {
            print("No unread chats.")
            exit(0)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            for conversation in conversations {
                let started = ContinuousClock.now
                let result = await Summarizer.summarize(prompt: SummaryPrompt.prompt(for: conversation))
                let elapsed = (ContinuousClock.now - started).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
                let text = switch result {
                case .done(let summary): summary
                case .failed(let reason): "(\(reason))"
                case .loading: ""
                }
                print("\(conversation.name) (\(conversation.unreadCount) unread, \(elapsed))\n  \(text)")
            }
            exit(0)
        }
        dispatchMain()
    }

    private static func watch() -> Never {
        let storage = StorageMode.current().readOnly
        let queue = DispatchQueue(label: "TeamsPulse.watch")
        let printer = WatchPrinter(storage: storage, settings: trackerSettings)
        let engine = NotificationEngine(paths: storage.paths) { snapshot in queue.async { printer.receive(snapshot) } }
        // Unread messages also expire with time alone.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(1))
        timer.setEventHandler { printer.report() }
        timer.resume()
        engine.start()
        setvbuf(stdout, nil, _IOLBF, 0)
        print("Watching \(storage.paths.database.path). Ctrl-C stops.")
        withExtendedLifetime((engine, timer)) { dispatchMain() }
    }
}

/// Prints new unread messages and chats that were read. Confined to the watch queue.
private final class WatchPrinter: @unchecked Sendable {
    private var tracker: UnreadTracker
    private let settings: TrackerSettings
    private var problem: PulseProblem?
    private var previous: [String: ConversationSummary] = [:]
    private var counts: [ChatGroup: Int] = [:]
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(storage: StorageMode, settings: TrackerSettings) {
        let cached = storage.keyStore.map {
            UnreadCache(url: storage.paths.unreadFile, keyStore: $0).load(discardingUnreadable: false).conversations
        } ?? []
        tracker = UnreadTracker(launch: LaunchContext(state: StateStore(url: storage.paths.stateFile).load(),
                                                      cached: cached, launchedAt: Date()))
        self.settings = settings
    }

    func receive(_ snapshot: EngineSnapshot) {
        if snapshot.problem != problem {
            problem = snapshot.problem
            if let problem { line("! \(problem.title). \(problem.message)") }
        }
        if let notifications = snapshot.notifications {
            tracker.apply(notifications, now: Date())
        }
        report()
    }

    func report() {
        let now = Date()
        tracker.expire(now: now, settings: settings)
        let state = tracker.state(now: now, settings: settings)
        var current: [String: ConversationSummary] = [:]
        for group in ChatGroup.allCases {
            for conversation in state.unread(in: group) {
                current[conversation.id] = conversation
                let known = Set(previous[conversation.id]?.unread.map(\.key) ?? [])
                for message in conversation.unread where !known.contains(message.key) {
                    line("+ \(conversation.name) (\(group.title.lowercased())): \(message.preview.prefix(90))")
                }
            }
        }
        for (id, conversation) in previous where current[id] == nil {
            line("  read: \(conversation.name)")
        }
        let newCounts = Dictionary(uniqueKeysWithValues: ChatGroup.allCases.map { ($0, state.count($0)) })
        if newCounts != counts {
            line(ChatGroup.allCases.map { "\($0.title.lowercased()) \(newCounts[$0] ?? 0)" }.joined(separator: " · "))
            counts = newCounts
        }
        previous = current
    }

    private func line(_ text: String) {
        print("\(formatter.string(from: Date()))  \(text)")
    }
}
