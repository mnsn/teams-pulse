#!/bin/bash
# Sets up the two keys that releases are signed with, once, on the maintainer's Mac. Then it copies
# each secret that the release workflow needs to the clipboard in turn, for you to paste into the
# release environment on GitHub. No private key is written to a file.
#   scripts/make-release-keys.sh
#
# - The release certificate is your "Teams Pulse Signing" certificate from your login keychain
#   (scripts/make-signing-identity.sh creates it if you have none). macOS ties Full Disk Access to
#   it, so every release must be signed with it. The designated requirement it gives the app goes to
#   Resources/ReleaseRequirement.txt, which the release workflow checks each release against.
# - The update signing key is an EdDSA key that Sparkle's generate_keys keeps in your login keychain,
#   under the account teams-pulse. Its public key goes to SUPublicEDKey in Resources/Info.plist:
#   installed apps accept only updates signed with it.
#
# It never replaces either key, and stops if those files name others. Run it again to copy the
# secrets again. See "Releasing" in CONTRIBUTING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Teams Pulse Signing"
ACCOUNT="teams-pulse"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PLIST="Resources/Info.plist"
REQUIREMENT_FILE="Resources/ReleaseRequirement.txt"
GENERATE_KEYS=".build/artifacts/sparkle/Sparkle/bin/generate_keys"

if [[ ! -t 0 ]]; then
    echo "Run this in Terminal: it waits for you between secrets." >&2
    exit 1
fi
wait_for_return() { read -r -p "$1 " _; }

WORK="$(mktemp -d)"
COPIED=false
cleanup() {
    rm -rf "$WORK"
    if $COPIED; then
        swift scripts/copy-secret.swift --clear || true
    fi
}
trap cleanup EXIT

# The release certificate, and the designated requirement that it gives the app.
if ! security find-certificate -c "$NAME" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    ./scripts/make-signing-identity.sh "$LOGIN_KEYCHAIN"
fi
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
cp /usr/bin/true "$WORK/probe"
if ! OUTPUT="$(codesign --force --sign "$NAME" --keychain "$LOGIN_KEYCHAIN" --identifier "$IDENTIFIER" --timestamp=none "$WORK/probe" 2>&1)"; then
    echo "$OUTPUT" >&2
    exit 1
fi
REQUIREMENT="$(codesign -d -r- "$WORK/probe" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ "$REQUIREMENT" != "identifier \"$IDENTIFIER\" and certificate "* ]]; then
    echo "Unexpected designated requirement: $REQUIREMENT" >&2
    exit 1
fi
if [[ -s "$REQUIREMENT_FILE" && "$(tr -d '\n' < "$REQUIREMENT_FILE")" != "$REQUIREMENT" ]]; then
    cat >&2 <<EOF
Your "$NAME" certificate isn't the one that releases are signed with.
  Releases ($REQUIREMENT_FILE): $(tr -d '\n' < "$REQUIREMENT_FILE")
  This Mac:  $REQUIREMENT
Every user would lose Full Disk Access with a release signed with it. Import the release
certificate from your backup into your login keychain instead. To change it anyway, delete
$REQUIREMENT_FILE and run this again.
EOF
    exit 1
fi
printf '%s\n' "$REQUIREMENT" > "$REQUIREMENT_FILE"

# The update signing key. generate_keys creates it unless it exists, and never replaces it. It prints
# its errors to standard output.
swift package resolve >/dev/null
if ! OUTPUT="$("$GENERATE_KEYS" --account "$ACCOUNT" 2>&1)" ||
    ! PUBLIC_KEY="$("$GENERATE_KEYS" --account "$ACCOUNT" -p 2>&1)"; then
    echo "${PUBLIC_KEY:-$OUTPUT}" >&2
    exit 1
fi
if [[ "$(printf '%s' "$PUBLIC_KEY" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" != 32 ]]; then
    echo "generate_keys printed something other than a public key: $PUBLIC_KEY" >&2
    exit 1
fi
CURRENT_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
if [[ -n "$CURRENT_KEY" && "$CURRENT_KEY" != "$PUBLIC_KEY" ]]; then
    cat >&2 <<EOF
SUPublicEDKey in $PLIST isn't the public key of your update signing key.
  $PLIST: $CURRENT_KEY
  This Mac (account $ACCOUNT): $PUBLIC_KEY
Installed apps accept only updates signed with the key in $PLIST. Import that key from your backup
with "$GENERATE_KEYS --account $ACCOUNT -f <file>" instead. To change it anyway (users would have
to download the next release by hand), empty SUPublicEDKey and run this again.
EOF
    exit 1
fi
# PlistBuddy would drop the comments in Info.plist, so edit its text.
KEY="$PUBLIC_KEY" perl -0pi -e 's{(<key>SUPublicEDKey</key>\s*<string>)[^<]*(</string>)}{$1$ENV{KEY}$2}' "$PLIST"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" != "$PUBLIC_KEY" ]]; then
    echo "Couldn't set SUPublicEDKey in $PLIST." >&2
    exit 1
fi

cat <<EOF
Release certificate: $REQUIREMENT
Update signing key:  $PUBLIC_KEY
Wrote both to $REQUIREMENT_FILE and $PLIST.

Now add three secrets to the release environment. On github.com, open the repository's
Settings › Environments › release, and under "Environment secrets" click "Add environment secret"
for each. This copies each value to the clipboard in turn, marked so that clipboard managers skip it,
and clears the clipboard at the end. For a backup, paste each into your password manager too.

EOF
# A new password each time: it only protects the copy on its way to GitHub.
P12_PASSWORD="$(openssl rand -base64 24)"
wait_for_return "Press Return to copy RELEASE_CERTIFICATE_P12 (macOS asks you to allow exporting the key: enter your login password and click Allow)."
TEAMS_PULSE_EXPORT_PASSWORD="$P12_PASSWORD" swift scripts/export-identity.swift "$NAME" "$LOGIN_KEYCHAIN" |
    swift scripts/copy-secret.swift
COPIED=true
wait_for_return "Copied. Paste it as RELEASE_CERTIFICATE_P12, then press Return to copy RELEASE_CERTIFICATE_PASSWORD."
printf '%s' "$P12_PASSWORD" | swift scripts/copy-secret.swift
wait_for_return "Copied. Paste it as RELEASE_CERTIFICATE_PASSWORD, then press Return to copy SPARKLE_PRIVATE_KEY (macOS asks you to allow security to use it: enter your login password and click Allow)."
security find-generic-password -s https://sparkle-project.org -a "$ACCOUNT" -w "$LOGIN_KEYCHAIN" |
    swift scripts/copy-secret.swift
wait_for_return "Copied. Paste it as SPARKLE_PRIVATE_KEY, then press Return to clear the clipboard."
swift scripts/copy-secret.swift --clear
COPIED=false

cat <<EOF

Done. Commit the public halves, which the app and the release workflow check against:
  git add $PLIST $REQUIREMENT_FILE
  git commit -m "Set the release signing keys"
EOF
