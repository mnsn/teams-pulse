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
- **Signing**: every build is signed with a self-signed certificate, so Full Disk Access survives
  rebuilds.
- **Private**: reads Notification Center's database read-only, and makes no network connections.
