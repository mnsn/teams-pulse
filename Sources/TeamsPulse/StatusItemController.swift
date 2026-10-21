import AppKit
import Combine
import PulseCore
import SwiftUI

/// One menu-bar item: Chats (1:1) or Group Chats, with its count and its own popover.
@MainActor
final class StatusItemController: NSObject {
    let group: ChatGroup
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: ConversationStore
    private var cancellables: Set<AnyCancellable> = []
    /// Called before the popover opens, so the other item can close its own.
    var willShow: ((StatusItemController) -> Void)?

    init(
        group: ChatGroup, store: ConversationStore, settings: AppSettings, loginItem: LoginItem,
        onboarding: OnboardingController, summarizer: Summarizer, updater: Updater
    ) {
        self.group = group
        self.store = store
        super.init()

        let host = NSHostingController(
            rootView: MenuPanelView(group: group)
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(loginItem)
                .environmentObject(onboarding)
                .environmentObject(summarizer)
                .environmentObject(updater)
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.autosaveName = "TeamsPulse.\(group.rawValue)"

        render()
        store.$state.map { $0.count(group) }.removeDuplicates().map { _ in () }
            .merge(with: store.$problem.removeDuplicates().map { _ in () })
            .sink { [weak self] in MainActor.assumeIsolated { self?.render() } }
            .store(in: &cancellables)

        // Opening a chat hands focus to Teams; don't leave the list hanging open.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.closePopover() } }
            .store(in: &cancellables)
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        willShow?(self)
        store.refresh()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let count = store.state.count(group)
        let attention = store.problem?.isBlocking == true
        Self.configure(button, group: group, count: count, attention: attention)
        var tooltip = "Teams Pulse: " + group.unreadDescription(count).lowercased()
        if let problem = store.problem, attention {
            tooltip += ". " + problem.title
        }
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
    }

    /// The symbol and count. With nothing unread, just the symbol in the menu bar's own color; with
    /// unread chats, the symbol in the item's color and the count. `--render` sets up the README
    /// picture's buttons here too, so the picture can't drift from the real items.
    static func configure(_ button: NSButton, group: ChatGroup, count: Int, attention: Bool) {
        let font = NSFont.menuBarFont(ofSize: 0)
        if count == 0 && !attention {
            let image = NSImage(systemSymbolName: group.symbol, accessibilityDescription: group.title)
            image?.isTemplate = true
            button.image = image
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            return
        }
        let title = NSMutableAttributedString()
        title.append(symbol(group.symbol, color: count > 0 ? group.nsColor : .labelColor, font: font))
        if count > 0 {
            title.append(NSAttributedString(
                string: "\u{2009}\(count)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .medium),
                             .foregroundColor: NSColor.labelColor]
            ))
        }
        if attention {
            title.append(NSAttributedString(string: "\u{2009}"))
            title.append(symbol("exclamationmark.triangle.fill", color: .systemOrange, font: font, scale: 0.75))
        }
        button.image = nil
        button.attributedTitle = title
        button.imagePosition = .noImage
    }

    private static func symbol(_ name: String, color: NSColor, font: NSFont, scale: CGFloat = 1) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(pointSize: (font.pointSize - 1) * scale, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0, y: (font.capHeight - image.size.height) / 2,
            width: image.size.width, height: image.size.height
        )
        return NSAttributedString(attachment: attachment)
    }
}
