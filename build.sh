#!/bin/bash
# Builds build/SafariCleaner.app and signs it.
#
# Signing with the same certificate every time keeps "Full Disk Access" across rebuilds:
# macOS remembers the app by its signature, and an unsigned (ad-hoc) build looks like a new app each time.
# By default the first "Apple Development" certificate from the keychain is used;
# another one can be chosen with SIGN_IDENTITY="..." ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SafariCleaner"

APP=build/SafariCleaner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SafariCleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Подписано сертификатом: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "ВНИМАНИЕ: сертификат не найден, подпись временная. «Полный доступ к диску» придётся включать после каждой сборки."
fi

echo "Готово: $(pwd)/$APP"
