# Changelog

## 0.1.0 - Unreleased

The first version.

- **Menu bar**: two items, Chats (1:1) and Group Chats (group and meeting chats), each with the number
  of chats with unread messages and its own list.
- **Lists**: each unread chat with its latest message, how long ago it arrived and how many are
  unread, plus read chats from the last day under Recent.
- **One click to a chat**: opens it in Teams at its oldest unread message.
- **Summaries**: a one-sentence summary of a chat on request, from Apple's on-device model.
- **Unread chats survive**: kept after Notification Center drops their notifications, and across
  restarts, encrypted on disk until they're read.
- **Full Disk Access**: a window walks you through granting it, and notices when it's granted.
- **Updates**: Teams Pulse updates itself, with [Sparkle](https://sparkle-project.org). The second
  time you open it, it asks whether to check for updates automatically, once a day.
  **Check for Updates…** in its settings checks right away. It installs only updates that come from
  this project's GitHub releases and are signed with the project's key.
- **Signing**: every release is signed with the same certificate, so Full Disk Access survives
  updates. Builds from source are signed ad hoc, or, to keep Full Disk Access across rebuilds, with a
  certificate of your own (`make signing-identity`). No program can use either certificate's key
  unasked, so none can sign itself as Teams Pulse to get its access.
- **Private**: reads Notification Center's database read-only. The only network requests are the
  update checks and downloads, from GitHub. Nothing about your chats is sent.
- A universal app for Apple silicon and Intel Macs with macOS 15 or later. Summaries need macOS 26.
