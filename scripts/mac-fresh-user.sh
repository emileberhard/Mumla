#!/bin/zsh
# Simulate a brand-new user for the macOS app: kill every running instance,
# reset TCC permissions, wipe UserDefaults and the saved credentials, and delete
# every local installation. DMGs are left alone (use `just clean-dmgs`) so a
# freshly built installer survives the wipe.

set -uo pipefail

BUNDLE_ID="emileberhard.WisprClone"
KEYCHAIN_SERVICE="emileberhard.WisprClone.apiKeys"
LEGACY_KEY_ACCOUNTS=(LLM_ROUTER_KEY OPENAI_API_KEY ASSEMBLYAI_API_KEY ELEVENLABS_API_KEY GEMINI_API_KEY AZURE_SPEECH_KEY)
STAMP=$(date +%Y%m%d-%H%M%S)

echo "==> Killing running instances"
pkill -f "/Applications/Mumla.app/Contents/MacOS/" 2>/dev/null && echo "killed Mumla" || true
pkill -f "/Applications/Mumla Dev.app/Contents/MacOS/" 2>/dev/null && echo "killed Mumla Dev" || true
sleep 1

# TCC reset MUST happen while an app with this bundle ID is still installed;
# tccutil errors with "No such bundle identifier" (a silent no-op) otherwise.
echo "==> Resetting TCC permissions for $BUNDLE_ID"
if ! tccutil reset All "$BUNDLE_ID"; then
    echo "warning: tccutil reset failed (is any Mumla app still installed?)" >&2
fi

echo "==> Wiping UserDefaults (backup first)"
PLIST="$HOME/Library/Preferences/$BUNDLE_ID.plist"
if [ -f "$PLIST" ]; then
    BACKUP="/tmp/mumla-defaults-$STAMP.plist"
    cp "$PLIST" "$BACKUP"
    echo "defaults backed up to $BACKUP (contains custom vocabulary)"
fi
defaults delete "$BUNDLE_ID" 2>/dev/null && echo "defaults deleted" || echo "no defaults to delete"

echo "==> Deleting the saved access session and retired keys"
# The data-protection keychain is invisible to the security CLI, so the app
# binary deletes those items itself; any installed build can, since they all
# share one keychain access group.
DELETED_VIA_APP=0
for binary in \
    "/Applications/Mumla.app/Contents/MacOS/Mumla" \
    "/Applications/Mumla Dev.app/Contents/MacOS/Mumla Dev"; do
    if [ -x "$binary" ] && "$binary" --delete-credentials; then
        echo "deleted data-protection keychain items via $binary"
        DELETED_VIA_APP=1
        break
    fi
done
if [ "$DELETED_VIA_APP" -eq 0 ]; then
    echo "warning: no app binary available; data-protection keychain items (if any) were not deleted" >&2
fi
# Legacy file-based items from pre-data-protection builds.
for account in "${LEGACY_KEY_ACCOUNTS[@]}"; do
    if security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1; then
        echo "deleted legacy Keychain item $account"
    fi
done

echo "==> Wiping local transcription history (backup first; the iCloud copy"
echo "    is untouched and re-syncs into the next signed install)"
APP_SUPPORT="$HOME/Library/Application Support/WisprClone"
if [ -d "$APP_SUPPORT" ]; then
    cp -R "$APP_SUPPORT" "/tmp/mumla-appsupport-$STAMP"
    rm -rf "$APP_SUPPORT"
    echo "history backed up to /tmp/mumla-appsupport-$STAMP"
fi

echo "==> Deleting installations"
for path in \
    "/Applications/Mumla.app" \
    "/Applications/Mumla Dev.app" \
    "$HOME/Desktop/Mumla-backups" \
    "/tmp/wcmac-dd" \
    "/tmp/wcmac-devid-dd"; do
    if [ -e "$path" ]; then
        rm -rf "$path"
        echo "removed $path"
    fi
done

echo "==> Verifying"
REMAINING=$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID*'" 2>/dev/null \
    | grep -v "DerivedData" || true)
if [ -n "$REMAINING" ]; then
    echo "warning: Spotlight still indexes these copies:" >&2
    echo "$REMAINING" >&2
else
    echo "no macOS installations remain"
fi

echo "==> Fresh-user state ready"
