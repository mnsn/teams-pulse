import Foundation

/// Teams' dock badge, as `lsappinfo info -only StatusLabel -app com.microsoft.teams2` reports it:
/// `"StatusLabel"={ "label"="3" }` while there's a badge, a line without a label when the app runs
/// without one, and nothing at all when the app isn't running.
public enum DockBadge: Sendable, Equatable {
    case noBadge
    case count(Int)
    /// A badge that isn't a number, such as a dot.
    case mark

    public var isClear: Bool {
        switch self {
        case .noBadge: return true
        case .count(let count): return count <= 0
        case .mark: return false
        }
    }

    /// Nil when the output says nothing, as when the app isn't running: that's no news about the badge.
    public static func parse(lsappinfo output: String) -> DockBadge? {
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard let match = output.firstMatch(of: /"label"\s*=\s*"([^"]*)"/) else { return .noBadge }
        let label = match.1.trimmingCharacters(in: .whitespaces)
        if label.isEmpty { return .noBadge }
        if let count = Int(label) { return .count(count) }
        return .mark
    }
}

/// Tells when Teams' dock badge was seen to clear. Only a badge that was there, then gone, in the same
/// Teams process counts: no badge right after Teams starts, or no reading at all, says nothing.
public struct DockBadgeTracker: Sendable {
    private var last: DockBadge?
    private var process: Int32?

    public init() {}

    /// Takes in a reading (nil when there was nothing to read) from the Teams process `process`, and
    /// returns whether the badge just cleared.
    public mutating func update(_ badge: DockBadge?, process: Int32) -> Bool {
        guard let badge else {
            reset()
            return false
        }
        if self.process != process {
            self.process = process
            last = nil
        }
        defer { last = badge }
        guard badge.isClear, let last else { return false }
        return !last.isClear
    }

    /// Teams started or quit: its badge starts over.
    public mutating func reset() {
        last = nil
        process = nil
    }
}
