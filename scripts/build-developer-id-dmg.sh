#!/usr/bin/env bash
# Build, notarize, and package the Developer ID macOS app as a DMG.
#
# This is the distribution channel for full-featured macOS installs
# (TestFlight requires App Sandbox, which kills the global hotkey and
# auto-paste). Signs with the Developer ID Application certificate,
# notarizes both the app and the DMG with notarytool, and staples both.
#
# Identity: bundle ID emileberhard.WisprClone (canonical mac identity,
# shared with the local dev build), unsandboxed, hardened runtime,
# Developer ID entitlements (Mumla/MumlaDeveloperID.entitlements: CloudKit
# history sync and the iCloud KVS identifier).
# Signs with the "Mumla Mac Developer ID" provisioning profile
# installed by the shared apple-devops helper so the profile-injected
# application-identifier acts as the data-protection keychain access group
# (TN3137).
set -euo pipefail

cd "$(dirname "$0")/.."

# Notary credentials (App Store Connect API key).
if [ -z "${APP_STORE_CONNECT_KEY_ID:-}" ] && [ -f "$HOME/configs/shared-env.sh" ]; then
    # shellcheck disable=SC1091
    source "$HOME/configs/shared-env.sh"
fi
for var in APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_KEY_PATH; do
    if [ -z "${!var:-}" ]; then
        echo "error: $var is not set (needed for notarytool)" >&2
        exit 1
    fi
done

# Signing identity: the canonical never-locked "apple-signing" keychain,
# provisioned from ~/configs/.appstoreconnect by the apple-devops skill.
# The active long-lived Developer ID profile is downloaded read-only through
# the App Store Connect API key, so a fresh runner needs no manual bootstrap.
apple_devops_scripts="$HOME/configs/skills/apple-devops/scripts"
"$apple_devops_scripts/ensure-signing-keychain"
echo "==> Installing the current Developer ID provisioning profile"
uv run "$apple_devops_scripts/asc_api.py" install-profile \
    --name "Mumla Mac Developer ID" \
    --type MAC_APP_DIRECT \
    --bundle-id emileberhard.WisprClone

signing_keychain_name="${APPLE_SIGNING_KEYCHAIN_NAME:-apple-signing}"
signing_keychain="$HOME/Library/Keychains/$signing_keychain_name.keychain-db"
if ! security find-identity -v -p codesigning "$signing_keychain" | grep -q "Developer ID Application"; then
    echo "error: no 'Developer ID Application' identity in the keychain." >&2
    echo "Expected it in ~/configs/.appstoreconnect/developer-id/ via" >&2
    echo "the apple-devops ensure-signing-keychain script." >&2
    exit 1
fi

version="${VERSION:-$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*')}"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"

build_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
derived_data="$(mktemp -d "$build_root/wcmac-devid-dd.XXXXXX")"
trap 'rm -rf "$derived_data"' EXIT
archive_path="$derived_data/Mumla.xcarchive"
dist_dir="dist"
dmg_path="$dist_dir/Mumla-$version.dmg"
rm -f "$dmg_path"
mkdir -p "$dist_dir"

xcodebuild -resolvePackageDependencies -project Mumla.xcodeproj -scheme MumlaMac \
    -derivedDataPath "$derived_data" -onlyUsePackageVersionsFromResolvedFile

echo "==> Archiving Mumla $version ($build_number) with Developer ID signing"
xcodebuild -project Mumla.xcodeproj -scheme MumlaMac \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -archivePath "$archive_path" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
    archive \
    PRODUCT_BUNDLE_IDENTIFIER=emileberhard.WisprClone \
    ENABLE_APP_SANDBOX=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    PROVISIONING_PROFILE_SPECIFIER="Mumla Mac Developer ID" \
    CODE_SIGN_ENTITLEMENTS=Mumla/MumlaDeveloperID.entitlements \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    | tail -5

app_path="$archive_path/Products/Applications/Mumla.app"
[ -d "$app_path" ] || { echo "error: archive has no app at $app_path" >&2; exit 1; }
APP_BUNDLE_ID=emileberhard.WisprClone DEVELOPMENT_TEAM=NNP2B278S6 scripts/sign-bundles check "$app_path" developer-id
scripts/check-access-configuration "$app_path/Contents/Info.plist"

notarize() {
    local file="$1"
    echo "==> Notarizing $(basename "$file")"
    # --timeout bounds the wait: a stalled notary submission once hung CI
    # for the full 150-minute job timeout. Normal processing takes minutes.
    xcrun notarytool submit "$file" \
        --key "$APP_STORE_CONNECT_KEY_PATH" \
        --key-id "$APP_STORE_CONNECT_KEY_ID" \
        --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
        --wait \
        --timeout 30m
}

app_zip="$derived_data/Mumla.zip"
rm -f "$app_zip"
ditto -c -k --keepParent "$app_path" "$app_zip"
notarize "$app_zip"
xcrun stapler staple "$app_path"
spctl -a -vv "$app_path"

echo "==> Building DMG"
staging="$derived_data/dmg-staging"
rm -rf "$staging"
mkdir -p "$staging"
cp -R "$app_path" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Mumla" -srcfolder "$staging" -ov -format UDZO -quiet "$dmg_path"
codesign --force --sign "Developer ID Application" --timestamp "$dmg_path"

notarize "$dmg_path"
xcrun stapler staple "$dmg_path"
spctl -a -vv -t open --context context:primary-signature "$dmg_path"

echo "Done: $dmg_path"
