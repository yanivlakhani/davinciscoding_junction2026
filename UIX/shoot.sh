#!/usr/bin/env bash
# Render each app screen in a phone-shaped headless window.
# Uses Chrome's --virtual-time-budget so transitions settle before capture.

set -e
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p shots

shoot() {
  local name="$1"
  local hash="$2"
  "$CHROME" \
    --headless=new \
    --disable-gpu \
    --hide-scrollbars \
    --window-size=430,932 \
    --force-device-scale-factor=2 \
    --virtual-time-budget=1500 \
    --screenshot="shots/${name}.png" \
    "file://$PWD/index.html${hash}" >/dev/null 2>&1
}

shoot "01-home"     ""
shoot "02-contacts" "#/contacts"
shoot "03-edit"     "#/edit"
shoot "04-confirm"  "#/home?confirm=1"

echo "Wrote:"
ls -1 shots
