#!/usr/bin/env bash
#
# Sign release artifacts with minisign.
#
# The key lives only in the CI secret MINISIGN_SECRET_KEY (the raw contents of
# a password-less minisign secret key). A password-protected key cannot be used
# here: minisign would prompt, and a prompt in CI is a hang, not a signature.
#
# Verification, for whoever downloads a release:
#   minisign -Vm tailscale_<ver>_arm64.tgz -P <public key from docs/BUILD.md>
#
# Usage: MINISIGN_SECRET_KEY="$(cat vau-tailscale.key)" scripts/sign.sh FILE...
set -euo pipefail

: "${MINISIGN_SECRET_KEY:?MINISIGN_SECRET_KEY is not set}"

if ! command -v minisign >/dev/null 2>&1; then
    echo "sign.sh: minisign not found in PATH" >&2
    exit 1
fi

# The key never touches the working tree: a stray vau-tailscale.key committed by
# accident is the whole threat model of this file failing at once.
keyfile=$(mktemp)
chmod 600 "$keyfile"
trap 'rm -f "$keyfile"' EXIT
printf '%s' "$MINISIGN_SECRET_KEY" > "$keyfile"

comment="Vau-Tailscale $(git describe --tags --always --dirty 2>/dev/null || echo unknown)"

for f in "$@"; do
    [ -f "$f" ] || { echo "sign.sh: no such file: $f" >&2; exit 1; }
    minisign -S -s "$keyfile" -m "$f" -x "$f.minisig" -c "$comment" -t "$comment"
    echo "signed: $f.minisig"
done
