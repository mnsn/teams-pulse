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
make package            # what a release ships: the universal app, checked and zipped, in build/release
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

[How it works](docs/how-it-works.md) explains the database, the unread rules, the signing and the
updates.

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
                        settings, keychain, summaries (Summarizer), updates (Updater), command line
Tests/PulseCoreTests/   Swift Testing suites with made-up notifications, including live kqueue tests
scripts/                app bundling, signing and checks, the signing certificate, packaging and
                        signing releases, the MDM profile, the icon and the demo data
.github/workflows/      CI, and the release workflow
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
- **Nothing about chats leaves the Mac.** The app's only network requests are Sparkle's update
  checks and downloads, from this project's GitHub releases, and only if the user allows them. The
  app's own code has no networking, and `scripts/check-app.sh` fails if it uses networking APIs.
  Keep it that way.
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

## Pull requests

- Keep each pull request focused, and describe the change users will see.
- Run `make test` first. CI also runs it on macOS 15 (with Xcode 16, so without summaries) and
  macOS 26, packages the app and runs it on Apple silicon and Intel.
- Update the README, or [How it works](docs/how-it-works.md), when behavior or settings change.
- For UI changes, include before and after screenshots from `make screenshots`, never of your own
  chats.

## Releasing

Releases are built and signed by GitHub Actions, not on a maintainer's Mac.

1. Set the new version as `CFBundleShortVersionString` in `Resources/Info.plist`, as three numbers
   such as `0.2.0`. The build sets `CFBundleVersion` to the same value. Sparkle compares it to
   decide whether a release is newer, so a release fails unless its version is higher than every
   earlier tag.
2. Add a section for it at the top of `CHANGELOG.md`, such as `## 0.2.0 - 2026-11-30`. It becomes
   the release notes, on GitHub and in the app's update window, so write it for users.
3. Push to `main` and wait for CI. Its macOS 26 job uploads the packaged app as the `Teams-Pulse`
   artifact, and the next jobs run that app on macOS 15 on Apple silicon and Intel. CI also signs
   the package with a throwaway key, the way a release does (`scripts/appcast-dry-run.sh`).
4. Tag the commit and push the tag:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

5. Approve the release: in the run under **Actions**, click **Review deployments**, select
   `release` and click **Approve and deploy**.

The tag starts the [release workflow](.github/workflows/release.yml). Its first job checks the
version, then builds and tests the universal app on macOS 26, signed with a throwaway certificate.
After your approval, the second job signs the app again with the release certificate
(`scripts/sign-release.sh`), checks that it's the certificate in `Resources/ReleaseRequirement.txt`
and deletes it from the runner. It then signs the zip and writes `appcast.xml`
(`scripts/make-appcast.sh`), checks the signatures with the public key
(`scripts/verify-appcast.swift`), attests both files, and publishes the release with
`Teams-Pulse.zip`, its SHA-256, `appcast.xml` and the changelog section.

### The release keys

A release needs two private keys, which only the maintainer's Mac and the `release` environment
hold. `scripts/make-release-keys.sh` sets both up and copies them, one at a time, to the clipboard
for the environment's secrets, without writing them to a file:

- **The release certificate** signs the app. macOS ties Full Disk Access to it, so every release
  must be signed with the same one, or every user loses the access. It's the maintainer's
  **Teams Pulse Signing** certificate from `make signing-identity`, so their own builds and the
  releases share Full Disk Access. Secrets: `RELEASE_CERTIFICATE_P12` and
  `RELEASE_CERTIFICATE_PASSWORD`. `Resources/ReleaseRequirement.txt` holds the designated
  requirement it gives the app, and the release workflow refuses to publish an app that doesn't
  have it.
- **The update signing key** signs each update and the appcast. Installed apps accept only updates
  signed with the key that matches `SUPublicEDKey` in `Resources/Info.plist`. Sparkle's
  `generate_keys` keeps it in the maintainer's login keychain, under the account `teams-pulse`.
  Secret: `SPARKLE_PRIVATE_KEY`.

To set up a repository:

1. In its **Settings › Environments**, create an environment named `release`. Under
   **Deployment protection rules**, turn on **Required reviewers** and add the maintainers. Under
   **Deployment branches and tags**, choose **Selected branches and tags** and add a rule for the
   tag pattern `v*`.
2. Run `scripts/make-release-keys.sh` in Terminal. For each secret it copies, click
   **Add environment secret** in the environment, paste the value, and name it as the script says.
   Paste each into your password manager too, as the backup.
3. Commit the public halves it wrote, `Resources/Info.plist` and `Resources/ReleaseRequirement.txt`,
   and push.

Never put either private key anywhere else, in a file you keep, a command-line argument or a log.
Don't change `SUPublicEDKey` or the release certificate either:

- If the update signing key leaks, generate a new one, and publish one release whose app has the new
  public key but is signed with the old key. `scripts/make-appcast.sh` refuses that mismatch, so sign
  that release by hand with Sparkle's `sign_update`. Sign later releases with the new key. If it's
  lost, the installed apps can't be updated anymore: publish a release with a new key and ask users
  to download it by hand once.
- If the release certificate leaks or is lost, delete it from your login keychain if it's still
  there, create a new one with `make signing-identity`, delete `Resources/ReleaseRequirement.txt` and
  run `scripts/make-release-keys.sh` again. Users lose Full Disk Access with the next update and have
  to grant it again, so say so in its release notes.

## License

Teams Pulse is licensed under the GNU General Public License, version 3 or later. By contributing,
you agree that your contributions are licensed under the same terms.
