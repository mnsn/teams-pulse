# Contributing to Teams Pulse

Bug reports, ideas and pull requests are welcome.

## Getting started

You need macOS 15 or later and Swift 6. Xcode works, and so do just the Command Line Tools.

```sh
git clone https://github.com/mnsn/teams-pulse.git
cd teams-pulse
make test    # run the tests
make demo    # run the app with made-up chats (Ctrl-C to quit)
```

`make demo` writes made-up Teams notifications in Notification Center's layout to `build/demo` and
points the app at them. Use it to work on the UI and to take screenshots without showing your own
chats.

Other targets:

```sh
make build              # debug build
make demo-check         # check that the demo chats land in the expected lists
make render             # draw the menu bar, both lists and the Full Disk Access window from the demo data
make screenshots        # render the README's screenshots (with summaries, if Apple Intelligence is on)
make signing-identity   # once per Mac: create the certificate every build is signed with
make pppc-profile       # a configuration profile that grants the built app Full Disk Access, for MDM
make app                # build "Teams Pulse.app" into ./build, signed with it
make install            # build the app, copy it to ~/Applications and open it
make icon               # regenerate Resources/AppIcon.icns
```

These read your own Teams notifications, through Terminal's Full Disk Access:

```sh
make run        # the app, from a debug build (it saves nothing)
make dump       # unread and recent chats
make watch      # messages as they arrive, and chats as they're read
make diagnose   # the structure only, without names, messages or IDs
```

[How it works](docs/how-it-works.md) explains the database, the unread rules and the signing.

## Project layout

```text
Sources/PulseCore/      the engine; UI-free, and fully tested
  NotificationPaths     where Notification Center and Teams Pulse keep their files
  NotificationDatabase  read-only SQLite access to Teams' rows, with the layout checks
  RecordDecoder         a stored notification's plist and its archived user info
  TeamsNotification     what a Teams notification is: chat message, activity, channel post
  DeepLink              msteams: links to a chat message
  SummaryPrompt         what the on-device model is asked when it summarizes a chat
  UnreadTracker         decides which chats are unread
  UnreadStore           the encrypted unread chats and the state file
  FormatCheck           how much of what's stored could be read
  Diagnostics           the structure-only report
  DockBadge             parses Teams' dock badge from lsappinfo
  FileEventStream       FSEvents wrapper
  FileWriteWatcher      kqueue watcher for the SQLite WAL file
  NotificationEngine    wires the reading together and publishes snapshots
Sources/TeamsPulse/     the AppKit/SwiftUI app: two menu-bar items, lists, Full Disk Access window,
                        settings, keychain, summaries (Summarizer), command line
Tests/PulseCoreTests/   Swift Testing suites with made-up notifications, including live kqueue tests
scripts/                app bundling and signing, the signing certificate, the MDM profile, the icon and
                        the demo data
```

## Debugging

The app binary doubles as a command-line tool (`TeamsPulse --help`). Set `TEAMS_PULSE_DB` to read
another database, such as `build/demo/db2/db`, and `TEAMS_PULSE_STATE_DIR` for its state; `make demo`
does both. With another database, Teams Pulse keeps its key in a file next to that state instead of the
keychain. Chats from Notification Center's own database are only ever saved by the installed app, with
the key in the keychain.

Diagnostics go to the system log:

```sh
log show --last 10m --info --predicate 'subsystem == "com.asaf.TeamsPulse"' --style compact
```

## Building with only the Command Line Tools

- `make test` passes Swift Testing's macro plugin folder to the compiler explicitly. Without it,
  `swift test` sometimes fails with "plugin for module 'TestingMacros' not found".
- The `@State`, `@Entry` and `#Preview` SwiftUI macros aren't available without Xcode, so the views
  use a small `@LocalState` property wrapper instead of `@State`.

## Ground rules

- **Never change Notification Center's data.** Open it read-only, keep reads short, and never run
  SQL that writes, including `PRAGMA` settings and checkpoints. Never copy the database.
- **Nothing leaves the Mac.** The app makes no network connections, and `scripts/check-app.sh` fails
  if it uses networking APIs. Keep it that way.
- **Only unread chats touch the disk**, encrypted, and only until they're read. Summaries, read chats
  and anything else about chats stay in memory.
- **Summaries stay on the Mac.** Use `SystemLanguageModel` only, never
  `PrivateCloudComputeLanguageModel` or any other model that runs elsewhere.
- **No content in logs.** Log counts, states and errors, never names, messages or chat IDs.
- **Use made-up data.** Names, messages and IDs from real Teams chats are private, and often
  confidential. Don't put them in tests, screenshots, issues or pull requests. `--diagnose` output is
  safe to share; `--dump` and `--watch` output isn't.
- **Logic goes in `PulseCore`**, free of UI code and covered by tests.
- **The formats are undocumented.** When you rely on a new field, handle its absence and add a test
  with a small made-up sample.

## License

Teams Pulse is licensed under the GNU General Public License, version 3 or later. By contributing,
you agree that your contributions are licensed under the same terms.
