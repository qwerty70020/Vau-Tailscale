#!/bin/bash
# Сторож достижимости телефонов, живёт на сервере.
#
# Проверка снаружи, а не на самом телефоне: выключенный или потерявший сеть
# телефон не может сообщить, что он выключен, поэтому тревогу должно поднимать
# замеченное молчание. Токен бота остаётся здесь и на устройство не попадает.
#
# Сообщения шлются только при СМЕНЕ состояния, иначе каждые пять минут в чат
# падал бы один и тот же текст и его перестали бы читать.
set -u

ENVFILE=/home/vau/vauserver/.env
STATEFILE="$HOME/.moto-watch.state"
LOGFILE="$HOME/moto-watch.log"
HOSTS="moto-root phone"

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

touch "$STATEFILE"
NOW_TIME=$(date '+%H:%M')

for host in $HOSTS; do
    if reachable "$host"; then now=up; else now=down; fi
    was=$(grep -m1 "^$host=" "$STATEFILE" | cut -d= -f2)
    [ -z "$was" ] && was=unknown

    if [ "$now" != "$was" ]; then
        echo "$(date '+%m-%d %H:%M:%S') $host: $was -> $now" >> "$LOGFILE"
        # unknown -> up молчит: это первый запуск, а не восстановление.
        if [ "$now" = down ]; then
            notify "🔴 $host недоступен ($NOW_TIME)"
        elif [ "$was" = down ]; then
            notify "🟢 $host снова доступен ($NOW_TIME)"
        fi
        grep -v "^$host=" "$STATEFILE" > "$STATEFILE.tmp" 2>/dev/null
        mv -f "$STATEFILE.tmp" "$STATEFILE" 2>/dev/null
        echo "$host=$now" >> "$STATEFILE"
    fi
done
