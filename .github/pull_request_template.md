## What and why

<!-- What does this change, and what problem does it solve? Link related issues, for example "Fixes #12". -->

## Testing

<!-- How did you check it? For UI changes, add before and after screenshots made with `make screenshots`, which shows made-up chats. Never include screenshots, names, messages or chat IDs from your own Teams chats; to describe what you saw, share `--diagnose` output instead. -->

## Checklist

- [ ] `make test` passes
- [ ] Notification Center's database is still only read, never written
- [ ] Nothing about chats leaves the Mac, goes to the log, or is saved apart from the encrypted unread chats
- [ ] No real chat names, messages, chat IDs or screenshots in code, tests, comments or this pull request
- [ ] The README is updated if behavior or settings changed
