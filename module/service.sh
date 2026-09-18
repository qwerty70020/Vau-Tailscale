#!/system/bin/sh
#
# Vau Tailscale — KernelSU late_start service
# ---------------------------------------------------------------------------
# Starts tailscaled as root and keeps it alive. Everything it needs lives in
# /data/adb/tailscale, which is DE storage: readable before the owner's first
# unlock. That is the entire point of this module — the Tailscale app and
# Termux both live in CE storage and cannot run until a PIN is entered, so a
# phone that reboots unattended is unreachable until somebody walks over to it.
#
# Default mode is userspace networking: no tailscale0 interface, no ip rules,
# no iptables. It therefore cannot take the phone's network down from far away,
# and it does not fight the Tailscale app for the single Android VPN slot. The
# kernel-TUN mode exists (TUN_MODE=kernel) but must not be enabled before the
# DNS and routing findings in docs/vau/AUDIT.md are fixed.
#
# !!! KEEP THIS FILE LF-ONLY (no CRLF) AND DO NOT ZIP IT ON WINDOWS !!!
# ---------------------------------------------------------------------------

MODDIR=${0%/*}

# ----- tunables ---------------------------------------------------------------
# Defaults live here; a handset keeps its own values in $CONF, outside the
# module directory, where neither an update nor a reinstall can reach them.
STATE=/data/adb/tailscale
CONF=/data/adb/vau-tailscale.conf
LOG=/data/local/tmp/vau_tailscale.log

TUN_MODE=userspace       # userspace = no interface/routes/iptables; kernel = full TUN
EXTRA_ARGS=""            # extra tailscaled flags, e.g. --socks5-server=127.0.0.1:1055
HEALTH_INTERVAL=60       # seconds between health checks
HEALTH_FAILS=3           # failed checks in a row before the daemon is restarted
RESTART_MIN=5            # first restart delay, seconds
RESTART_MAX=300          # cap for the exponential backoff, seconds
HEALTHY_AFTER=600        # a run this long counts as healthy and resets the backoff
DAEMON_LOG_MAX_KB=2048   # rotate the daemon log above this size

# A run shorter than this is a "fast failure" — the shape of a binary that
# cannot start at all, as opposed to one that ran and later died.
FAST_FAIL_SECS=60
# After this many fast failures in a row the previous binary is put back. An
# update that breaks the daemon otherwise leaves the phone unreachable, and the
# only way back in is the very thing that just broke.
ROLLBACK_FAILS=3

# Optional: a tailnet address to ping as a REAL reachability check. An answering
# socket proves the daemon is alive, not that the node can talk to anyone — on
# 2026-09-10 an empty tailnet policy left this node perfectly responsive and
# completely cut off. Set it to the peer that matters, e.g. the home server.
HEALTH_PEER=""
# Optional: Uptime Kuma push URL, called while the node is healthy. Silence is
# the signal: a phone that is switched off cannot report that it is switched
# off, so absence of a push has to be what raises the alarm.
KUMA_PUSH_URL=""
# host:port of the daemon's own SOCKS proxy, when the push has to travel over
# the tailnet and the VPN app is not carrying it.
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

# History records TRANSITIONS only — up, down, rollback, restart. A line here
# means something changed, which is what makes "it dropped last night" a
# question with an answer instead of a memory.
hist() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$HIST"; }

# ----- helpers ----------------------------------------------------------------

tun_flag() {
    case "$TUN_MODE" in
        kernel) echo "tailscale0,userspace-networking" ;;   # try TUN, fall back
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

# The daemon is given a CLEAN environment on purpose. tailscaled hands its own
# environment down to Tailscale SSH sessions, and it resolves helper binaries
# through PATH; a PATH inherited from a terminal app would mean root running
# binaries that a non-root uid can rewrite (docs/vau/AUDIT.md, H3/H5).
start_daemon() {
    rotate_log "$DLOG" "$DAEMON_LOG_MAX_KB"
    # shellcheck disable=SC2086
    env -i PATH=/system/bin:/system/xbin HOME="$STATE" TMPDIR=/data/local/tmp \
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

# Health is judged by an ANSWER, not by a live pid, and by the RIGHT answer.
# "The socket replied" was the check here until an empty tailnet policy proved
# it worthless: status answered instantly while nothing could reach the node.
health_ok() {
    st=$(backend_state)
    [ "$st" = "Running" ] || { health_why="BackendState=$st"; return 1; }
    if [ -n "$HEALTH_PEER" ]; then
        if ! timeout 20 "$CLI" --socket="$SOCK" ping -c 1 -- "$HEALTH_PEER" >/dev/null 2>&1; then
            health_why="no answer from $HEALTH_PEER"
            return 1
        fi
    fi
    health_why=""
    return 0
}

# Never let monitoring break the thing it monitors: every failure here is
# swallowed, and the push is best-effort.
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
        kill -0 "$pid" 2>/dev/null || continue   # supervisor handles a dead pid
        if health_ok; then
            if [ "$healthy" != "yes" ]; then
                hist "healthy (BackendState=Running${HEALTH_PEER:+, $HEALTH_PEER reachable})"
                [ "$fails" -gt 0 ] && log "health: recovered after $fails miss(es)"
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
                log "health: restarting the daemon (pid $pid) — $health_why"
                hist "restart forced by health check: $health_why"
                kill "$pid" 2>/dev/null
                fails=0
            fi
        fi
    done
}

# Put the previous binary back. Used when a fresh one cannot stay up: the point
# of this module is remote access, so a broken update must not be able to take
# that away until someone walks over to the phone.
roll_back() {
    [ -x "$PREV" ] || { log "rollback: no $PREV to fall back to"; return 1; }
    if cmp -s "$BIN" "$PREV"; then
        log "rollback: previous binary is identical — not a binary problem"
        return 1
    fi
    cp -f "$PREV" "$BIN.rb" 2>/dev/null || return 1
    chmod 0755 "$BIN.rb" 2>/dev/null
    mv -f "$BIN.rb" "$BIN" 2>/dev/null || return 1
    log "ROLLBACK: restored the previous tailscaled after repeated fast failures"
    hist "ROLLBACK to previous binary"
    return 0
}

supervise() {
    delay=$RESTART_MIN
    fastfails=0
    while true; do
        t0=$(date +%s)
        start_daemon
        log "tailscaled started (pid $daemon_pid, tun=$(tun_flag))"
        hist "daemon start (pid $daemon_pid)"
        wait "$daemon_pid"
        rc=$?
        up=$(( $(date +%s) - t0 ))
        hist "daemon exit rc=$rc after ${up}s"

        if [ "$up" -lt "$FAST_FAIL_SECS" ]; then
            fastfails=$((fastfails + 1))
            log "tailscaled exited rc=$rc after ${up}s — fast failure $fastfails/$ROLLBACK_FAILS"
        else
            fastfails=0
            [ "$up" -ge "$HEALTHY_AFTER" ] && delay=$RESTART_MIN
            log "tailscaled exited rc=$rc after ${up}s — restarting in ${delay}s"
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
    # Supervisor first, then the health loop, then the daemon: kill the daemon
    # while the supervisor is still up and it is restarted a second later,
    # which looks exactly like a stop that did not work.
    for f in "$SUPFILE" "$HLTFILE" "$PIDFILE"; do
        [ -f "$f" ] || continue
        pid=$(cat "$f" 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        rm -f "$f"
    done
    log "stopped by request"
    hist "stopped by request"
}

# ----- entry points -----------------------------------------------------------

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
        roll_back && echo "rolled back, restart the daemon to use it"
        exit $?
        ;;
esac

mkdir -p "$STATE" && chmod 700 "$STATE"
rotate_log "$HIST" 256

if [ ! -x "$BIN" ]; then
    log "no tailscaled at $BIN — nothing to run"
    exit 0
fi

if [ -f "$SUPFILE" ] && kill -0 "$(cat "$SUPFILE" 2>/dev/null)" 2>/dev/null; then
    log "supervisor already running — nothing to do"
    exit 0
fi

# Deliberately NOT waiting for sys.boot_completed or for the first unlock: the
# whole value of this module is being on the tailnet before either happens.
log "=== boot: starting supervisor (tun=$(tun_flag)) ==="
hist "=== boot ==="
supervise &
echo $! > "$SUPFILE"
health_loop &
echo $! > "$HLTFILE"
