#!/bin/bash
# Собирает самодостаточный «Local Meeting Assistant.app»: приложение + встроенный движок llama.cpp.
# Требуются только Command Line Tools (xcode-select --install); Xcode не нужен.
#
#   scripts/build-app.sh            — сборка в dist/
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   — подпись своим сертификатом
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
CONFIG="${CONFIG:-release}"   # CONFIG=debug — быстрая сборка для разработки
APP="$ROOT/dist/Local Meeting Assistant.app"
LLAMA_BUILD="$(grep '^LLAMA_BUILD=' scripts/fetch-llama.sh | cut -d'"' -f2)"

# Сборка заменяет приложение в dist/. Если оно сейчас запущено (возможно, идёт запись встречи),
# замена оставила бы его без встроенных ресурсов — поэтому останавливаемся.
if pgrep -f "$APP/Contents/MacOS/LocalMeetingAssistant" >/dev/null 2>&1 && [ "${FORCE:-0}" != "1" ]; then
    echo "Приложение из dist/ сейчас запущено. Закройте его (убедившись, что запись не идёт) и повторите сборку." >&2
    exit 1
fi

"$ROOT/scripts/fetch-llama.sh"
"$ROOT/scripts/fetch-localvqe-model.sh"

echo "Сборка приложения…"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/llama" "$APP/Contents/Frameworks"

cp "$BIN/LocalMeetingAssistant" "$APP/Contents/MacOS/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Модель эхоподавления.
cp "$ROOT"/Vendor/localvqe/localvqe-*.gguf "$APP/Contents/Resources/"

# Ресурсы зависимостей (SwiftPM ищет их в Contents/Resources).
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Библиотека совместимости Swift — на случай более старой macOS, где её нет в системе.
SPAN="$(xcrun --find swift | xargs dirname)/../lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib"
if [ -f "$SPAN" ]; then
    cp "$SPAN" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/LocalMeetingAssistant" 2>/dev/null || true
fi

# Движок языковой модели: сервер и его библиотеки (ссылки между ними сохраняются).
LLAMA_SRC="$ROOT/Vendor/llama/llama-$LLAMA_BUILD"
cp "$LLAMA_SRC/llama-server" "$APP/Contents/Resources/llama/"
cp -a "$LLAMA_SRC"/*.dylib "$APP/Contents/Resources/llama/"
cp "$LLAMA_SRC/LICENSE" "$APP/Contents/Resources/llama/LICENSE-llama.cpp" 2>/dev/null || true

echo "Подпись…"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp --options runtime --entitlements "$ROOT/Resources/entitlements.plist")
fi
find "$APP/Contents/Resources/llama" "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "llama-server" \) -print0 |
    while IFS= read -r -d '' file; do codesign "${SIGN_ARGS[@]}" "$file"; done
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo
echo "Готово: $APP"
du -sh "$APP" | cut -f1 | xargs echo "Размер:"
