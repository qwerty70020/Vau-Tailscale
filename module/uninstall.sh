#!/system/bin/sh
#
# Виконується, коли модуль видаляють із KernelSU Manager.
#
# Supervisor убивається ПЕРШИМ: убий спочатку демон — і supervisor просто
# запустить його знову, що виглядає точнісінько як видалення, яке не
# спрацювало.
#
# Ідентичність вузла в /data/adb/tailscale/tailscaled.state навмисно
# зберігається: повторне встановлення модуля повертає в tailnet ТОЙ САМИЙ
# вузол, з тією ж адресою й тими ж правилами ACL. Щоб піти з tailnet
# по-справжньому:
#   rm -rf /data/adb/tailscale
# і видалити вузол в адмін-консолі Tailscale.

STATE=/data/adb/tailscale
LOG=/data/local/tmp/vau_tailscale.log

for f in "$STATE/supervisor.pid" "$STATE/health.pid" "$STATE/tailscaled.pid"; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$f"
done

echo "[$(date '+%m-%d %H:%M:%S')] модуль видалено; стан збережено в $STATE" >> "$LOG"
