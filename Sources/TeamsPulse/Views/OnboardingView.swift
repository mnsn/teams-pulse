import AppKit
import Combine
import PulseCore
import SwiftUI

/// The window that walks you through granting Full Disk Access. It opens by itself when Teams Pulse
/// can't read the database, and checks for access every 2 seconds while it's open.
@MainActor
final class OnboardingController: NSObject, ObservableObject, NSWindowDelegate {
    private let store: ConversationStore
    private var window: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    /// Whether this is the app bundle, rather than a binary run from Terminal (whose Full Disk Access
    /// is then Terminal's).
    let isBundled = Bundle.main.bundleIdentifier == "com.asaf.TeamsPulse"

    /// The folder the app is in, as you'd type it in an Open panel: `~/Applications` after `make install`.
    var appFolder: String {
        (Bundle.main.bundleURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    init(store: ConversationStore) {
        self.store = store
        super.init()
    }

    func show() {
        requestListing()
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView()
                .environmentObject(store)
                .environmentObject(self))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Teams Pulse"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        store.setWaitingForAccess(true)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            store.setWaitingForAccess(false)
        }
    }

    func openPrivacySettings() {
        requestListing()
        let panes = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for pane in panes {
            if let url = URL(string: pane), NSWorkspace.shared.open(url) { return }
        }
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Gets Teams Pulse listed under Full Disk Access, switched off, so you only turn it on. macOS lists
    /// an app there once it has been denied a folder that Full Disk Access protects, but Notification
    /// Center's database is protected without that. So, while access is missing, this tries to list the
    /// folders Apple's Stocks and Safari keep, as the FullDiskAccess package does
    /// (github.com/inket/FullDiskAccess). Without access, both attempts are denied and read nothing.
    func requestListing() {
        guard isBundled, DatabaseAccess.check(store.paths.database) == .denied else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in ["Library/Containers/com.apple.stocks", "Library/Safari"] {
            _ = try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(folder).path)
        }
        Log.app.info("Asked macOS to list Teams Pulse under Full Disk Access")
    }

    /// Quits and opens the app again, once this process has exited, for when macOS only applies
    /// access after a restart.
    func relaunch() {
        guard isBundled else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            Log.app.error("Couldn't relaunch: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var controller: OnboardingController

    private var granted: Bool { store.access == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AppIconView(isBundled: controller.isBundled)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Allow Full Disk Access")
                        .font(.title2.weight(.semibold))
                    Text("So Teams Pulse can see the notifications Teams sends")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Teams Pulse finds your unread chats in the notifications that macOS keeps in Notification Center. macOS protects that database, so Teams Pulse needs Full Disk Access to read it. It only reads it, and nothing about your chats leaves your Mac.")
                .fixedSize(horizontal: false, vertical: true)

            if store.lostAccess {
                Label("Teams Pulse had access before. That happens when it's rebuilt with another signature: remove Teams Pulse from the list with −, then add it again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.isBundled {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Click **Open Privacy Settings**.")
                    step(2, "Turn on **Teams Pulse**. If it isn't in the list, click **+** under the list and choose it in **\(controller.appFolder)** (press ⌘⇧G to type the folder), or click **Show in Finder** and drag it into the list.")
                    step(3, "If macOS offers to, choose **Quit & Reopen**.")
                }
            } else {
                Text("You're running Teams Pulse from Terminal, so macOS checks Terminal's access instead: give **Terminal** Full Disk Access, then run Teams Pulse again.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open Privacy Settings") { controller.openPrivacySettings() }
                    .keyboardShortcut(.defaultAction)
                if controller.isBundled {
                    Button("Show in Finder") { controller.showInFinder() }
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 8) {
                if granted {
                    Label("Done. Teams Pulse can read Teams' notifications now.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Close") { controller.close() }
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for access…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.isBundled {
                        Button("Quit & Reopen") { controller.relaunch() }
                            .help("Use this if you turned access on and Teams Pulse still waits")
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app's icon, which you can drag into the Full Disk Access list.
struct AppIconView: View {
    let isBundled: Bool

    var body: some View {
        let icon = Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .frame(width: 64, height: 64)
        if isBundled {
            icon
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help("Drag this into the Full Disk Access list")
        } else {
            icon
        }
    }
}
