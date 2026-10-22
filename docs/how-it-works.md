# How Teams Pulse works

## Where the data comes from

When Teams shows a notification, macOS keeps a copy in Notification Center's database:

| | |
|---|---|
| File | `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (SQLite, WAL mode), protected by macOS: reading it needs Full Disk Access |
| Tables | `app(app_id, identifier, badge)`, `record(rec_id, app_id, uuid, data, request_date, request_last_date, delivered_date, presented, style, snooze_fire_date)`, and `categories`, `dbinfo`, `delivered`, `displayed`, `requests` |
| Teams' rows | `record` rows whose `app` is `com.microsoft.teams2` (new Teams) or `com.microsoft.teams` (classic) |
| Each row's `data` | A binary plist: `{app, date, req: {titl, body, iden, cate, usda, …}, uuid, …}`. `req.usda` is the notification's user info, archived with NSKeyedArchiver |

Teams' user info, as of Teams 26261 on macOS 27:

| Notification | `default_type` | `default_id` | Message ID | Title / body |
|---|---|---|---|---|
| 1:1 message | `chats` | `19:…@unq.gbl.spaces` | `default_options` JSON `messageId` | sender / text |
| Group or meeting chat message | `chats` | `19:…@thread.v2` (meeting chats `19:meeting_…`) | the same | chat name / `Sender: text` |
| Reaction to your message | `chats` | the 1:1 chat's ID | the same | `<emoji> <Name> reacted to your message` / empty |
| Channel post or reply | `channels` | JSON `{channelId: 19:…@thread.tacv2, replyChainId}` | `default_options` JSON `messageId` | `<Name> posted a new message`, `<Name> replied to …` / text |

Messages, unlike reactions, have a reply box: `textInputsend_type` `chats`, and
`textInputsend_options` JSON whose `convId` is the conversation ID again. That's how Teams Pulse
tells them apart. No field holds a link, so Teams Pulse builds one (see
[Opening a chat](#opening-a-chat)).

Notification Center keeps a limited number of notifications per app: 100 for Teams on the Mac this
was built on, about two days' worth, half of them channel posts. It drops old ones as new ones
arrive, and nothing in the database records whether you've read a chat: `app.badge` stays empty,
and `presented` and `style` don't track it. Reading a chat in Teams doesn't remove its notifications
either (Teams 26276 on macOS 27): they stay until Notification Center makes room, or you clear them.

Teams Pulse never changes the database. It opens it with a read-only SQLite connection, for a few
milliseconds per read, and never copies it. Like any SQLite reader, it takes brief shared locks and
updates SQLite's shared-memory index (`db-shm`) while it reads; neither changes any data.

## Deciding what's unread

The [table in the README](../README.md#what-counts-as-unread) lists the rules. In more detail
(`UnreadTracker` in `Sources/PulseCore`):

- **Arrival.** A chat message is unread if it was delivered after the chat was last read, or after
  Teams Pulse started (on its very first launch, everything already stored counts as read, so the
  counts are never wrong on day one). A message posted twice, for example after an edit, is counted
  once: messages are keyed by conversation and message ID.
- **Leaving Notification Center.** When notifications leave the database, either Notification
  Center made room for new ones, or you clicked or cleared them (or Teams withdrew them). Teams
  Pulse tells the two apart by the count: if the database holds as many Teams notifications as it
  ever has, and at least as many arrived as left, it made room, and those chats stay unread. Teams
  Pulse keeps them, although Notification Center no longer has them. Otherwise their chat is read up
  to them.
- **Expiry.** Unread messages older than **Keep Unread For** count as read, since Teams Pulse can't
  see which chat you read in Teams.
- **Teams' dock badge**, while **Mark All Read When Teams' Badge Clears** is on, as it is by default.
  Reading a chat in Teams leaves its notifications alone, but the badge gets smaller as you read, and
  disappears once nothing in Teams is unread. `lsappinfo info -long -only StatusLabel -app
  com.microsoft.teams2` reads it every 5 s while Teams runs, and when Teams comes to the front or
  leaves it, without any permission. It needs `-long`: without it, macOS 27's `lsappinfo` leaves
  `StatusLabel` out. When a badge Teams Pulse saw disappears, in the same Teams process, and is still
  gone 10 s later, everything delivered until it went counts as read. The wait passes over a badge
  that's back right away, as it might be while Teams reloads. No badge says nothing by itself: not
  while Teams isn't running, and not in the first minute after it starts, before it has set one. A
  badge that only gets smaller doesn't say which chat you read, so it changes nothing.
- **Launching again.** Notifications delivered after the last read Teams Pulse took in count as
  unread. It records when that read started every minute and when it quits, so a stretch when it
  couldn't read the database never counts as seen.

Counts are chats with unread messages, like Teams' own badge.

## What's saved

Unread chats must survive a restart even after Notification Center dropped them, so Teams Pulse
saves them, and only them, to `~/Library/Application Support/Teams Pulse/unread`:

- Per unread chat: its ID, kind and name, and its unread messages (ID, time, sender and text), at
  most 20.
- Sealed with AES-GCM (CryptoKit). The 256-bit key is a generic-password item in the login keychain,
  which macOS lets only Teams Pulse read, identified by its signature.
- Written atomically, readable only by you (0600), in a folder only you can open (0700) that Time
  Machine skips.
- A chat leaves the file as soon as it's read or expires, even while the database can't be read,
  and the file is deleted when nothing is unread. A file that can't be opened with the key is
  deleted, with the key.
- If the key can't be read when Teams Pulse starts (a locked keychain, or a declined prompt), the
  file is left alone and never overwritten. Teams Pulse tries again after 1, 5, 15 and 60 minutes,
  and merges what it loads, minus what was read since. Until then it doesn't record how far it has
  seen, so the next launch counts everything since as unread.

Next to it, `state.json` holds when Teams Pulse first ran, when it last ran and whether it ever had
access. Nothing else touches the disk.

## Updates are pushed, not polled

Notification Center keeps its database open. FSEvents reports a file's writes only once the writer
closes it, so it never sees them. Teams Pulse instead watches SQLite's write-ahead log (`db-wal`)
with **kqueue** (`EVFILT_VNODE`), which reports every write as it happens, and reads Teams' rows
again 0.3 s later, combining bursts. FSEvents on the `db2` folder reports the log being created or
replaced, so the kqueue watch can move to the new file. `db` itself is deliberately not opened for
watching: closing an extra file descriptor on a SQLite database drops the process's SQLite locks.

Notification Center writes for every app, so most writes change nothing for Teams; Teams Pulse
publishes only when Teams' notifications changed. Four timers exist, and none drives updates:

- a 15 s tick that refreshes relative times and expires old unread messages,
- a 60 s safety rescan that catches anything missed, for example after the Mac wakes from sleep,
- while Teams Pulse can't read the database, a check for access: every 2 s while the Full Disk
  Access window is open, every 30 s otherwise, and
- while **Mark All Read When Teams' Badge Clears** is on, as it is by default, a 5 s check of Teams'
  dock badge, which runs `lsappinfo` only while Teams runs (see
  [Deciding what's unread](#deciding-whats-unread)).

## Opening a chat

Clicking a chat opens Teams' documented link to a message in a chat, with Teams' own URL scheme so no
browser is involved, at the chat's oldest unread message:

```text
msteams:/l/message/<conversation ID, percent-encoded>/<message ID>?context=%7B%22contextType%22%3A%22chat%22%7D
```

It's opened with Teams itself as the handler. A message without an ID falls back to
`msteams:/l/chat/<conversation ID>/0`.

## Getting listed under Full Disk Access

macOS lists an app under **Full Disk Access**, switched off, once it has been denied a folder that
Full Disk Access protects. Notification Center's database doesn't get Teams Pulse listed: it's in a
group container, which macOS guards with its App Data protection
(`kTCCServiceSystemPolicyAppDataDetailed`, "found app sharing this group container" in `tccd`'s log),
and that denies quietly. So while it has no access, when its Full Disk Access window opens and when
you click **Open Privacy Settings**, Teams Pulse tries to list the folders Apple's Stocks and Safari
keep, as the [FullDiskAccess](https://github.com/inket/FullDiskAccess) package does. That reaches
`tccd` as a Full Disk Access check (`kTCCServiceSystemPolicyAllFiles`), which it denies without a
prompt. Without access, nothing is read. Whether macOS then lists the app was confirmed up to
macOS 14 by that package's author. On later versions, the window still explains how to add it with
**+**.

Organizations can skip the step entirely: a configuration profile with a
`com.apple.TCC.configuration-profile-policy` payload that allows `SystemPolicyAllFiles` for
`com.asaf.TeamsPulse`, with its designated requirement, grants the access when their MDM installs it.
`scripts/make-pppc-profile.sh` writes one for a built app.

## Summaries

The ✨ button on a chat asks Apple's on-device model for one sentence: what the chat is about, and
anything it asks of you (`Summarizer` in the app, `SummaryPrompt` in `PulseCore`).

- The session is created with `SystemLanguageModel.default`, the model that runs on the Mac. The
  framework also offers `PrivateCloudComputeLanguageModel`, which runs on Apple's servers; Teams
  Pulse never uses it, so nothing leaves the Mac.
- The prompt holds the chat's name and kind, and its unread messages with their senders, oldest
  first (its latest messages if none are unread). The newest messages that fit in 3,000 characters
  are kept, each cut at 600, to stay within the model's context window.
- A summary is kept in memory for as long as it covers the chat's newest message, and never saved.
- With **Show Message Previews** off, summaries are hidden too, since they'd reveal the same.
- Without Apple Intelligence (before macOS 26, on a Mac that can't run it, or with it turned off),
  the setting says why. An unsupported language, a refusal or a busy model shows a short note
  instead of a summary.
- FoundationModels is linked weakly, so the app still opens on macOS 15. Built with an SDK that
  doesn't have it, such as Xcode 16's, the app leaves the summarizer out, and the setting says that
  summaries need a build made with the macOS 26 SDK.

## Signing

macOS records each Full Disk Access grant with the app's **designated requirement**, the part of its
signature that says how to recognize it again, and checks the running app against it.

- An ad-hoc signature's designated requirement is its code hashes: an ad-hoc build of Copilot Pulse
  has `cdhash H"5de6…" or cdhash H"d166…"`. Apple's
  [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
  puts it this way: ad hoc signed code "has a DR but it's tied to that specific version of the code",
  so "macOS can't track this authorization across versions of your app". Every build loses Full
  Disk Access, although System Settings may still show the switch on. macOS keeps the requirement of
  the build you allowed, and turning the switch off and on keeps it too: remove Teams Pulse from the
  list, or run `tccutil reset SystemPolicyAllFiles com.asaf.TeamsPulse`, and add it again.
- Signed with a certificate, the requirement names the certificate instead:
  `identifier "com.asaf.TeamsPulse" and certificate leaf = H"<the certificate's hash>"`. A rebuilt
  app with different code hashes still satisfies it (`codesign -R=<requirement> --verify` passes), so
  macOS keeps the access.

Builds from source are signed ad hoc (`scripts/build-app.sh`, through `scripts/sign-app.sh`), with
the hardened runtime and no timestamp, so signing makes no network request. Each build needs Full
Disk Access again, but there's no key on the Mac that anything could sign as Teams Pulse with. The
keychain item for the unread chats trusts the app by its signature too, so macOS may ask whether a
new build may use it; declined, the saved chats are left alone.

### An optional certificate for builds from source

`scripts/make-signing-identity.sh` (`make signing-identity`) creates a certificate, self-signed, for
code signing only, valid for 10 years, in the login keychain, and `scripts/build-app.sh` then signs
every build with it, so Full Disk Access survives rebuilds. Nothing has to trust the certificate:
macOS matches the certificate itself. `--delete` deletes it and its key, and builds are signed ad hoc
again.

Matching a certificate is only as strong as the private key behind it: anything that can sign with
the key can sign itself as `com.asaf.TeamsPulse`, satisfy the requirement, and get the Full Disk
Access the user gave Teams Pulse. So no app may use the key without asking:

- `security import` can't make such a key. With `-T /usr/bin/codesign`, codesign may use the key
  silently; without it, `/usr/bin/security`, the app that imported it, may. Either way, any program
  running as the user could have it sign. `scripts/signing-key.swift` imports the key with an access
  list that trusts no app, so codesign asks for the login password every time, and as
  non-extractable, so it can't be exported even with the password.
- **Always Allow** in that prompt would add codesign to the list. `scripts/build-app.sh` reads the
  list before every build, and again after signing (without prompting), and refuses to go on while
  any app is on it. `scripts/make-signing-identity.sh --replace` swaps such a certificate for a new
  one, and `--check` reads the list.
- Sparkle.framework is signed ad hoc, so each build uses the key once, and asks once. With library
  validation off (below), the app loads the framework whoever signed it, and the app's own signature
  records the framework's exact code hash.
- The certificate and its key are made in memory and reach the keychain through a pipe, never a file.

Only CI's throwaway keychains (`scripts/ci-signing-identity.sh`) let codesign use their key without
asking, since nothing could answer a prompt there.

### Releases

Releases are signed with a certificate too, all with the same one, **Teams Pulse Release**, which
isn't on any Mac. `scripts/make-release-keys.sh` makes it in memory, once, for the `release`
environment's secrets and the maintainer's password manager, so only the release workflow's
approved job can sign with it. That job checks that the signed app has the designated requirement in
`Resources/ReleaseRequirement.txt`, so a release can't quietly cost everyone their access, and
`scripts/check-app.sh` fails if a release's requirement names code hashes. CI, and the release's
build job, sign with a throwaway certificate instead.

Changing the certificate, or the bundle identifier, loses Full Disk Access once: remove Teams Pulse
from the list (or reset its entry with `tccutil`, as above) and add it again. That's also what
happens when a copy you built updates itself to a release.

### The hardened runtime and library validation

Every build runs with the hardened runtime, so other processes can't use Teams Pulse's Full Disk
Access by injecting code into it: macOS ignores `DYLD_` environment variables for it, such as
`DYLD_INSERT_LIBRARIES`, and doesn't let debuggers attach.

The hardened runtime also turns on library validation, which loads only libraries signed by Apple
or by the app's own team. A self-signed certificate has no team, so macOS would refuse Sparkle,
even signed with the same certificate ("mapping process and mapped file (non-platform) have
different Team IDs"). The app's one entitlement, `com.apple.security.cs.disable-library-validation`
in `Resources/TeamsPulse.entitlements`, turns that check off. The cost: macOS recognizes the app by
its own executable's signature, and with library validation off, the app loads whatever its
Sparkle.framework holds. So anything running as you could copy the app anywhere, put its own code in
the copy's framework, and run the copy with Teams Pulse's Full Disk Access, without touching the
installed app; where the app is installed doesn't change that. The same weakness in another app was
published as [CVE-2025-4081](https://cert.pl/en/posts/2025/05/tcc-bypass/)
([SECURITY.md](../SECURITY.md#how-the-app-is-signed)). Any of these would close it: a Developer ID
certificate, which would make the entitlement unnecessary; running Sparkle in a process of its own,
so that the app loads no libraries but Apple's; or a library load constraint (macOS 14 and later), a
rule in the app's signature that lets it load only the Sparkle it ships with.

## Updating the app

Teams Pulse updates itself with [Sparkle](https://sparkle-project.org) 2, embedded as
`Contents/Frameworks/Sparkle.framework`, without the XPC services that only sandboxed apps need.

- **Only if you allow it.** Sparkle asks on the second launch whether to check automatically, and
  then checks once a day. **Check for Updates…** checks right away. A build without `SUPublicEDKey`
  in its `Info.plist` never checks, and has no update settings.
- **What it fetches**: `appcast.xml` from
  `https://github.com/mnsn/teams-pulse/releases/latest/download/`, and the zip that it names.
  These are the app's only network requests. Its own code has no networking (`scripts/check-app.sh`
  checks the symbols the binary imports), and Sparkle's anonymous system profiling stays off.
