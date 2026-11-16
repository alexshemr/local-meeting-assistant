#!/bin/bash
# Скачивает зафиксированную сборку llama.cpp (движок языковой модели) и проверяет её контрольную сумму.
# Движок вкладывается внутрь .app, поэтому пользователю ничего ставить отдельно не нужно.
set -euo pipefail

LLAMA_BUILD="b12284"
LLAMA_SHA256="7965e7701df311c49cfc629cfe14cc5092fcc590ef8c85f4c436a2973031e9d0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/llama"
TARGET="$DEST/llama-$LLAMA_BUILD"

if [ -x "$TARGET/llama-server" ]; then
    echo "llama.cpp $LLAMA_BUILD уже скачан"
    exit 0
fi

mkdir -p "$DEST"
ARCHIVE="$DEST/llama-$LLAMA_BUILD.tar.gz"
URL="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/llama-$LLAMA_BUILD-bin-macos-arm64.tar.gz"

echo "Скачиваю llama.cpp $LLAMA_BUILD…"
curl -fL --progress-bar -o "$ARCHIVE" "$URL"

ACTUAL="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$LLAMA_SHA256" ]; then
    echo "Контрольная сумма не совпала: ожидалась $LLAMA_SHA256, получена $ACTUAL" >&2
    rm -f "$ARCHIVE"
    exit 1
fi

tar -xzf "$ARCHIVE" -C "$DEST"
rm -f "$ARCHIVE"
echo "Готово: $TARGET"
