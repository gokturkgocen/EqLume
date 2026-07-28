#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Eqlume-AppStore.app"

./build.sh appstore

test -d "$APP"
test ! -e "$APP/Contents/Resources/DiscogsEffNet.mlmodelc"
test ! -e "$APP/Contents/Resources/discogs_styles.txt"

codesign --verify --deep --strict "$APP"

ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null)
[[ "$ENTITLEMENTS" == *"com.apple.security.app-sandbox"* ]]
[[ "$ENTITLEMENTS" == *"com.apple.security.network.client"* ]]
[[ "$ENTITLEMENTS" == *"com.apple.security.device.audio-input"* ]]
[[ "$ENTITLEMENTS" == *"com.apple.security.automation.apple-events"* ]]
[[ "$ENTITLEMENTS" != *"com.apple.security.get-task-allow"* ]]

# Guideline 2.4.5(i): ship only entitlements with matching functionality. Build 3 was
# rejected for carrying network.server with no reachable feature behind it. Both of these
# belong to the Spotify OAuth pre-fetch path, which is compiled out with `#if !APP_STORE`.
[[ "$ENTITLEMENTS" != *"com.apple.security.network.server"* ]]
[[ "$ENTITLEMENTS" != *"keychain-access-groups"* ]]

# The OAuth loopback listener must leave no trace in the binary either.
BIN="$APP/Contents/MacOS/Eqlume-AppStore"
! strings "$BIN" | grep -qE "38123|api\.spotify\.com|SpotifyOAuthServer"

INFO="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "com.gokturkgocen.Eqlume" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$INFO")" == "public.app-category.utilities" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$INFO")" == "false" ]]

echo "App Store preflight passed: $APP"
