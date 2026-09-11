#!/system/bin/sh
#
# Vau Tailscale — updater, driven from the module's WebUI.
#
# Two different questions get confused easily, so this script answers them
# separately:
#
#   1. Is there a newer build of THIS module? That can be installed from the
#      phone, and this script does it.
#   2. Is there a newer TAILSCALE upstream release? That cannot be installed
#      from the phone at all — it needs the patch rebased onto the new upstream
#      tag and a CI build. The script only reports it, so the owner knows when
#      it is time to rebuild rather than believing a button will do it.
#
# Everything runs with the system tools (/system/bin/curl, unzip, sha256sum):
# nothing here may depend on a terminal app, because the daemon this updates is
# the one that keeps the phone reachable before that app can even start.

REPO=qwerty70020/Vau-Tailscale
STATE=/data/adb/tailscale
MODDIR=${0%/*}
LOG=/data/local/tmp/vau_tailscale.log
WORK=/data/local/tmp/vau_update
CURL="/system/bin/curl -sS --max-time 60 --retry 2"

log() { echo "[$(date '+%m-%d %H:%M:%S')] update: $*" >> "$LOG"; }
say() { echo "$*"; }

installed_code() { grep -m1 '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2; }
installed_ver()  { grep -m1 '^version='     "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2; }

# The commit the running binary was built from, and the upstream version it is
# based on. `tailscale version` prints both.
running_ver() { "$STATE/tailscaled" --version 2>/dev/null | head -1; }

json_field() { # json_field <file> <key>  — no jq on Android
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" | head -1
}

check() {
    mkdir -p "$WORK" || { say "не можу створити $WORK"; return 1; }

    say "встановлено:   $(installed_ver) (versionCode $(installed_code))"
    say "працює:        $(running_ver)"

    if ! $CURL -o "$WORK/update.json" \
        "https://github.com/$REPO/releases/latest/download/update.json"; then
        say "не вдалося отримати update.json — немає мережі?"
        return 1
    fi
    NEW_VER=$(json_field "$WORK/update.json" version)
    NEW_CODE=$(json_field "$WORK/update.json" versionCode)
    NEW_URL=$(json_field "$WORK/update.json" zipUrl)
    say "у релізі:      $NEW_VER (versionCode $NEW_CODE)"

    # Upstream, for information only.
    if $CURL -o "$WORK/ts.json" "https://api.github.com/repos/tailscale/tailscale/releases/latest"; then
        UP=$(json_field "$WORK/ts.json" tag_name)
        say "апстрим Tailscale: ${UP:-?}"
        case "$(running_ver)" in
            *"${UP#v}"*) : ;;
            *) say "  ↳ наш бінарник зібрано НЕ з цієї версії — потрібен перенос патчу і збірка в CI" ;;
        esac
    fi

    CUR_CODE=$(installed_code)
    if [ -n "$NEW_CODE" ] && [ -n "$CUR_CODE" ] && [ "$NEW_CODE" -gt "$CUR_CODE" ] 2>/dev/null; then
        say "Є ОНОВЛЕННЯ МОДУЛЯ: $NEW_VER"
        return 0
    fi
    say "оновлення модуля не потрібне"
    return 2
}

install_update() {
    check || { [ $? = 2 ] && return 0; return 1; }

    ZIP_NAME=$(basename "$NEW_URL")
    say "завантажую $ZIP_NAME…"
    if ! $CURL -L -o "$WORK/$ZIP_NAME" "$NEW_URL"; then
        say "завантаження не вдалося"; log "download failed: $NEW_URL"; return 1
    fi

    # Integrity, not authenticity: SHA256SUMS comes from the same release over
    # HTTPS, so it catches a truncated or corrupted download. It does NOT prove
    # who built the file — that is what the minisign signature in the release is
    # for, and verifying it needs a verifier this phone does not carry outside
    # the terminal app. Checked on a desktop before trusting a new key.
    if $CURL -L -o "$WORK/SHA256SUMS" \
        "https://github.com/$REPO/releases/latest/download/SHA256SUMS"; then
        WANT=$(grep " $ZIP_NAME\$" "$WORK/SHA256SUMS" | cut -d' ' -f1)
        GOT=$(sha256sum "$WORK/$ZIP_NAME" | cut -d' ' -f1)
        if [ -z "$WANT" ]; then
            say "у SHA256SUMS немає рядка для $ZIP_NAME — зупиняюсь"; return 1
        fi
        if [ "$WANT" != "$GOT" ]; then
            say "СУМА НЕ ЗБІГЛАСЯ — файл пошкоджено або підмінено, зупиняюсь"
            log "sha mismatch want=$WANT got=$GOT"
            rm -f "$WORK/$ZIP_NAME"; return 1
        fi
        say "sha256 збігається"
    else
        say "не вдалося отримати SHA256SUMS — зупиняюсь"; return 1
    fi

    say "встановлюю через ksud…"
    if /data/adb/ksud module install "$WORK/$ZIP_NAME" 2>&1 | tail -5; then
        log "installed $NEW_VER"
        say "ГОТОВО: $NEW_VER встановлено, застосується після перезавантаження"
        rm -f "$WORK/$ZIP_NAME"
        return 0
    fi
    say "ksud не зміг встановити пакет"; log "ksud install failed"; return 1
}

case "$1" in
    install) install_update ;;
    *)       check ;;
esac
