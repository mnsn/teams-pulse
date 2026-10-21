import os

/// Diagnostics: `log show --last 10m --predicate 'subsystem == "com.asaf.TeamsPulse"'`
///
/// Only counts, states and errors. Never chat names, messages or IDs.
enum Log {
    static let app = Logger(subsystem: "com.asaf.TeamsPulse", category: "app")
}
