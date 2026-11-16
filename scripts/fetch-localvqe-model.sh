#!/bin/bash
# Скачивает модель эхоподавления LocalVQE (Apache-2.0, 2,9 МБ) и проверяет её контрольную сумму.
# Модель вкладывается внутрь .app. Библиотека LocalVQE сама сверяет модель со списком допустимых,
# поэтому версия модели привязана к версии библиотеки в Package.swift.
set -euo pipefail

REPO="LocalAI-io/LocalVQE"
REVISION="29ca38495cba9d6393a92a4dd890f28dd81f758d"
FILE="localvqe-v1.4-aec-200K-f32.gguf"
SHA256="b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731"
UPSTREAM_URL="https://huggingface.co/${REPO}/resolve/${REVISION}/${FILE}"
MIRROR_URL="https://github.com/pasrom/localvqe-xcframework/releases/download/model-v1.4-aec-200K/${FILE}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/localvqe"
TARGET="$DEST/$FILE"

verify() {
    [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$SHA256" ]
}

if verify "$TARGET"; then
    echo "Модель LocalVQE уже скачана"
    exit 0
fi

mkdir -p "$DEST"
for url in "$UPSTREAM_URL" "$MIRROR_URL"; do
    echo "Скачиваю модель эхоподавления: $url"
    if curl -fsSL --connect-timeout 10 --max-time 120 -o "$TARGET.tmp" "$url" && verify "$TARGET.tmp"; then
        mv "$TARGET.tmp" "$TARGET"
        echo "Готово: $TARGET"
        exit 0
    fi
    rm -f "$TARGET.tmp"
done

echo "Не удалось скачать модель LocalVQE или не совпала контрольная сумма" >&2
exit 1