- **What it accepts**: only an appcast and a zip signed with the project's EdDSA key, and it checks
  the zip before unpacking it. [SECURITY.md](../SECURITY.md#how-updates-are-verified) has the
  details.
- **Full Disk Access survives**, because every release is signed with the same certificate.

## When the formats change

Both formats are undocumented, so every read is checked:

- **The database's layout.** `PRAGMA table_info` lists its tables and columns first. Without
  `app(app_id, identifier)` or `record(app_id, data)`, Teams Pulse reports which are missing and shows
  nothing rather than guess. The other columns are optional.
- **Each notification.** Records that aren't a plist, have no request, user info or `default_type`,
  or are chat notifications without a valid `19:…@…` conversation ID are counted. If none of the
  stored Teams notifications can be read, the lists say Teams' notifications have changed; if more
  than a quarter can't, they say how many. Well-formed notifications of kinds Teams Pulse doesn't
  show, such as calls, are set aside without counting against it, unless they look like chat
  messages (a reply box, or a chat's ID): that's more likely a renamed chat type, so they count.
- **Archives** are decoded with secure coding and plist classes only, so an unexpected class makes a
  record unreadable instead of being instantiated.

`--diagnose` and **Copy Diagnostics** describe all of this by structure only: table and field names,
counts, and the shapes of values, such as `<oneOnOne ID>`, `<13-digit>` or
`json {actionType: view, messageId: <13-digit>, userContextId: <guid>}`. They also show Teams' dock
badge as Teams Pulse reads it.

## Why not Microsoft Graph or a server?

Graph would need your organization to consent to an app, lets an app poll a user's chats only once
a day, and delivers changes as they happen only to a public webhook, so a server. Organizations
that use Teams also rarely allow chat content, or summaries of it, to leave their Macs. Notification
Center already has everything a glance needs, on the Mac.
