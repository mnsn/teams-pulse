#!/bin/bash
# Builds "Teams Pulse.app" into ./build, for this Mac's architecture. It's signed ad hoc, so macOS ties
# Full Disk Access to this exact build, and each new build needs the access again. If you made the
# optional "Teams Pulse Signing" certificate (scripts/make-signing-identity.sh), it's signed with that
# instead, and keeps the access across rebuilds.
#   --universal   builds for both Apple silicon and Intel instead.
#   --install     also copies it to ~/Applications and (re)launches it.
#   --ad-hoc      signs it ad hoc even if the certificate exists.
# TEAMS_PULSE_SIGNING_IDENTITY names another certificate. TEAMS_PULSE_SIGNING_KEYCHAIN is a keychain of
# its own that holds it (CI, scripts/ci-signing-identity.sh), and must.
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

# Whether some app may use the key of your certificate without asking. If so, any program running as
# you could sign itself as Teams Pulse with it, and get its Full Disk Access.
check_key() { swift -suppress-warnings scripts/signing-key.swift check "$IDENTITY" 2>&1; }
SIGN_WITH_CERTIFICATE=false
if $AD_HOC; then
    :
elif [[ -n "$KEYCHAIN" ]]; then
    if ! security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "There's no \"$IDENTITY\" certificate in $KEYCHAIN (TEAMS_PULSE_SIGNING_KEYCHAIN)." >&2
        exit 1
    fi
    SIGN_WITH_CERTIFICATE=true
else
    STATUS=0
    OUTPUT="$(check_key)" || STATUS=$?
    case $STATUS in
        0) SIGN_WITH_CERTIFICATE=true ;;
        4) ;; # No certificate: ad hoc.
        3)
            echo "$OUTPUT" >&2
            echo "So any program running as you could sign itself as Teams Pulse, and get its Full Disk Access." >&2
            echo "Delete the certificate, to build ad hoc, or replace it with one that every app has to ask to use:" >&2
            echo "  scripts/make-signing-identity.sh --delete   (or --replace)" >&2
            exit 1 ;;
        *)
            echo "$OUTPUT" >&2
            echo "Couldn't check which apps may use the \"$IDENTITY\" key. Build with --ad-hoc, or delete the" >&2
            echo "certificate: scripts/make-signing-identity.sh --delete" >&2
            exit 1 ;;
    esac
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

if ! $SIGN_WITH_CERTIFICATE; then
    ./scripts/sign-app.sh "$APP" --ad-hoc
elif [[ -n "$KEYCHAIN" ]]; then
    ./scripts/sign-app.sh "$APP"
else
    echo "Signing with \"$IDENTITY\": macOS asks for your login password so that codesign can use its key." >&2
    echo "Click Allow, never Always Allow." >&2
    if ! ./scripts/sign-app.sh "$APP"; then
        echo "codesign couldn't use the \"$IDENTITY\" key. When macOS asks, enter your login password and click" >&2
        echo "Allow (never Always Allow), or build with --ad-hoc." >&2
        exit 1
    fi
    # Always Allow, just now, would let codesign use the key without asking from now on.
    STATUS=0
    OUTPUT="$(check_key)" || STATUS=$?
    if [[ $STATUS -eq 3 ]]; then
        echo "$OUTPUT" >&2
        echo "That was Always Allow, so anything running as you could now sign itself as Teams Pulse, and get" >&2
        echo "its Full Disk Access. Run scripts/make-signing-identity.sh --replace (or --delete), and build again." >&2
        exit 1
    elif [[ $STATUS -ne 0 ]]; then
        echo "$OUTPUT" >&2
        echo "warning: couldn't check again which apps may use the \"$IDENTITY\" key." >&2
    fi
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
if ! $SIGN_WITH_CERTIFICATE; then
    # Full Disk Access keeps the requirement of the build that was allowed, even when it's turned off
    # and on, so the entry has to go before this build can be allowed.
    echo "note: signed ad hoc, so macOS ties Full Disk Access to this exact build, and turning it off and on" >&2
    echo "      keeps the old build's. To allow this one, run" >&2
    echo "      tccutil reset SystemPolicyAllFiles $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)" >&2
    echo "      (or remove Teams Pulse with − in Privacy & Security › Full Disk Access), and add it again with +." >&2
    echo "      To keep the access across rebuilds, see \"Keeping Full Disk Access across rebuilds\" in the README." >&2
fi
