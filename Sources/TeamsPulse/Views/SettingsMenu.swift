import AppKit
import PulseCore
import SwiftUI

/// The gear menu, shared by both popovers.
struct SettingsMenuContent: View {
    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var loginItem: LoginItem
    @EnvironmentObject private var onboarding: OnboardingController
    @EnvironmentObject private var updater: Updater

    var body: some View {
        Picker("Keep Unread For", selection: $settings.keepUnread) {
            ForEach(AppSettings.KeepUnread.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)

        Toggle("Show Message Previews", isOn: $settings.showPreviews)
        Toggle("Summarize with Apple Intelligence", isOn: $settings.showSummaries)
            .disabled(!settings.showPreviews)
        if settings.showSummaries, let reason = Summarizer.unavailableReason {
            Text(reason)
        }
        Toggle("Mark All Read When Teams' Badge Clears", isOn: $settings.clearWithDockBadge)

        if loginItem.isAvailable {
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            if loginItem.needsApproval {
                Button("Allow in Login Items Settings…") { loginItem.openSystemSettings() }
            } else if let error = loginItem.lastError {
                Text("Launch at Login failed: \(error)")
            }
        }

        Divider()

        if updater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            Toggle("Check for Updates Automatically", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.setAutomaticallyChecks($0) }
            ))
            Divider()
        }

        if store.access != .granted {
            Button("Set Up Full Disk Access…") { onboarding.show() }
        }
        Button("Copy Diagnostics") { Diagnose.copyReport(paths: store.paths) }
        Button("Open Microsoft Teams") { TeamsApp.activate() }
        Button("Quit Teams Pulse") { NSApp.terminate(nil) }
    }
}

enum Diagnose {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    /// Copies the structure-only report (no names, messages or IDs) for an issue.
    @MainActor
    static func copyReport(paths: NotificationPaths) {
        let version = appVersion
        DispatchQueue.global(qos: .userInitiated).async {
            let report = Diagnostics.report(paths: paths, appVersion: version)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }
    }
}
