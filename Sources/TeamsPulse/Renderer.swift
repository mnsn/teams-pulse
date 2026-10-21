import AppKit
import PulseCore
import SwiftUI

/// `--render <dir>`: draws the menu bar with the Chats list open, the Group Chats list and the Full Disk
/// Access window into PNGs (light and dark). Useful for checking layout without screen-recording
/// permission, and for the README's screenshots, from the demo data (`make screenshots`).
@MainActor
enum Renderer {
    static func run(directory: String) -> Int32 {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            fputs("Can't create \(directory): \(error.localizedDescription)\n", stderr)
            return 1
        }

        // Overlay scrollers, as on most Macs, whatever this Mac's scroll bar setting.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        _ = NSApplication.shared
        let suite = "TeamsPulse.render"
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let loginItem = LoginItem()
        let storage = StorageMode.current().readOnly
        let store = ConversationStore(settings: settings, storage: storage)
        store.receive(NotificationEngine.loadOnce(paths: storage.paths))
        let onboarding = OnboardingController(store: store)
        let summarizer = Summarizer()
        // TEAMS_PULSE_RENDER_SUMMARIES=1 summarizes the unread chats first, with the on-device model.
        if ProcessInfo.processInfo.environment["TEAMS_PULSE_RENDER_SUMMARIES"] == "1", Summarizer.unavailableReason == nil {
            let unread = ChatGroup.allCases.flatMap { store.state.unread(in: $0) }
            unread.forEach(summarizer.summarize)
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, unread.contains(where: { summarizer.state(for: $0) == .loading }) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }

        var written: [String] = []
        func render<V: View>(_ view: V, appearance: NSAppearance?) -> NSBitmapImageRep? {
            Self.render(view, appearance: appearance, store: store, settings: settings, loginItem: loginItem,
                        onboarding: onboarding, summarizer: summarizer)
        }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = dark ? "dark" : "light"
            if let appearance,
               let panel = render(MenuPanelView(group: .chats).background(Color(nsColor: .windowBackgroundColor)),
                                  appearance: appearance),
               let picture = MenuBarPicture.draw(panel: panel, state: store.state, appearance: appearance),
               let file = write(picture, to: output.appending(path: "menubar-\(suffix).png")) {
                written.append(file)
            }
            if let panel = render(MenuPanelView(group: .groups).background(Color(nsColor: .windowBackgroundColor)),
                                  appearance: appearance),
               let file = write(panel, to: output.appending(path: "groups-\(suffix).png")) {
                written.append(file)
            }
            if let window = render(OnboardingView().background(Color(nsColor: .windowBackgroundColor)), appearance: appearance),
               let file = write(window, to: output.appending(path: "onboarding-\(suffix).png")) {
                written.append(file)
            }
        }
        written.forEach { print($0) }
        return written.isEmpty ? 1 : 0
    }

    private static func render<V: View>(
        _ view: V, appearance: NSAppearance?, store: ConversationStore, settings: AppSettings, loginItem: LoginItem,
        onboarding: OnboardingController, summarizer: Summarizer
    ) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(loginItem)
            .environmentObject(onboarding)
            .environmentObject(summarizer)
            .environmentObject(Updater())) // never started: rendering doesn't check for updates
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        // Let SwiftUI settle measured sizes (the list measures itself) before sizing the image.
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        return cache(host)
    }

    /// Draws an AppKit view at its current size, in an offscreen window with the given appearance.
    static func snapshot(_ view: NSView, appearance: NSAppearance?) -> NSBitmapImageRep? {
        view.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: view.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return cache(view)
    }

    private static func cache(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func write(_ image: NSBitmapImageRep, to url: URL) -> String? {
        guard let data = image.representation(using: .png, properties: [:]) else { return nil }
        do {
            try data.write(to: url)
            return url.path
        } catch {
            fputs("Can't write \(url.path): \(error.localizedDescription)\n", stderr)
            return nil
        }
    }
}
