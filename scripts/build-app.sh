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

KEYCHAIN_ARGS=()
if [[ -n "$KEYCHAIN" ]]; then
    KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
fi
if ! $AD_HOC && ! security find-certificate -c "$IDENTITY" ${KEYCHAIN:+"$KEYCHAIN"} >/dev/null 2>&1; then
    echo "There's no signing certificate named \"$IDENTITY\". Create it once with 'make signing-identity'." >&2
    echo "(Or pass --ad-hoc, but then Full Disk Access doesn't survive the next build.)" >&2
    exit 1
fi

BUILD_FLAGS=(-c release)
if $UNIVERSAL; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_FLAGS[@]}" --product "$EXECUTABLE"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist >/dev/null 2>&1; then
    echo "Resources/Info.plist sets CFBundleVersion. Remove it: the build sets it to CFBundleShortVersionString." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The hardened runtime costs nothing here: the app links only system frameworks. No timestamp, so
# signing makes no network request.
if $AD_HOC; then
    echo "warning: signing ad hoc. Full Disk Access granted to this build won't apply to the next one." >&2
    codesign --force --options runtime --sign - "$APP"
else
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
        ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$APP"
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
