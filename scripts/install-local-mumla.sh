#!/bin/zsh

set -euo pipefail

APP_NAME="Mumla Dev.app"
APP_SRC="/tmp/wcmac-dd/Build/Products/Debug/$APP_NAME"
APP_DST="/Applications/$APP_NAME"

if [ ! -d "$APP_SRC" ]; then
  echo "Built app not found at: $APP_SRC" >&2
  echo "Run 'just install-mac' (builds a signed Debug MumlaMac first)." >&2
  exit 1
fi

pkill -f "$APP_DST/Contents/MacOS/" || true
sleep 1

rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
mkdir -p "$HOME/.local/bin"
install -m 755 "${0:A:h}/mumla" "$HOME/.local/bin/mumla"

if [[ "${MUMLA_INSTALL_LAUNCH:-1}" == "1" ]]; then
  open "$APP_DST"
  sleep 2
fi

echo "Installed app:"
stat -f "%Sm %N" -t "%Y-%m-%d %H:%M:%S" "$APP_DST"

if [[ "${MUMLA_INSTALL_LAUNCH:-1}" == "1" ]]; then
  echo
  echo "Running process:"
  ps -axo pid,command | rg -F "$APP_DST/Contents/MacOS/" || true
else
  echo "Installed without launching for CloudKit schema bootstrap."
fi
