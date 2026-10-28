#!/usr/bin/env bash
# Build, notarize, and package the Developer ID macOS app as a DMG.
#
# This is the distribution channel for full-featured macOS installs
# (TestFlight requires App Sandbox, which kills the global hotkey and
# auto-paste). `archive` builds the app unsigned and signs it ad hoc with its
# Developer ID entitlements before any signing credential is present.
# `package` then exports it with manual signing: the Developer ID
# provisioning profile at $DEVELOPER_ID_PROFILE and the keychain identity of
# the certificate it names. App Store Connect API keys cannot
# cloud sign Developer ID, so the identity must be local. The DMG is signed
# with the same identity, then notarized once and stapled as the outermost
# container.
#
# Identity: bundle ID emileberhard.WisprClone (canonical mac identity,
# shared with the local dev build), unsandboxed, hardened runtime,
# Developer ID entitlements (Mumla/MumlaDeveloperID.entitlements: CloudKit
# history sync and the iCloud KVS identifier). The Developer ID profile
# supplies the application identifier that acts as the data-protection
# keychain access group (TN3137).
set -euo pipefail

cd "$(dirname "$0")/.."

[ $# -eq 2 ] || { echo "usage: $0 archive|package ARCHIVE" >&2; exit 2; }
mode="$1"
archive_path="$2"

require() {
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            echo "error: $var is not set" >&2
            exit 1
        fi
    done
}

export APP_BUNDLE_ID=emileberhard.WisprClone DEVELOPMENT_TEAM=NNP2B278S6
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/wcmac-devid.XXXXXX")"
trap 'rm -rf "$work"' EXIT

case "$mode" in
archive)
    require VERSION BUILD_NUMBER
    rm -rf "$archive_path"
    xcodebuild -resolvePackageDependencies -project Mumla.xcodeproj -scheme MumlaMac \
        -derivedDataPath "$work/dd" -onlyUsePackageVersionsFromResolvedFile

    echo "==> Archiving Mumla $VERSION ($BUILD_NUMBER)"
    xcodebuild archive -quiet -project Mumla.xcodeproj -scheme MumlaMac -configuration Release \
        -destination generic/platform=macOS -derivedDataPath "$work/dd" -archivePath "$archive_path" \
        -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
        PRODUCT_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID" ENABLE_APP_SANDBOX=NO \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
    scripts/sign-bundles sign "$archive_path/Products/Applications/Mumla.app" developer-id
    ;;
package)
    require VERSION DEVELOPER_ID_PROFILE APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_KEY_PATH
    security cms -D -i "$DEVELOPER_ID_PROFILE" > "$work/profile.plist"
    profile_name="$(plutil -extract Name raw "$work/profile.plist")"
    profile_uuid="$(plutil -extract UUID raw "$work/profile.plist")"
    identity="$(plutil -extract DeveloperCertificates.0 raw "$work/profile.plist" | base64 --decode | openssl x509 -inform DER -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
    if ! security find-identity -v -p codesigning | grep -q "$identity"; then
        echo "error: no keychain identity for the certificate in $profile_name" >&2
        exit 1
    fi
    profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    mkdir -p "$profiles_dir"
    cp "$DEVELOPER_ID_PROFILE" "$profiles_dir/$profile_uuid.provisionprofile"
    export_path="$work/export"
    dmg_path="dist/Mumla-$VERSION.dmg"
    rm -f "$dmg_path"
    mkdir -p dist

    echo "==> Exporting with $profile_name"
    plutil -insert teamID -string "$DEVELOPMENT_TEAM" -o "$work/ExportOptions.plist" Apple/Config/ExportOptions-developer-id.plist
    plutil -insert signingCertificate -string "$identity" "$work/ExportOptions.plist"
    plutil -insert provisioningProfiles -json "{\"$APP_BUNDLE_ID\":\"$profile_name\"}" "$work/ExportOptions.plist"
    xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_path" \
        -exportOptionsPlist "$work/ExportOptions.plist"

    app_path="$export_path/Mumla.app"
    scripts/sign-bundles check "$app_path" developer-id
    scripts/check-access-configuration "$app_path/Contents/Info.plist"

    echo "==> Building and signing the DMG"
    staging="$work/dmg-staging"
    mkdir -p "$staging"
    ditto "$app_path" "$staging/Mumla.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname "Mumla" -srcfolder "$staging" -ov -format UDZO -quiet "$dmg_path"
    codesign --sign "$identity" --timestamp --identifier "$APP_BUNDLE_ID.disk-image" "$dmg_path"

    echo "==> Notarizing $(basename "$dmg_path")"
    # --timeout bounds the wait: a stalled notary submission once hung CI
    # for the full 150-minute job timeout. Normal processing takes minutes.
    xcrun notarytool submit "$dmg_path" \
        --key "$APP_STORE_CONNECT_KEY_PATH" \
        --key-id "$APP_STORE_CONNECT_KEY_ID" \
        --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
        --wait \
        --timeout 30m
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
    spctl -a -t open --context context:primary-signature -v "$dmg_path"
    echo "Done: $dmg_path"
    ;;
*)
    echo "usage: $0 archive|package ARCHIVE" >&2
    exit 2
    ;;
esac
