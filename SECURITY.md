# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/mnsn/teams-pulse/security/advisories/new),
not in a public issue.

Describe what's affected, how to reproduce it and the impact you expect, with made-up chats or
`--diagnose` output, never names, messages or chat IDs from real chats. This is a personal project
maintained in spare time, so a reply may take a few days.

## Scope

Teams Pulse holds Full Disk Access to read the Teams notifications in Notification Center's
database. It keeps unread chats on disk, encrypted, until they're read, and makes summaries on the
Mac. Its only network requests are for its own updates, from this project's GitHub releases. Worth
reporting:

- any way it could send anything about chats off the Mac, or expose it to other users or apps on
  the Mac (its saved unread chats, its log, its summaries),
- any way another app could use Teams Pulse's Full Disk Access, such as by injecting code into it,
- any way it could change Notification Center's data,
- any way to make it install an update that the release workflow here didn't sign, and
- problems with how the build scripts and workflows here create, sign or publish the app.

Vulnerabilities in Microsoft Teams itself should go to the
[Microsoft Security Response Center](https://msrc.microsoft.com/report/vulnerability/new).

## Supported versions

Only the latest release, and the latest commit on `main`, are supported.

## How the app is signed

macOS ties Full Disk Access to the app's signing certificate, so every release is signed with the
same one, and updates keep the access. The project has no Apple Developer ID, so the certificate is
self-signed: it tells macOS that a new version comes from the same place as the last, but not who
made it, and the app isn't notarized.

- The app runs with the hardened runtime, so other processes can't inject code into it with
  `DYLD_` environment variables or a debugger, and use its Full Disk Access that way.
- Library validation is off (`com.apple.security.cs.disable-library-validation`, the app's only
  entitlement). With it on, macOS loads only libraries signed by Apple or by the app's own team,
  and a self-signed certificate has no team, so macOS would refuse even the app's own copy of
  Sparkle, its updater. The trade-off: software that can change the files inside the app, such as
  malware running as you, could make it load other code and use its Full Disk Access. Keep the app
  in `/Applications`. A Developer ID would let the app turn library validation back on.
- `scripts/check-app.sh` checks each build for these settings, and CI runs it.
- Anything that can sign with the certificate's key can sign itself as Teams Pulse and inherit its
  Full Disk Access. So the release certificate, **Teams Pulse Release**, is on no Mac: it's made in
  memory, once, and kept only in the `release` environment's secrets and the maintainer's password
  manager.
- Builds from source are signed ad hoc, so there's no key on the Mac that could sign as them. The
  optional certificate that keeps their Full Disk Access across rebuilds (`make signing-identity`)
  trusts no app to use its key, not even codesign, which asks for the password every time, and its
  key can't be exported. `make app` refuses to sign with a key that some app may use without asking.

## How updates are verified

The app updates itself with [Sparkle](https://sparkle-project.org). It reads the appcast, a small
file that describes the latest release, from
`https://github.com/mnsn/teams-pulse/releases/latest/download/appcast.xml`, and downloads the
update from the same release.

- The release workflow signs both the update's zip and the appcast with an EdDSA (Ed25519) key.
  The app has the public key in its `Info.plist` (`SUPublicEDKey`).
- The app rejects an appcast whose signature doesn't match (`SURequireSignedFeed`), with no
  fallback after a while (`SUSignedFeedFailureExpirationInterval` is 0). It checks the zip's
  signature before it even unpacks it (`SUVerifyUpdateBeforeExtraction`).
- The EdDSA signature is the main protection. The certificate is what keeps Full Disk Access.

The private keys of both exist only in the maintainer's password manager and in the secrets of the
`release` environment in GitHub Actions: `RELEASE_CERTIFICATE_P12` and
`RELEASE_CERTIFICATE_PASSWORD` for the certificate, and `SPARKLE_PRIVATE_KEY` for the update signing
key. `scripts/make-release-keys.sh` makes them in memory, so they're never written to a file or a
keychain, where any program running as the maintainer could use them. Only the job that signs a
release can read the secrets, and the environment waits for a maintainer to approve each release.
That job deletes its copy of the certificate right after signing. Before publishing, it checks that
the certificate is the one every release uses (`Resources/ReleaseRequirement.txt`) and that the
signatures match the public key in `Info.plist`.

If the update signing key were lost, users would have to download a new version by hand once,
because the app can't accept an update signed with a different key. If the certificate were lost, a
release signed with a new one would lose Full Disk Access, and users would have to grant it again.

## Verifying a download

Releases are built and published by the
[release workflow](https://github.com/mnsn/teams-pulse/blob/main/.github/workflows/release.yml)
from the tagged source, with a build provenance attestation. To check that a `Teams-Pulse.zip` you
downloaded came from it, use the [GitHub CLI](https://cli.github.com):

```sh
gh attestation verify Teams-Pulse.zip --repo mnsn/teams-pulse
```

The release's `appcast.xml` has an attestation too. Each release also lists the zip's SHA-256,
which `shasum -a 256 Teams-Pulse.zip` prints.
