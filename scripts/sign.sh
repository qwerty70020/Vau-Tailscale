#!/usr/bin/env bash
#
# Підписати артефакти релізу за допомогою minisign.
#
# Ключ живе лише в CI-секреті MINISIGN_SECRET_KEY (сирий вміст секретного
# ключа minisign без пароля). Ключ із паролем тут використати не можна:
# minisign запитає його, а запит у CI — це зависання, а не підпис.
#
# Перевірка для того, хто завантажує реліз:
#   minisign -Vm tailscale_<ver>_arm64.tgz -P <публічний ключ із docs/BUILD.md>
#
# Використання: MINISIGN_SECRET_KEY="$(cat vau-tailscale.key)" scripts/sign.sh ФАЙЛ...
set -euo pipefail

: "${MINISIGN_SECRET_KEY:?MINISIGN_SECRET_KEY не задано}"

if ! command -v minisign >/dev/null 2>&1; then
    echo "sign.sh: minisign не знайдено в PATH" >&2
    exit 1
fi

# Ключ ніколи не торкається робочого дерева: випадково закомічений
# vau-tailscale.key — це вся модель загроз цього файлу, що провалилась разом.
keyfile=$(mktemp)
chmod 600 "$keyfile"
trap 'rm -f "$keyfile"' EXIT
printf '%s' "$MINISIGN_SECRET_KEY" > "$keyfile"

comment="Vau-Tailscale $(git describe --tags --always --dirty 2>/dev/null || echo unknown)"

for f in "$@"; do
    [ -f "$f" ] || { echo "sign.sh: файлу немає: $f" >&2; exit 1; }
    minisign -S -s "$keyfile" -m "$f" -x "$f.minisig" -c "$comment" -t "$comment"
    echo "підписано: $f.minisig"
done
