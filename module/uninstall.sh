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

# Як і в service.sh: pid із файлу після ребуту може належати чужому процесу,
# тож убиваємо лише той, чий cmdline збігається з очікуваним.
for f in "$STATE/supervisor.pid:service.sh" "$STATE/health.pid:service.sh" "$STATE/tailscaled.pid:tailscaled"; do
    file=${f%%:*}
    pid=$(cat "$file" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) rm -f "$file"; continue ;; esac
    case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
        *"${f#*:}"*) kill "$pid" 2>/dev/null ;;
    esac
    rm -f "$file"
done

echo "[$(date '+%m-%d %H:%M:%S')] модуль видалено; стан збережено в $STATE" >> "$LOG"
