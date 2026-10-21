#!/bin/bash
# Signs "Teams Pulse.app" from the inside out: Sparkle.framework (ad hoc), then the app, with the
# hardened runtime. scripts/build-app.sh runs it for every build; the release workflow runs it again
# with the release certificate, which only the approved release job holds.
#   scripts/sign-app.sh <app> [--ad-hoc]
# TEAMS_PULSE_SIGNING_IDENTITY names the certificate (default "Teams Pulse Signing");
# TEAMS_PULSE_SIGNING_KEYCHAIN is a keychain to find it in, instead of the search list.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?Usage: $0 <app> [--ad-hoc]}"
AD_HOC=false
if [[ "${2:-}" == "--ad-hoc" ]]; then
    AD_HOC=true
fi
IDENTITY="${TEAMS_PULSE_SIGNING_IDENTITY:-Teams Pulse Signing}"
KEYCHAIN="${TEAMS_PULSE_SIGNING_KEYCHAIN:-}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

if $AD_HOC; then
    SIGN=(--sign -)
else
    # No timestamp, so signing makes no network request.
    SIGN=(--sign "$IDENTITY" --timestamp=none)
    if [[ -n "$KEYCHAIN" ]]; then
        SIGN+=(--keychain "$KEYCHAIN")
    fi
fi

# Sparkle's helpers (Autoupdate and Updater.app) run as their own processes and keep the signatures
# they ship with. The framework is signed again, without its XPC services, ad hoc: with library
# validation off (see Resources/TeamsPulse.entitlements), the app loads it whoever signed it, and the
# app's own signature seals the framework's exact code. So codesign uses the certificate's key once per
# build, and asks for the password once.
if [[ -d "$FRAMEWORK" ]]; then
    codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$FRAMEWORK"
fi
# The hardened runtime keeps other processes from injecting code into an app that holds Full Disk
# Access (DYLD_* variables are ignored). See Resources/TeamsPulse.entitlements for library validation.
codesign --force "${SIGN[@]}" --options runtime --entitlements Resources/TeamsPulse.entitlements "$APP"
