#!/bin/bash
# Builds build/SafariCleaner.app (one app for both Apple Silicon and Intel) and signs it.
#
# Signing: if the keychain has an "Apple Development" certificate, it is used.
# Signing with the same certificate every time keeps "Full Disk Access" across rebuilds:
# macOS remembers the app by its signature. Without a certificate the app gets a local
# (ad-hoc) signature: it works the same, but after each rebuild macOS sees it as a new app
# and "Full Disk Access" has to be switched on again.
# A specific certificate can be chosen with SIGN_IDENTITY="..." ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

BINS=()
for ARCH in arm64 x86_64; do
    swift build -c release --arch "$ARCH"
    BINS+=("$(swift build -c release --arch "$ARCH" --show-bin-path)/SafariCleaner")
done

APP=build/SafariCleaner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/SafariCleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Подписано сертификатом: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Подписано локально (без сертификата). После каждой пересборки «Полный доступ к диску» нужно включать заново."
fi

echo "Готово: $(pwd)/$APP"
