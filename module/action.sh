#!/system/bin/sh
#
# KernelSU Manager "Action" button: show what the node is doing right now.
# Read-only on purpose — anything that changes network state belongs in the
# WebUI, where it can ask for confirmation and show the command's own output.

STATE=/data/adb/tailscale
CLI="$STATE/tailscale"
SOCK="$STATE/tailscaled.sock"
LOG=/data/local/tmp/vau_tailscale.log

echo "== tailscale status =="
if [ -x "$CLI" ]; then
    "$CLI" --socket="$SOCK" status 2>&1 | head -20
else
    echo "no CLI at $CLI"
fi

echo
echo "== module log (tail) =="
tail -n 15 "$LOG" 2>/dev/null || echo "no log yet"

echo
echo "== daemon log (tail) =="
tail -n 10 "$STATE/daemon.log" 2>/dev/null || echo "no daemon log yet"
