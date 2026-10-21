#!/bin/bash
# Imports the release certificate into a new keychain, for the release workflow's approved job, and
# prints the keychain's path. The certificate comes from the environment: RELEASE_CERTIFICATE_P12
# (base64 of a PKCS #12 file) and RELEASE_CERTIFICATE_PASSWORD, the release environment's secrets.
#   scripts/import-release-identity.sh [folder]   (default: a new temporary folder)
# Delete the keychain when done with `security delete-keychain <path>`.
set -euo pipefail

: "${RELEASE_CERTIFICATE_P12:?The release environment has no RELEASE_CERTIFICATE_P12 secret.}"
: "${RELEASE_CERTIFICATE_PASSWORD:?The release environment has no RELEASE_CERTIFICATE_PASSWORD secret.}"
NAME="${TEAMS_PULSE_SIGNING_IDENTITY:-Teams Pulse Signing}"
FOLDER="${1:-$(mktemp -d)}"
KEYCHAIN="$FOLDER/teams-pulse-release.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
P12="$(mktemp "$FOLDER/identity.XXXXXX")"
# On failure, nothing is left behind, since the caller never learns the keychain's path.
trap 'status=$?; rm -f "$P12"; if [[ $status -ne 0 ]]; then security delete-keychain "$KEYCHAIN" 2>/dev/null || true; fi' EXIT
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

# security import only reads files, so the PKCS #12 exists on the runner's disk for this moment only.
printf '%s' "$RELEASE_CERTIFICATE_P12" | base64 --decode > "$P12"
security import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$RELEASE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
rm -f "$P12"
# Lets codesign use the key without a prompt, which a runner couldn't answer.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

if ! security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "RELEASE_CERTIFICATE_P12 holds no certificate named \"$NAME\"." >&2
    exit 1
fi
echo "$KEYCHAIN"
