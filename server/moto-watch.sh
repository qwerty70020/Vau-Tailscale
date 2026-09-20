#!/bin/bash
# Сторож досяжності телефонів, живе на сервері.
#
# Перевірка ззовні, а не на самому телефоні: вимкнений або позбавлений мережі
# телефон не може повідомити, що він вимкнений, тож тривогу має здіймати
# помічена тиша. Токен бота лишається тут і на пристрій не потрапляє.
#
# Одиниця спостереження — ТЕЛЕФОН, а не окремий вузол. У кожного телефона
# кілька вузлів у tailnet, і це різні ШАРИ доступності, а не дублікати:
#   moto-root / nord-root — демон модуля з /data/adb (DE), відповідає ще до
#                           введення PIN;
#   phone                 — застосунок Tailscale на Моторолі;
#   nord                  — Termux на Норді, живе в CE-сховищі й до першого
#                           розблокування не існує.
# Мовчать усі вузли й tailnet їх не бачить — телефон без мережі (метро, ліфт)
# або вимкнений: це «чекаємо на мережу», а не поломка. Мовчить лише частина —
# щось зламалося саме на телефоні (демон упав, телефон перезавантажився і
# стоїть на екрані блокування), і про це варто сказати окремо.
#
# Повідомлення йдуть лише при ЗМІНІ стану, інакше кожні п'ять хвилин у чат
# падав би той самий текст і його перестали б читати.
set -u

ENVFILE=/home/vau/vauserver/.env
STATEFILE="$HOME/.moto-watch.state"
LOGFILE="$HOME/moto-watch.log"
# телефон:вузол,вузол — вузли це ssh-аліаси, у ~/.ssh/config вони вказують
# на tailnet-адреси, за якими ми ж їх і знаходимо в `tailscale status`.
DEVICES="moto:moto-root,phone nord:nord-root,nord"

BOT_TOKEN=$(grep -m1 '^BOT_TOKEN=' "$ENVFILE" | cut -d= -f2- | tr -d '"'"'"'')
CHAT_ID=$(grep -m1 '^BOT_CHAT_ID=' "$ENVFILE" | cut -d= -f2- | tr -d '"'"'"'')

notify() {
    [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] || return 0
    curl -sS --max-time 20 -o /dev/null \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$1" \
        "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" || true
}

reachable() {
    timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=12 "$1" 'echo ok' >/dev/null 2>&1
}

# Чи бачить координаційний сервер вузол онлайн. Один знімок на запуск;
# без нього (tailscaled на сервері мовчить) вважаємо, що не знаємо.
TS_JSON=$(tailscale status --json 2>/dev/null)
tailnet_online() {
    [ -n "$TS_JSON" ] || { echo unknown; return; }
    addr=$(ssh -G "$1" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')
    jq -r --arg a "$addr" --arg h "$1" '
        [.Peer[] | select((.TailscaleIPs|index($a)) or .HostName==$h
                          or (.DNSName|startswith($h+".")))] | first // {}
        | if has("Online") then (.Online|tostring) else "unknown" end' <<<"$TS_JSON"
}

# Хвилини від мітки часу в state-файлі; порожньо, якщо мітки нема або
# минуло менше хвилини (щоб не писати «через 0 хв»).
since_min() {
    [ -n "$1" ] || return 0
    m=$(( ($(date +%s) - $1) / 60 ))
    [ "$m" -gt 0 ] && echo "$m"
}

touch "$STATEFILE"
NOW_TIME=$(date '+%H:%M')

for entry in $DEVICES; do
    dev=${entry%%:*}
    hosts=${entry#*:}
    up=""; down=""; online=no
    for host in ${hosts//,/ }; do
        if reachable "$host"; then
            up="$up $host"
        else
            down="$down $host"
            [ "$(tailnet_online "$host")" = true ] && online=yes
        fi
    done
    up=${up# }; down=${down# }

    # Стан телефона: up / nonet / silent / partial.
    if [ -z "$down" ]; then
        now=up
    elif [ -z "$up" ] && [ "$online" = no ]; then
        now=nonet     # усі мовчать і tailnet їх не бачить — мережі нема
    elif [ -z "$up" ]; then
        now=silent    # tailnet бачить, а SSH не відповідає — зламано на телефоні
    else
        now=partial   # частина вузлів відповідає
    fi

    line=$(grep -m1 "^$dev=" "$STATEFILE")
    was=${line#*=}; was=${was%% *}
    since=${line#* }; [ "$since" = "$line" ] && since=""
    [ -z "$was" ] && was=unknown

    if [ "$now" != "$was" ]; then
        echo "$(date '+%m-%d %H:%M:%S') $dev: $was -> $now${down:+ (мовчить: $down)}" >> "$LOGFILE"
        mins=$(since_min "$since")
        case "$now" in
            nonet)
                notify "⏳ $dev без мережі — чекаю на мережу ($NOW_TIME)" ;;
            silent)
                notify "🔴 $dev: tailnet бачить вузол, а SSH не відповідає — схоже, зламано на телефоні ($NOW_TIME)" ;;
            partial)
                hint=""
                case " $down " in
                    *" nord "*)      hint=" — телефон перезавантажився і стоїть на екрані блокування?" ;;
                    *"-root "*)      hint=" — демон модуля впав, застосунок живий" ;;
                esac
                notify "🟠 $dev: мовчить $down, відповідає $up$hint ($NOW_TIME)" ;;
            up)
                # unknown -> up мовчить: це перший запуск, а не відновлення.
                case "$was" in
                    nonet)   notify "🟢 $dev знову в мережі${mins:+ (без мережі $mins хв)} ($NOW_TIME)" ;;
                    silent|partial)
                             notify "🟢 $dev знову доступний повністю${mins:+ (через $mins хв)} ($NOW_TIME)" ;;
                esac ;;
        esac
        grep -v "^$dev=" "$STATEFILE" > "$STATEFILE.tmp" 2>/dev/null
        mv -f "$STATEFILE.tmp" "$STATEFILE" 2>/dev/null
        echo "$dev=$now $(date +%s)" >> "$STATEFILE"
    fi
done
