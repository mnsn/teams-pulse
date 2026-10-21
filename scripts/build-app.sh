#!/bin/bash
# Builds "Teams Pulse.app" into ./build, for this Mac's architecture, signed with the certificate that
# scripts/make-signing-identity.sh creates.
#   --universal   builds for both Apple silicon and Intel instead.
#   --install     also copies it to ~/Applications and (re)launches it.
#   --ad-hoc      signs it ad hoc instead. macOS then ties Full Disk Access to this exact build, and
#                 the next build has to be added to the Full Disk Access list again.
# TEAMS_PULSE_SIGNING_IDENTITY names another certificate; TEAMS_PULSE_SIGNING_KEYCHAIN is a keychain
# to find it in, instead of the search list.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Teams Pulse"
EXECUTABLE="TeamsPulse"
APP="build/$APP_NAME.app"
IDENTITY="${TEAMS_PULSE_SIGNING_IDENTITY:-Teams Pulse Signing}"
KEYCHAIN="${TEAMS_PULSE_SIGNING_KEYCHAIN:-}"

UNIVERSAL=false
INSTALL=false
AD_HOC=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --install) INSTALL=true ;;
        --ad-hoc) AD_HOC=true ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if ! $AD_HOC && ! security find-certificate -c "$IDENTITY" ${KEYCHAIN:+"$KEYCHAIN"} >/dev/null 2>&1; then
    echo "There's no signing certificate named \"$IDENTITY\". Create it once with 'make signing-identity'." >&2
    echo "(Or pass --ad-hoc, but then Full Disk Access doesn't survive the next build.)" >&2
    exit 1
fi
# If some app may use the key without asking, any program running as you could sign itself as Teams
# Pulse with it, and get its Full Disk Access. A throwaway keychain of its own (CI) is the exception.
if ! $AD_HOC && [[ -z "$KEYCHAIN" ]]; then
    STATUS=0
    swift -suppress-warnings scripts/signing-key.swift check "$IDENTITY" || STATUS=$?
    if [[ $STATUS -eq 3 ]]; then
        echo "So any program running as you could sign itself as Teams Pulse, and get its Full Disk Access." >&2
        echo "Replace the certificate with one that every app has to ask to use, then build again:" >&2
        echo "  scripts/make-signing-identity.sh --replace" >&2
        exit 1
    elif [[ $STATUS -ne 0 ]]; then
        echo "warning: couldn't check which apps may use the key of \"$IDENTITY\"." >&2
    fi
fi

BUILD_FLAGS=(-c release)
if $UNIVERSAL; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_FLAGS[@]}" --product "$EXECUTABLE"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

# The build copies Sparkle.framework, the in-app updater, next to the executable.
SPARKLE=""
for candidate in "$BIN_DIR/Sparkle.framework" "$BIN_DIR/PackageFrameworks/Sparkle.framework"; do
    if [[ -d "$candidate" ]]; then
        SPARKLE="$candidate"
        break
    fi
done
if [[ -z "$SPARKLE" ]]; then
    echo "Sparkle.framework isn't in $BIN_DIR." >&2
    exit 1
fi
# Sparkle's license covers the code it bundles too. The app ships the copy in Resources.
SPARKLE_LICENSE=".build/artifacts/sparkle/Sparkle/LICENSE"
if ! cmp -s Resources/Sparkle-LICENSE.txt "$SPARKLE_LICENSE"; then
    echo "Resources/Sparkle-LICENSE.txt differs from $SPARKLE_LICENSE. Copy the new license over it." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist >/dev/null 2>&1; then
    echo "Resources/Info.plist sets CFBundleVersion. Remove it: the build sets it to CFBundleShortVersionString." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sparkle offers an update when its CFBundleVersion is higher than the running app's, so it's the
# version itself (scripts/package.sh checks that each release's version is higher).
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Sparkle-LICENSE.txt "$APP/Contents/Resources/Sparkle-LICENSE.txt"

# ditto keeps the framework's symlinks. A non-sandboxed app doesn't use Sparkle's XPC services, so
# leave them out: less code shipped, and less to attack.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE" "$FRAMEWORK"
rm -rf "$FRAMEWORK/XPCServices" "$FRAMEWORK/Versions/Current/XPCServices"

if $AD_HOC; then
    echo "warning: signing ad hoc. Full Disk Access granted to this build won't apply to the next one." >&2
    ./scripts/sign-app.sh "$APP" --ad-hoc
else
    if [[ -z "$KEYCHAIN" ]]; then
        echo "Signing with \"$IDENTITY\": macOS asks for your login password so that codesign can use its key." >&2
        echo "Click Allow, never Always Allow." >&2
    fi
    ./scripts/sign-app.sh "$APP"
fi
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
echo "Built $APP (version $VERSION, $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"
echo "Designated requirement: $REQUIREMENT"

if $INSTALL; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"

    # Quit a running copy so the new build takes over.
    pids="$(pgrep -f "/$APP_NAME.app/Contents/MacOS/$EXECUTABLE" || true)"
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        for _ in {1..50}; do
            pgrep -f "/$APP_NAME.app/Contents/MacOS/$EXECUTABLE" >/dev/null || break
            sleep 0.1
        done
    fi

    rm -rf "$DEST/$APP_NAME.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/$APP_NAME.app"
    echo "Installed and launched $DEST/$APP_NAME.app"
fi
