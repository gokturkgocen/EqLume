#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Eqlume"
BUILD_DIR="./build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BUILD_FLAVOR="${1:-development}"
ENTITLEMENTS="Eqlume.entitlements"
SWIFT_FLAGS=()
BUNDLE_CLASSIFIER=true

if [[ "$BUILD_FLAVOR" == "sandbox-probe" ]]; then
    APP_NAME="Eqlume-SandboxProbe"
    APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
    ENTITLEMENTS="Eqlume.appstore.entitlements"
    SWIFT_FLAGS+=("-D" "SANDBOX_PROBE")
    BUNDLE_CLASSIFIER=false
elif [[ "$BUILD_FLAVOR" == "appstore" ]]; then
    APP_NAME="Eqlume-AppStore"
    APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
    ENTITLEMENTS="Eqlume.appstore.entitlements"
    SWIFT_FLAGS+=("-D" "APP_STORE")
    BUNDLE_CLASSIFIER=false
elif [[ "$BUILD_FLAVOR" == "screenshots" ]]; then
    APP_NAME="Eqlume-Screenshots"
    APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
    SWIFT_FLAGS+=("-D" "APP_STORE_SCREENSHOTS")
    BUNDLE_CLASSIFIER=false
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

if [[ "$BUILD_FLAVOR" == "sandbox-probe" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gokturkgocen.Eqlume.SandboxProbe" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Eqlume Sandbox Probe" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Eqlume-SandboxProbe" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Eqlume-SandboxProbe" "$APP_BUNDLE/Contents/Info.plist"
elif [[ "$BUILD_FLAVOR" == "appstore" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Eqlume-AppStore" "$APP_BUNDLE/Contents/Info.plist"
elif [[ "$BUILD_FLAVOR" == "screenshots" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gokturkgocen.Eqlume.Screenshots" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Eqlume Screenshots" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Eqlume-Screenshots" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Eqlume-Screenshots" "$APP_BUNDLE/Contents/Info.plist"
fi

# Bundle ML resources: CoreML model, mel filterbank, style labels, self-test vectors.
RES="$APP_BUNDLE/Contents/Resources"
[ -f Resources/AppIcon.icns ]            && cp Resources/AppIcon.icns "$RES/"
if [[ "$BUNDLE_CLASSIFIER" == true ]]; then
    [ -d Resources/DiscogsEffNet.mlmodelc ]  && cp -R Resources/DiscogsEffNet.mlmodelc "$RES/"
    [ -f Resources/mel_filterbank_96x257.f32 ] && cp Resources/mel_filterbank_96x257.f32 "$RES/"
    [ -f Resources/discogs_styles.txt ]      && cp Resources/discogs_styles.txt "$RES/"
    [ -f Resources/selftest_input.f32 ]      && cp Resources/selftest_input.f32 "$RES/"
    [ -f Resources/selftest_mel.f32 ]        && cp Resources/selftest_mel.f32 "$RES/"
fi

SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)

swiftc \
    -O \
    ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} \
    -target arm64-apple-macos26.0 \
    -sdk "$SDK_PATH" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework AVFAudio \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework CoreML \
    -framework Accelerate \
    -framework SwiftUI \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    Sources/*.swift

# Sign the app. Prefer a real "Apple Development" identity (keeps TCC permissions stable
# across rebuilds); if none exists, fall back to ad-hoc signing so anyone can build without
# an Apple Developer account. Override with: SIGN_ID="Your Identity" ./build.sh
SIGN_ID="${SIGN_ID:-Apple Development}"
if codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" --options runtime "$APP_BUNDLE" 2>/dev/null \
   || codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" 2>/dev/null; then
    echo "Signed with: $SIGN_ID"
else
    echo "No '$SIGN_ID' identity found — using ad-hoc signing."
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
fi

xattr -rc "$APP_BUNDLE" 2>/dev/null || true

# Preflight: the App Store build must ship only the minimum entitlements (App Review
# guideline 2.4.5(i) — build 3 was rejected for carrying network.server with no matching
# functionality). network.server and keychain-access-groups belong to the Spotify OAuth
# pre-fetch path, which is compiled out via `#if !APP_STORE`; assert they are really gone,
# that the entitlements we DO need survived, and that no CC BY-NC-SA model got bundled.
if [[ "$BUILD_FLAVOR" == "appstore" ]]; then
    SIGNED_ENTS=$(codesign -d --entitlements - --xml "$APP_BUNDLE" 2>/dev/null \
                  | plutil -convert xml1 -o - - 2>/dev/null)
    preflight_fail=0
    for forbidden in "com.apple.security.network.server" "keychain-access-groups"; do
        if grep -q "$forbidden" <<< "$SIGNED_ENTS"; then
            echo "PREFLIGHT FAIL: '$forbidden' is present in the signed App Store build." >&2
            preflight_fail=1
        fi
    done
    for required in "com.apple.security.app-sandbox" "com.apple.security.network.client" \
                    "com.apple.security.device.audio-input" "com.apple.security.automation.apple-events"; do
        if ! grep -q "$required" <<< "$SIGNED_ENTS"; then
            echo "PREFLIGHT FAIL: required entitlement '$required' is missing." >&2
            preflight_fail=1
        fi
    done
    if [ -e "$APP_BUNDLE/Contents/Resources/DiscogsEffNet.mlmodelc" ]; then
        echo "PREFLIGHT FAIL: the CC BY-NC-SA Discogs-EffNet model must not ship in the App Store build." >&2
        preflight_fail=1
    fi
    [ "$preflight_fail" -eq 0 ] || exit 1
    echo "Preflight OK: no network.server / keychain-access-groups, required entitlements present, no bundled model."
fi

echo "Built: $APP_BUNDLE"

if [[ "$BUILD_FLAVOR" == "install" ]]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/"
    # Remove the build copy so Spotlight/Launchpad only ever show the installed app
    # (otherwise two "Eqlume" entries get indexed).
    rm -rf "$APP_BUNDLE"
    echo "Installed to /Applications/$APP_NAME.app"
fi
