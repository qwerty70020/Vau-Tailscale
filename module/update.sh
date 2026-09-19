#!/system/bin/sh
#
# Vau Tailscale — оновлювач, яким керує WebUI модуля.
#
# Два різні питання легко сплутати, тому скрипт відповідає на них окремо:
#
#   1. Чи є новіша збірка ЦЬОГО модуля? Її можна встановити з телефону,
#      і цей скрипт це робить.
#   2. Чи є новіший upstream-реліз TAILSCALE? Його з телефону встановити
#      не можна взагалі — потрібен перенос патчу на новий upstream-тег і
#      збірка в CI. Скрипт лише повідомляє про це, щоб власник знав, коли
#      час перезбирати, а не вірив, що кнопка все зробить.
#
# Усе працює системними інструментами (/system/bin/curl, unzip, sha256sum):
# ніщо тут не має залежати від термінального застосунку, бо демон, який ми
# оновлюємо, — той самий, що тримає телефон досяжним ще до старту цього
# застосунку.

REPO=qwerty70020/Vau-Tailscale
STATE=/data/adb/tailscale
MODDIR=${0%/*}
LOG=/data/local/tmp/vau_tailscale.log
WORK=/data/local/tmp/vau_update
# -L не опційний: кожен URL releases/latest/download/... — це 302, і без нього
# curl пише файл нульової довжини, а кожне поле парситься як порожнє — що
# виглядає точнісінько як «оновлень немає». Виміряно: 302/0 байт без нього,
# 200/292 байти з ним.
CURL="/system/bin/curl -sSL --max-time 60 --retry 2"

log() { echo "[$(date '+%m-%d %H:%M:%S')] update: $*" >> "$LOG"; }
say() { echo "$*"; }

installed_code() { grep -m1 '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2; }
installed_ver()  { grep -m1 '^version='     "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2; }

# Коміт, з якого зібрано запущений бінарник, і upstream-версія, на якій він
# базується. `tailscale version` друкує обидва.
running_ver() { "$STATE/tailscaled" --version 2>/dev/null | head -1; }

json_field() { # json_field <файл> <ключ>  — на Android немає jq
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
    if [ ! -s "$WORK/update.json" ]; then
        say "update.json порожній — перевір мережу"; return 1
    fi
    NEW_VER=$(json_field "$WORK/update.json" version)
    NEW_CODE=$(json_field "$WORK/update.json" versionCode)
    NEW_URL=$(json_field "$WORK/update.json" zipUrl)
    say "у релізі:      $NEW_VER (versionCode $NEW_CODE)"

    # Upstream — лише для інформації.
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
    if ! $CURL -o "$WORK/$ZIP_NAME" "$NEW_URL"; then
        say "завантаження не вдалося"; log "download failed: $NEW_URL"; return 1
    fi

    # Цілісність, а не автентичність: SHA256SUMS приходить із того самого
    # релізу по HTTPS, тож ловить обрізане чи пошкоджене завантаження. Він НЕ
    # доводить, хто зібрав файл, — для цього в релізі є підпис minisign, а його
    # перевірка потребує верифікатора, якого на телефоні поза термінальним
    # застосунком немає. Перевіряється на десктопі, перш ніж довіряти новому
    # ключу.
    if $CURL -o "$WORK/SHA256SUMS" \
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

    # Модуль працює на обох root-реалізаціях, а пакети вони ставлять по-різному:
    # у KernelSU є ksud, у Magisk — `magisk --install-module`. На другому
    # телефоні (OnePlus Nord, Magisk 30700) ksud немає взагалі, тож захардкодити
    # його означало б упасти на останньому кроці, коли завантаження і контрольна
    # сума вже пройшли.
    #
    # Обидва шукаємо за абсолютним шляхом, перш ніж питати PATH, бо PATH не
    # однаковий скрізь, де може виконуватись скрипт. Через Tailscale SSH це
    # /system/bin:/system_ext/bin:/vendor/bin:/apex/... без жодного симлінку на
    # magisk, і `command -v magisk` тоді провалюється на телефоні, де Magisk
    # явно є, — виміряно на Nord, де встановлення померло саме тут із
    # «ні ksud, ні magisk», тоді як /data/adb/magisk/magisk -V друкував 30700.
    if [ -x /data/adb/ksud ]; then
        INSTALLER="/data/adb/ksud module install"
    elif [ -x /data/adb/magisk/magisk ]; then
        INSTALLER="/data/adb/magisk/magisk --install-module"
    elif command -v ksud >/dev/null 2>&1; then
        INSTALLER="ksud module install"
    elif command -v magisk >/dev/null 2>&1; then
        INSTALLER="magisk --install-module"
    else
        say "не знайдено ні ksud, ні magisk — встанови пакет вручну:"
        say "$WORK/$ZIP_NAME"
        return 1
    fi

    say "встановлюю ($INSTALLER)…"
    # Не `$INSTALLER … | tail -5` в умові: статус конвеєра — це статус tail,
    # тобто завжди 0, і відхилений zip звітувався б як встановлений.
    OUT=$($INSTALLER "$WORK/$ZIP_NAME" 2>&1); RC=$?
    printf '%s\n' "$OUT" | tail -5
    if [ "$RC" -eq 0 ]; then
        log "installed $NEW_VER"
        say "ГОТОВО: $NEW_VER встановлено, застосується після перезавантаження"
        rm -f "$WORK/$ZIP_NAME"
        return 0
    fi
    say "встановлювач не зміг застосувати пакет (код $RC)"; log "install failed rc=$RC ($INSTALLER)"; return 1
}

case "$1" in
    install) install_update ;;
    *)       check ;;
esac
