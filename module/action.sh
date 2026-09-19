#!/system/bin/sh
#
# Кнопка «Action» у KernelSU Manager: показати, що вузол робить просто зараз.
# Навмисно лише читання — усе, що змінює стан мережі, належить WebUI, де
# можна попросити підтвердження і показати вивід самої команди.

STATE=/data/adb/tailscale
CLI="$STATE/tailscale"
SOCK="$STATE/tailscaled.sock"
LOG=/data/local/tmp/vau_tailscale.log

echo "== tailscale status =="
if [ -x "$CLI" ]; then
    "$CLI" --socket="$SOCK" status 2>&1 | head -20
else
    echo "немає CLI за шляхом $CLI"
fi

echo
echo "== лог модуля (хвіст) =="
tail -n 15 "$LOG" 2>/dev/null || echo "логу ще немає"

echo
echo "== лог демона (хвіст) =="
tail -n 10 "$STATE/daemon.log" 2>/dev/null || echo "логу демона ще немає"
