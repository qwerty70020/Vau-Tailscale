#!/system/bin/sh
#
# Runs when the module is removed from KernelSU Manager.
#
# The supervisor is killed FIRST: kill the daemon first and the supervisor
# simply starts it again, which looks exactly like an uninstall that did not
# work.
#
# The node identity in /data/adb/tailscale/tailscaled.state is kept on purpose:
# reinstalling the module then rejoins the tailnet as the SAME node, with the
# same address and the same ACL rules. To leave the tailnet for real:
#   rm -rf /data/adb/tailscale
# and remove the node in the Tailscale admin console.

STATE=/data/adb/tailscale
LOG=/data/local/tmp/vau_tailscale.log

for f in "$STATE/supervisor.pid" "$STATE/tailscaled.pid"; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$f"
done

echo "[$(date '+%m-%d %H:%M:%S')] module uninstalled; state kept in $STATE" >> "$LOG"
