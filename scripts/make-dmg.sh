#!/bin/bash
# Собирает установочный образ: dist/LocalMeetingAssistant-<версия>.dmg
# с приложением и ярлыком папки «Программы» (установка перетаскиванием).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export VERSION="${VERSION:-0.1.1}"
"$ROOT/scripts/build-app.sh"

APP="$ROOT/dist/Local Meeting Assistant.app"
DMG="$ROOT/dist/LocalMeetingAssistant-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Local Meeting Assistant" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ "${SIGN_IDENTITY:--}" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

echo "Образ готов: $DMG"
du -sh "$DMG" | cut -f1 | xargs echo "Размер:"
