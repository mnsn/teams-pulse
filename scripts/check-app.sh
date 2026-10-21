#!/bin/bash
# Checks a built "Teams Pulse.app" before it ships: its signatures are valid, with the hardened runtime
# and only the entitlement it needs; its designated requirement names a certificate rather than code
# hashes (so Full Disk Access survives updates); it embeds Sparkle (the updater) and loads it; it's set
# up for signed updates; and on this Mac it runs and sorts the demo chats into the expected lists.
#   scripts/check-app.sh [app] [--universal] [--release] [--allow-ad-hoc]
#   (default: build/Teams Pulse.app)
#   --universal     requires code for both Apple silicon and Intel (releases and CI).
#   --release       also requires the update signing key in Info.plist (scripts/make-release-keys.sh).
#   --allow-ad-hoc  accepts an ad-hoc signature, for a quick local check.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Teams Pulse.app"
UNIVERSAL=false
RELEASE=false
ALLOW_AD_HOC=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --release) RELEASE=true ;;
        --allow-ad-hoc) ALLOW_AD_HOC=true ;;
        -*) echo "Unknown option: $arg" >&2; exit 2 ;;
        *) APP="$arg" ;;
    esac
done
BIN="$APP/Contents/MacOS/TeamsPulse"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
PLIST="$APP/Contents/Info.plist"

fail() {
    echo "$APP: $1" >&2
    exit 1
}
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

# Every signature, and each nested one on its own so a failure names it.
codesign --verify --deep --strict "$APP" || fail "has an invalid signature."
for code in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
    codesign --verify --strict "$code" || fail "${code#"$APP/"} has an invalid signature."
done
codesign -dv "$APP" 2>&1 | grep '^CodeDirectory.*flags=.*runtime' >/dev/null || fail "isn't signed with the hardened runtime."
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ "$REQUIREMENT" == *cdhash* ]]; then
    $ALLOW_AD_HOC || fail "is signed ad hoc (designated requirement: $REQUIREMENT), so Full Disk Access won't survive the next build. Run 'make signing-identity' and build again."
elif [[ "$REQUIREMENT" != *'identifier "com.asaf.TeamsPulse"'* || "$REQUIREMENT" != *certificate* ]]; then
    fail "has an unexpected designated requirement: $REQUIREMENT"
fi
# Only the entitlement that lets the hardened runtime load Sparkle (see Resources/TeamsPulse.entitlements).
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || true)"
[[ "$ENTITLEMENTS" == '{"com.apple.security.cs.disable-library-validation":true}' ]] ||
    fail "has unexpected entitlements: ${ENTITLEMENTS:-none}"

# Sparkle, with its symlinks and without the XPC services, loaded through the app's Frameworks.
[[ -L "$FRAMEWORK/Versions/Current" && -L "$FRAMEWORK/Sparkle" ]] || fail "has no Sparkle.framework, or it lost its symlinks."
[[ ! -e "$FRAMEWORK/Versions/B/XPCServices" ]] || fail "still has Sparkle's XPC services."
[[ -f "$APP/Contents/Resources/Sparkle-LICENSE.txt" ]] || fail "doesn't include Sparkle's license."
otool -L "$BIN" | grep '@rpath/Sparkle.framework/' >/dev/null || fail "doesn't link Sparkle."
ARCHS="$(lipo -archs "$BIN")"
REQUIRED_ARCHS="$(uname -m)"
if $UNIVERSAL; then
    REQUIRED_ARCHS="arm64 x86_64"
fi
for arch in $REQUIRED_ARCHS; do
    if [[ " $ARCHS " != *" $arch "* ]]; then
        fail "${BIN#"$APP/"} has no $arch code (only $ARCHS)."
    fi
    [[ " $(lipo -archs "$FRAMEWORK/Versions/B/Sparkle") " == *" $arch "* ]] || fail "Sparkle has no $arch code."
    otool -arch "$arch" -l "$BIN" | grep 'path @executable_path/../Frameworks ' >/dev/null ||
        fail "${BIN#"$APP/"} ($arch) has no @executable_path/../Frameworks rpath."
done

# Signed updates only, from the feed in the latest GitHub release; Sparkle compares CFBundleVersion.
[[ -n "$(plist SUFeedURL)" ]] || fail "has no SUFeedURL."
KEY_BYTES="$(plist SUPublicEDKey | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
if [[ "$KEY_BYTES" != 32 ]]; then
    if $RELEASE || [[ -n "$(plist SUPublicEDKey)" ]]; then
        fail "has no valid SUPublicEDKey. Run scripts/make-release-keys.sh (see \"Releasing\" in CONTRIBUTING.md)."
    fi
    echo "warning: $APP has no SUPublicEDKey yet, so it won't check for updates." >&2
fi
[[ "$(plist SURequireSignedFeed)" == true && "$(plist SUVerifyUpdateBeforeExtraction)" == true ]] ||
    fail "doesn't require signed updates and appcasts."
for key in SUEnableSystemProfiling SUEnableDownloaderService SUEnableInstallerLauncherService; do
    [[ -z "$(plist "$key")" ]] || fail "sets $key."
done
[[ "$(plist CFBundleIdentifier)" == com.asaf.TeamsPulse ]] || fail "has another bundle identifier."
[[ "$(plist LSUIElement)" == true ]] || fail "isn't a menu-bar-only app (LSUIElement)."
[[ "$(plist CFBundleVersion)" == "$(plist CFBundleShortVersionString)" ]] ||
    fail "has a CFBundleVersion that isn't its version."
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || fail "has no icon."

# Nothing about chats may leave the Mac. The app's own code has no networking: only Sparkle, for
# update checks, does.
if nm -u "$BIN" 2>/dev/null | grep -E 'nw_connection|URLSession|CFNetwork|NSURLConnection' >/dev/null; then
    fail "uses networking APIs in its own code."
fi
# Summaries need macOS 26's FoundationModels; linked weakly, the app still opens on macOS 15. (No
# grep -q in these pipes: with pipefail, its early exit could make a match look like none.)
if otool -l "$BIN" | grep -B2 'FoundationModels.framework' | grep 'cmd LC_LOAD_DYLIB$' >/dev/null; then
    fail "links FoundationModels strongly, so it won't open before macOS 26."
fi

# Running it shows that it launches, with Sparkle loaded under the hardened runtime.
"$BIN" --help >/dev/null || fail "doesn't launch (or can't load Sparkle)."
make -s demo-check PULSE="$BIN"
echo "Checked $APP: valid signatures, hardened runtime, $ARCHS, Sparkle embedded and loaded, designated requirement: $REQUIREMENT"
