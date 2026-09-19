#!/system/bin/sh
#
# Vau Tailscale — KernelSU late_start service
# ---------------------------------------------------------------------------
# Запускає tailscaled від root і не дає йому померти. Усе потрібне лежить у
# /data/adb/tailscale — це DE-сховище, доступне ще до першого розблокування
# власником. У цьому весь сенс модуля: і застосунок Tailscale, і Termux живуть
# у CE-сховищі й не можуть стартувати, доки не введено PIN, тож телефон, що
# перезавантажився без нагляду, недосяжний, поки хтось до нього не підійде.
#
# Типовий режим — userspace networking: без інтерфейсу tailscale0, без ip rule,
# без iptables. Тому він не може здалеку покласти мережу телефону й не б'ється
# із застосунком Tailscale за єдиний VPN-слот Android. Режим kernel-TUN існує
# (TUN_MODE=kernel), але його не можна вмикати, доки не закриті знахідки щодо
# DNS і маршрутизації з docs/vau/AUDIT.md.
#
# !!! ТРИМАЙ ЦЕЙ ФАЙЛ ЛИШЕ З LF (без CRLF) І НЕ ПАКУЙ ЙОГО В ZIP НА WINDOWS !!!
# ---------------------------------------------------------------------------

MODDIR=${0%/*}

# ----- налаштування -----------------------------------------------------------
# Тут — типові значення; свої телефон тримає у $CONF, поза каталогом модуля,
# куди не дістає ні оновлення, ні перевстановлення.
STATE=/data/adb/tailscale
CONF=/data/adb/vau-tailscale.conf
LOG=/data/local/tmp/vau_tailscale.log

TUN_MODE=userspace       # userspace = без інтерфейсу/маршрутів/iptables; kernel = повний TUN
EXTRA_ARGS=""            # додаткові прапорці tailscaled, напр. --socks5-server=127.0.0.1:1055
HOTSPOT_SHARE=0          # лише kernel: 1 = роздавати tailnet клієнтам точки доступу (MASQUERADE на tailscale0)
HEALTH_INTERVAL=60       # секунд між перевірками здоров'я
HEALTH_FAILS=3           # стільки провалених перевірок поспіль — і демон перезапускається
RESTART_MIN=5            # перша затримка перезапуску, секунд
RESTART_MAX=300          # стеля експоненційного відкату, секунд
HEALTHY_AFTER=600        # запуск, що прожив стільки, вважається здоровим і скидає відкат
DAEMON_LOG_MAX_KB=2048   # ротувати лог демона понад цей розмір

# Запуск, коротший за це, — «швидкий провал»: так поводиться бінарник, який
# узагалі не може стартувати, на відміну від того, що працював і потім упав.
FAST_FAIL_SECS=60
# Після стількох швидких провалів поспіль повертається попередній бінарник.
# Інакше оновлення, що ламає демон, лишає телефон недосяжним, а єдиний шлях
# усередину — саме те, що щойно зламалось.
ROLLBACK_FAILS=3

# Необов'язково: адреса в tailnet, яку пінгувати як СПРАВЖНЮ перевірку
# досяжності. Сокет, що відповідає, доводить лише, що демон живий, а не що
# вузол може з кимось говорити: 2026-09-10 порожня політика tailnet лишила цей
# вузол цілком чуйним і цілком відрізаним. Постав сюди peer, який важливий,
# наприклад домашній сервер.
HEALTH_PEER=""
# Необов'язково: push-URL Uptime Kuma, який смикається, поки вузол здоровий.
# Сигнал — тиша: вимкнений телефон не може повідомити, що він вимкнений, тож
# тривогу має здіймати саме відсутність push.
KUMA_PUSH_URL=""
# host:port власного SOCKS-проксі демона, коли push має йти через tailnet,
# а VPN-застосунок його не несе.
KUMA_VIA_SOCKS=""

[ -f "$CONF" ] && . "$CONF"

BIN="$STATE/tailscaled"
PREV="$STATE/tailscaled.prev"
CLI="$STATE/tailscale"
SOCK="$STATE/tailscaled.sock"
DLOG="$STATE/daemon.log"
HIST="$STATE/history.log"
PIDFILE="$STATE/tailscaled.pid"
SUPFILE="$STATE/supervisor.pid"
HLTFILE="$STATE/health.pid"

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Історія фіксує ЛИШЕ ПЕРЕХОДИ — піднявся, впав, відкат, перезапуск. Рядок тут
# означає, що щось змінилося; саме це робить «уночі відвалилось» питанням із
# відповіддю, а не спогадом.
hist() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$HIST"; }

# ----- допоміжні функції ------------------------------------------------------

tun_flag() {
    case "$TUN_MODE" in
        kernel) echo "tailscale0,userspace-networking" ;;   # спробувати TUN, інакше відкат
        *)      echo "userspace-networking" ;;
    esac
}

rotate_log() {
    f=$1; max=$2
    [ -f "$f" ] || return 0
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    [ "$((sz / 1024))" -ge "$max" ] && mv -f "$f" "$f.1"
    return 0
}

# Демон навмисно отримує ЧИСТЕ оточення. tailscaled передає своє оточення
# сесіям Tailscale SSH і шукає допоміжні бінарники через PATH; PATH,
# успадкований від термінального застосунку, означав би, що root запускає
# бінарники, які може переписати не-root uid (docs/vau/AUDIT.md, H3/H5).
start_daemon() {
    rotate_log "$DLOG" "$DAEMON_LOG_MAX_KB"
    # shellcheck disable=SC2086
    env -i PATH=/system/bin HOME="$STATE" TMPDIR=/data/local/tmp \
        TS_ANDROID_HOTSPOT_SHARE="$([ "$HOTSPOT_SHARE" = 1 ] && echo true || echo false)" \
        "$BIN" \
        --statedir="$STATE" \
        --socket="$SOCK" \
        --tun="$(tun_flag)" \
        --no-logs-no-support \
        $EXTRA_ARGS \
        >> "$DLOG" 2>&1 &
    daemon_pid=$!
    echo "$daemon_pid" > "$PIDFILE"
}

backend_state() {
    "$CLI" --socket="$SOCK" status --json 2>/dev/null \
        | grep -o '"BackendState"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# Здоров'я судимо за ВІДПОВІДДЮ, а не за живим pid, і за ПРАВИЛЬНОЮ відповіддю.
# «Сокет відповів» було перевіркою тут, доки порожня політика tailnet не довела
# її марність: status відповідав миттєво, а до вузла не міг дістатись ніхто.
health_ok() {
    st=$(backend_state)
    [ "$st" = "Running" ] || { health_why="BackendState=$st"; return 1; }
    if [ -n "$HEALTH_PEER" ]; then
        if ! timeout 20 "$CLI" --socket="$SOCK" ping -c 1 -- "$HEALTH_PEER" >/dev/null 2>&1; then
            health_why="немає відповіді від $HEALTH_PEER"
            return 1
        fi
    fi
    health_why=""
    return 0
}

# Моніторинг ніколи не має ламати те, що моніторить: кожна помилка тут
# ковтається, а push — best-effort.
push_kuma() {
    [ -n "$KUMA_PUSH_URL" ] || return 0
    if [ -n "$KUMA_VIA_SOCKS" ]; then
        /system/bin/curl -sS --max-time 15 --socks5-hostname "$KUMA_VIA_SOCKS" \
            -o /dev/null "$KUMA_PUSH_URL" 2>/dev/null
    else
        /system/bin/curl -sS --max-time 15 -o /dev/null "$KUMA_PUSH_URL" 2>/dev/null
    fi
    return 0
}

health_loop() {
    fails=0
    healthy=unknown
    while true; do
        sleep "$HEALTH_INTERVAL"
        [ -f "$PIDFILE" ] || continue
        pid=$(cat "$PIDFILE" 2>/dev/null)
        kill -0 "$pid" 2>/dev/null || continue   # мертвим pid займається supervisor
        if health_ok; then
            if [ "$healthy" != "yes" ]; then
                hist "healthy (BackendState=Running${HEALTH_PEER:+, $HEALTH_PEER досяжний})"
                [ "$fails" -gt 0 ] && log "health: відновився після $fails пропуск(ів)"
                healthy=yes
            fi
            fails=0
            push_kuma
        else
            fails=$((fails + 1))
            log "health: $health_why ($fails/$HEALTH_FAILS)"
            if [ "$healthy" != "no" ]; then
                hist "unhealthy: $health_why"
                healthy=no
            fi
            if [ "$fails" -ge "$HEALTH_FAILS" ]; then
                log "health: перезапускаю демон (pid $pid) — $health_why"
                hist "перезапуск за результатом перевірки здоров'я: $health_why"
                kill "$pid" 2>/dev/null
                fails=0
            fi
        fi
    done
}

# Повернути попередній бінарник. Використовується, коли свіжий не може
# втриматись: сенс модуля — віддалений доступ, тож зламане оновлення не має
# права його відібрати, доки хтось не підійде до телефону.
roll_back() {
    [ -x "$PREV" ] || { log "rollback: немає $PREV, куди відкочуватись"; return 1; }
    if cmp -s "$BIN" "$PREV"; then
        log "rollback: попередній бінарник ідентичний — проблема не в бінарнику"
        return 1
    fi
    cp -f "$PREV" "$BIN.rb" 2>/dev/null || return 1
    chmod 0755 "$BIN.rb" 2>/dev/null
    mv -f "$BIN.rb" "$BIN" 2>/dev/null || return 1
    log "ROLLBACK: повернуто попередній tailscaled після повторних швидких провалів"
    hist "ROLLBACK до попереднього бінарника"
    return 0
}

supervise() {
    delay=$RESTART_MIN
    fastfails=0
    while true; do
        t0=$(date +%s)
        start_daemon
        log "tailscaled запущено (pid $daemon_pid, tun=$(tun_flag))"
        hist "daemon start (pid $daemon_pid)"
        wait "$daemon_pid"
        rc=$?
        up=$(( $(date +%s) - t0 ))
        hist "daemon exit rc=$rc after ${up}s"

        if [ "$up" -lt "$FAST_FAIL_SECS" ]; then
            fastfails=$((fastfails + 1))
            log "tailscaled вийшов rc=$rc через ${up}s — швидкий провал $fastfails/$ROLLBACK_FAILS"
        else
            fastfails=0
            [ "$up" -ge "$HEALTHY_AFTER" ] && delay=$RESTART_MIN
            log "tailscaled вийшов rc=$rc через ${up}s — перезапуск за ${delay}s"
        fi

        if [ "$fastfails" -ge "$ROLLBACK_FAILS" ] && roll_back; then
            fastfails=0
            delay=$RESTART_MIN
        fi

        sleep "$delay"
        delay=$((delay * 2))
        [ "$delay" -gt "$RESTART_MAX" ] && delay=$RESTART_MAX
    done
}

stop_all() {
    # Спершу supervisor, потім health-цикл, потім демон: убий демон, поки
    # supervisor ще живий, — і за секунду його перезапустять, що виглядає
    # точнісінько як зупинка, яка не спрацювала.
    for f in "$SUPFILE" "$HLTFILE" "$PIDFILE"; do
        [ -f "$f" ] || continue
        pid=$(cat "$f" 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        rm -f "$f"
    done
    log "зупинено на вимогу"
    hist "зупинено на вимогу"
}

# ----- точки входу ------------------------------------------------------------

case "$1" in
    stop)
        stop_all
        exit 0
        ;;
    status)
        "$CLI" --socket="$SOCK" status 2>&1
        exit $?
        ;;
    health)
        if health_ok; then echo "healthy"; exit 0; else echo "unhealthy: $health_why"; exit 1; fi
        ;;
    rollback)
        roll_back && echo "відкочено; перезапусти демон, щоб він підхопив бінарник"
        exit $?
        ;;
esac

mkdir -p "$STATE" && chmod 700 "$STATE"
rotate_log "$HIST" 256
# Лог модуля отримує рядок на кожну провалену перевірку; телефон, що провів
# ніч офлайн, пише їх сотнями, а більше ніхто його ніколи не підрізав.
rotate_log "$LOG" 512

if [ ! -x "$BIN" ]; then
    log "немає tailscaled у $BIN — нічого запускати"
    exit 0
fi

if [ -f "$SUPFILE" ] && kill -0 "$(cat "$SUPFILE" 2>/dev/null)" 2>/dev/null; then
    log "supervisor уже працює — нічого робити"
    exit 0
fi

# Навмисно НЕ чекаємо ні sys.boot_completed, ні першого розблокування: уся
# цінність модуля — бути в tailnet раніше, ніж станеться будь-що з цього.
log "=== boot: запускаю supervisor (tun=$(tun_flag)) ==="
hist "=== boot ==="
supervise &
echo $! > "$SUPFILE"
health_loop &
echo $! > "$HLTFILE"
