#!/bin/bash
# Checks a built "Teams Pulse.app": its signature is valid and uses the hardened runtime, its designated
# requirement names a certificate rather than code hashes (so Full Disk Access survives the next build),
# its bundle settings are right, and it runs and sorts the demo chats into the expected lists.
#   scripts/check-app.sh [app] [--allow-ad-hoc]   (default: build/Teams Pulse.app)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Teams Pulse.app"
ALLOW_AD_HOC=false
for arg in "$@"; do
    case "$arg" in
        --allow-ad-hoc) ALLOW_AD_HOC=true ;;
        *) APP="$arg" ;;
    esac
done
BIN="$APP/Contents/MacOS/TeamsPulse"
PLIST="$APP/Contents/Info.plist"

fail() {
    echo "$APP: $1" >&2
    exit 1
}
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

codesign --verify --deep --strict "$APP" || fail "has an invalid signature."
codesign -dv "$APP" 2>&1 | grep '^CodeDirectory.*flags=.*runtime' >/dev/null || fail "isn't signed with the hardened runtime."
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ "$REQUIREMENT" == *cdhash* ]]; then
    $ALLOW_AD_HOC || fail "is signed ad hoc (designated requirement: $REQUIREMENT), so Full Disk Access won't survive the next build. Run 'make signing-identity' and build again."
elif [[ "$REQUIREMENT" != *'identifier "com.asaf.TeamsPulse"'* || "$REQUIREMENT" != *certificate* ]]; then
    fail "has an unexpected designated requirement: $REQUIREMENT"
fi

[[ "$(plist CFBundleIdentifier)" == com.asaf.TeamsPulse ]] || fail "has another bundle identifier."
[[ "$(plist LSUIElement)" == true ]] || fail "isn't a menu-bar-only app (LSUIElement)."
[[ "$(plist CFBundleVersion)" == "$(plist CFBundleShortVersionString)" ]] || fail "has a CFBundleVersion that isn't its version."
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || fail "has no icon."
# Nothing about chats may leave the Mac: the app has no network code to begin with.
if nm -u "$BIN" 2>/dev/null | grep -E 'nw_connection|URLSession|CFNetwork|NSURLConnection' >/dev/null; then
    fail "uses networking APIs."
fi
# Summaries need macOS 26's FoundationModels; linked weakly, the app still opens on macOS 15.
if otool -l "$BIN" | grep -B2 'FoundationModels.framework' | grep -q 'cmd LC_LOAD_DYLIB$'; then
    fail "links FoundationModels strongly, so it won't open before macOS 26."
fi

"$BIN" --help >/dev/null || fail "doesn't run its command-line mode."
make -s demo-check PULSE="$BIN"
echo "Checked $APP: valid signature, hardened runtime, $(lipo -archs "$BIN"), designated requirement: $REQUIREMENT"
