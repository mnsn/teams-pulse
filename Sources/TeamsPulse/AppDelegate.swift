import AppKit
import Combine
import PulseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let loginItem = LoginItem()
    private lazy var store = ConversationStore(settings: settings, storage: .current())
    private lazy var onboarding = OnboardingController(store: store)
    private lazy var badgeMonitor = BadgeMonitor(store: store, settings: settings)
    private let summarizer = Summarizer()
    private var items: [ChatGroup: StatusItemController] = [:]
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app has no visible windows most of the time; don't let macOS reclaim it.
        ProcessInfo.processInfo.disableAutomaticTermination("Shows unread Teams chats")
        Log.app.info("Launched from \(Bundle.main.bundlePath, privacy: .public)")

        // New items appear to the left of earlier ones, so this puts Chats left of Group Chats.
        for group in [ChatGroup.groups, .chats] {
            let item = StatusItemController(
                group: group, store: store, settings: settings, loginItem: loginItem, onboarding: onboarding,
                summarizer: summarizer
            )
            item.willShow = { [weak self] shown in
                guard let self else { return }
                for other in self.items.values where other !== shown {
                    other.closePopover()
                }
            }
            items[group] = item
        }

        // Without access, start with the steps to grant it.
        store.$access
            .compactMap { $0 }
            .first()
            .sink { [weak self] access in
                MainActor.assumeIsolated {
                    if access == .denied { self?.onboarding.show() }
                }
            }
            .store(in: &cancellables)

        store.start()
        badgeMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the chats.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if store.access == .denied {
            onboarding.show()
        } else {
            items[.chats]?.showPopover()
        }
        return false
    }
}
