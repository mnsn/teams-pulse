#!/bin/bash
# Signs a packaged release with the release certificate, in the release workflow's approved job:
# unzips build/release/Teams-Pulse.zip, signs the app again with the certificate that
# TEAMS_PULSE_SIGNING_IDENTITY and TEAMS_PULSE_SIGNING_KEYCHAIN name, checks it, and zips it again,
# with its new SHA-256 in Teams-Pulse.zip.sha256 and notes.md.
#   scripts/sign-release.sh [release dir]   (default: build/release)
# Every release must be signed with the same certificate: macOS ties Full Disk Access to the app's
# designated requirement, which names it. So the result must match Resources/ReleaseRequirement.txt,
# which scripts/make-release-keys.sh writes.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/release}"
ZIP="Teams-Pulse.zip"
APP="build/Teams Pulse.app"
EXPECTED_FILE="Resources/ReleaseRequirement.txt"

if [[ ! -s "$EXPECTED_FILE" ]]; then
    echo "$EXPECTED_FILE is missing. Run scripts/make-release-keys.sh (see \"Releasing\" in CONTRIBUTING.md)." >&2
    exit 1
fi
EXPECTED="$(tr -d '\n' < "$EXPECTED_FILE")"

(cd "$OUT" && shasum -a 256 -c "$ZIP.sha256")
OLD_SHA="$(cut -d ' ' -f 1 "$OUT/$ZIP.sha256")"
rm -rf "$APP"
ditto -x -k "$OUT/$ZIP" build

./scripts/sign-app.sh "$APP"
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ "$REQUIREMENT" != "$EXPECTED" ]]; then
    echo "The app is signed with another certificate than earlier releases, so every user would lose" >&2
    echo "Full Disk Access. Expected: $EXPECTED" >&2
    echo "Got:      $REQUIREMENT" >&2
    exit 1
fi
./scripts/check-app.sh "$APP" --universal --release

rm -f "$OUT/$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
(cd "$OUT" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
SHA256="$(cut -d ' ' -f 1 "$OUT/$ZIP.sha256")"
sed -i '' "s/$OLD_SHA/$SHA256/" "$OUT/notes.md"
grep -q "$SHA256" "$OUT/notes.md" || { echo "notes.md doesn't name the new SHA-256." >&2; exit 1; }
echo "Signed $OUT/$ZIP with the release certificate: $REQUIREMENT"
