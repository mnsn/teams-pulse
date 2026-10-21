#!/bin/bash
# Creates "Teams Pulse Signing", a self-signed code-signing certificate, in your login keychain. It's
# optional: without it, builds are signed ad hoc, and macOS ties Full Disk Access to that exact build,
# so each rebuild needs the access again. With it, scripts/build-app.sh signs every build with it, the
# app's designated requirement names the certificate rather than the code's hashes, and macOS keeps
# Teams Pulse's Full Disk Access across rebuilds. Run it once per Mac.
#   scripts/make-signing-identity.sh [--replace | --delete | --check] [keychain]
#
# The key is as powerful as that access: anything that can sign with it can sign itself as Teams Pulse
# and get the Full Disk Access you gave Teams Pulse. So no app may use it without asking, not even
# codesign, and it can't be exported: each build asks for your login password. Click Allow, never
# Always Allow. scripts/build-app.sh refuses to sign with a key that some app may use without asking,
# and checks again after signing.
#   --replace   deletes the certificate and its key, such as one an earlier version of this script
#               made, which let codesign use the key without asking, and makes a new one. Then give
#               the next build Full Disk Access again.
#   --delete    only deletes them: builds are signed ad hoc again.
#   --check     says, without asking anything, whether some app may use the key without asking.
#
# TEAMS_PULSE_SIGNING_IDENTITY picks another name. With TEAMS_PULSE_KEYCHAIN_PASSWORD set, for a
# throwaway keychain of its own (CI, scripts/ci-signing-identity.sh), codesign may use the key without
# asking.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${TEAMS_PULSE_SIGNING_IDENTITY:-Teams Pulse Signing}"
MODE=create
case "${1:-}" in
    --replace) MODE=replace; shift ;;
    --delete) MODE=delete; shift ;;
    --check) MODE=check; shift ;;
    -*) echo "Usage: $0 [--replace | --delete | --check] [keychain]" >&2; exit 2 ;;
esac
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"
OPEN_TO_CODESIGN=false
if [[ -n "${TEAMS_PULSE_KEYCHAIN_PASSWORD:-}" ]]; then
    if [[ "$KEYCHAIN" == *"/login.keychain"* ]]; then
        echo "TEAMS_PULSE_KEYCHAIN_PASSWORD is only for a keychain of its own, not the login keychain." >&2
        exit 1
    fi
    OPEN_TO_CODESIGN=true
fi
# macOS's own LibreSSL, on every Mac. Homebrew's OpenSSL 3, the default openssl on some Macs and on
# GitHub's macOS 26 runners, writes PKCS #12 files with AES and SHA-256, which older versions of
# macOS can't import.
OPENSSL=/usr/bin/openssl
signing_key() { swift -suppress-warnings scripts/signing-key.swift "$@"; }

if [[ $MODE == check ]]; then
    STATUS=0
    signing_key check "$NAME" "$KEYCHAIN" || STATUS=$?
    if [[ $STATUS -eq 0 ]]; then
        echo "No app may use the \"$NAME\" key without asking."
    elif [[ $STATUS -eq 3 ]]; then
        echo "So anything running as you could sign itself as Teams Pulse, and get the Full Disk Access you" >&2
        echo "gave it. Run scripts/make-signing-identity.sh --replace, or --delete to build ad hoc." >&2
    elif [[ $STATUS -eq 4 ]]; then
        echo "So builds are signed ad hoc." >&2
    fi
    exit $STATUS
fi
if [[ $MODE == replace || $MODE == delete ]]; then
    signing_key delete "$NAME" "$KEYCHAIN"
    if [[ $MODE == delete ]]; then
        echo "Builds are signed ad hoc now: give each new build Full Disk Access again."
        exit 0
    fi
else
    STATUS=0
    OUTPUT="$(signing_key check "$NAME" "$KEYCHAIN" 2>&1)" || STATUS=$?
    if [[ $STATUS -eq 0 ]] || { $OPEN_TO_CODESIGN && [[ $STATUS -eq 3 ]]; }; then
        echo "\"$NAME\" is already in $KEYCHAIN. Nothing to do."
        exit 0
    elif [[ $STATUS -eq 3 ]]; then
        echo "$OUTPUT" >&2
        cat >&2 <<EOF
So any program running as you could sign itself with it as Teams Pulse, and get the Full Disk Access
you gave Teams Pulse. Replace it with a certificate that every app has to ask to use:
  scripts/make-signing-identity.sh --replace
or delete it, and build ad hoc: scripts/make-signing-identity.sh --delete
EOF
        exit 1
    elif [[ $STATUS -ne 4 ]]; then
        echo "$OUTPUT" >&2
        echo "To start over with a new \"$NAME\", run: scripts/make-signing-identity.sh --replace" >&2
        exit 1
    fi
fi

# A leaf certificate for code signing only, valid for 10 years. Nothing needs to trust it: macOS
# matches the certificate itself against the app's designated requirement. The key and the certificate
# stay in variables, and reach openssl and the keychain through pipes, never files.
CONFIG="[ req ]
distinguished_name = subject
prompt = no
x509_extensions = codesigning
[ subject ]
CN = $NAME
[ codesigning ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash"
KEY="$("$OPENSSL" genrsa 3072 2>/dev/null)"
CERTIFICATE="$("$OPENSSL" req -x509 -new -sha256 -days 3650 -config <(printf '%s\n' "$CONFIG") -key <(printf '%s\n' "$KEY"))"
P12_PASSWORD="$("$OPENSSL" rand -hex 16)"
P12="$("$OPENSSL" pkcs12 -export -name "$NAME" -inkey <(printf '%s\n' "$KEY") -in <(printf '%s\n' "$CERTIFICATE") \
    -passout "file:"<(printf '%s\n' "$P12_PASSWORD") | base64)"
KEY=""

if $OPEN_TO_CODESIGN; then
    printf '%s\n%s\n' "$P12_PASSWORD" "$P12" | signing_key import "$KEYCHAIN" "$NAME" --trust /usr/bin/codesign
    # Lets Apple's tools use every key in the keychain, which is why it's only for a keychain of its own.
    security set-key-partition-list -S apple-tool:,apple: -s -k "$TEAMS_PULSE_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    # Sign a throwaway copy of a tool to check that the identity works, and show what macOS will match.
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cp /usr/bin/true "$WORK/probe"
    codesign --force --sign "$NAME" --keychain "$KEYCHAIN" --timestamp=none "$WORK/probe"
    REQUIREMENT="$(codesign -d -r- "$WORK/probe" 2>&1 | sed -n 's/^#* *designated => //p')"
    echo "Created \"$NAME\" in $KEYCHAIN."
    echo "Code signed with it is identified by: $REQUIREMENT"
else
    printf '%s\n%s\n' "$P12_PASSWORD" "$P12" | signing_key import "$KEYCHAIN" "$NAME"
    signing_key check "$NAME" "$KEYCHAIN"
    LEAF="$(printf '%s\n' "$CERTIFICATE" | "$OPENSSL" x509 -outform DER | shasum -a 1 | cut -d ' ' -f 1)"
    echo "Created \"$NAME\" in $KEYCHAIN (certificate leaf = H\"$LEAF\")."
    echo "No app may use its key without asking, and it can't be exported. Each build asks for your login"
    echo "password so that codesign can sign with it: click Allow, never Always Allow. Give the next build"
    echo "Full Disk Access; later builds keep it."
fi
