#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="${PROVISIONING_PROFILE:-}"
SIGN_ID="${SIGN_ID:-Apple Distribution}"
APP="build/Eqlume-AppStore.app"
# Derive the package name from Info.plist instead of hardcoding it — a stale build number
# here silently produces a mislabelled upload (it said "build-3" while shipping build 4).
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
PKG="build/Eqlume-${APP_VERSION}-build-${APP_BUILD}.pkg"

if [[ -z "$PROFILE" || ! -f "$PROFILE" ]]; then
    echo "Set PROVISIONING_PROFILE to the downloaded Mac App Store provisioning profile."
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_ID"; then
    echo "Signing identity not found: $SIGN_ID"
    exit 1
fi

SIGN_ID="$SIGN_ID" ./build.sh appstore
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
# Downloaded profiles carry macOS's quarantine attribute. App Store validation
# rejects any quarantined file inside the payload, so strip extended attributes
# after embedding the profile and before producing the final signature.
xattr -cr "$APP"
if xattr -lr "$APP" 2>/dev/null | grep -q 'com.apple.quarantine'; then
    echo "Quarantine attribute remains inside the app bundle."
    exit 1
fi
codesign --force --deep --strict --options runtime --sign "$SIGN_ID" --entitlements Eqlume.appstore.entitlements "$APP"
codesign --verify --deep --strict "$APP"

SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
[[ "$SIGNED_ENTITLEMENTS" == *"3R9ULKMUXY.com.gokturkgocen.Eqlume"* ]] || {
    echo "Signed application identifier does not match the provisioning profile."
    exit 1
}
for forbidden in "com.apple.security.network.server" "keychain-access-groups"; do
    if [[ "$SIGNED_ENTITLEMENTS" == *"$forbidden"* ]]; then
        echo "Forbidden entitlement remains after distribution signing: $forbidden"
        exit 1
    fi
done

BIN="$APP/Contents/MacOS/Eqlume-AppStore"
if strings "$BIN" | grep -qE "38123|api\.spotify\.com|SpotifyOAuthServer"; then
    echo "Spotify OAuth implementation remains in the App Store binary."
    exit 1
fi

INSTALLER_ID="${INSTALLER_ID:-3rd Party Mac Developer Installer}"
if ! security find-identity -v | grep -Fq "$INSTALLER_ID"; then
    echo "Installer identity not found: $INSTALLER_ID"
    exit 1
fi

productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$PKG"
echo "Created upload package: $PKG"
