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
EXTRA_ARGS=""            # extra tailscaled flags, e.g. --port=41641
HEALTH_INTERVAL=60       # seconds between health checks
HEALTH_FAILS=3           # unanswered checks in a row before we restart the daemon
RESTART_MIN=5            # first restart delay, seconds
RESTART_MAX=300          # cap for the exponential backoff, seconds
HEALTHY_AFTER=600        # a run this long counts as healthy and resets the backoff
DAEMON_LOG_MAX_KB=2048   # rotate the daemon log above this size

[ -f "$CONF" ] && . "$CONF"

BIN="$STATE/tailscaled"
CLI="$STATE/tailscale"
SOCK="$STATE/tailscaled.sock"
DLOG="$STATE/daemon.log"
PIDFILE="$STATE/tailscaled.pid"
SUPFILE="$STATE/supervisor.pid"

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# ----- helpers ----------------------------------------------------------------

tun_flag() {
    case "$TUN_MODE" in
        kernel) echo "tailscale0,userspace-networking" ;;   # try TUN, fall back
        *)      echo "userspace-networking" ;;
    esac
}

rotate_daemon_log() {
    [ -f "$DLOG" ] || return 0
    sz=$(stat -c %s "$DLOG" 2>/dev/null || echo 0)
    [ "$((sz / 1024))" -ge "$DAEMON_LOG_MAX_KB" ] && mv -f "$DLOG" "$DLOG.1"
    return 0
}

# The daemon is given a CLEAN environment on purpose. tailscaled hands its own
# environment down to Tailscale SSH sessions, and it resolves helper binaries
# through PATH; a PATH inherited from a terminal app would mean root running
# binaries that a non-root uid can rewrite (docs/vau/AUDIT.md, H3/H5).
start_daemon() {
    rotate_daemon_log
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

# Health is judged by an ANSWER, not by a live pid. A tailscaled that is running
# but no longer serving its socket looks perfectly healthy to pgrep while the
# phone is, in practice, gone.
health_ok() {
    "$CLI" --socket="$SOCK" status --json >/dev/null 2>&1
}

health_loop() {
    fails=0
    while true; do
        sleep "$HEALTH_INTERVAL"
        [ -f "$PIDFILE" ] || continue
        pid=$(cat "$PIDFILE" 2>/dev/null)
        kill -0 "$pid" 2>/dev/null || continue   # supervisor handles a dead pid
        if health_ok; then
            [ "$fails" -gt 0 ] && log "health: socket answers again after $fails miss(es)"
            fails=0
        else
            fails=$((fails + 1))
            log "health: no answer from the daemon socket ($fails/$HEALTH_FAILS)"
            if [ "$fails" -ge "$HEALTH_FAILS" ]; then
                log "health: restarting the daemon (pid $pid) — running but not answering"
                kill "$pid" 2>/dev/null
                fails=0
            fi
        fi
    done
}

supervise() {
    delay=$RESTART_MIN
    while true; do
        t0=$(date +%s)
        start_daemon
        log "tailscaled started (pid $daemon_pid, tun=$(tun_flag))"
        wait "$daemon_pid"
        rc=$?
        up=$(( $(date +%s) - t0 ))
        [ "$up" -ge "$HEALTHY_AFTER" ] && delay=$RESTART_MIN
        log "tailscaled exited rc=$rc after ${up}s — restarting in ${delay}s"
        sleep "$delay"
        delay=$((delay * 2))
        [ "$delay" -gt "$RESTART_MAX" ] && delay=$RESTART_MAX
    done
}

stop_all() {
    for f in "$SUPFILE" "$PIDFILE"; do
        [ -f "$f" ] || continue
        pid=$(cat "$f" 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        rm -f "$f"
    done
    log "stopped by request"
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
esac

mkdir -p "$STATE" && chmod 700 "$STATE"

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
supervise &
echo $! > "$SUPFILE"
health_loop &
