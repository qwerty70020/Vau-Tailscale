#!/system/bin/sh
#
# Хук встановлювача KernelSU / Magisk. Виконується з $MODPATH, що вказує на
# тимчасовий каталог модуля, поки zip встановлюється.
#
# Бінарник навмисно переноситься з каталогу модуля в /data/adb/tailscale: там
# уже живе стан демона, це DE-сховище (доступне до першого розблокування
# власником — у цьому весь сенс модуля), а одна копія замість двох економить
# 36 МБ на пристрої.

SKIPUNZIP=0
STATE=/data/adb/tailscale

ui_print "- Vau Tailscale"

mkdir -p "$STATE"
chmod 700 "$STATE"

if [ -f "$MODPATH/bin/tailscaled" ]; then
  # Зберегти старий бінарник як запасний ДО того, як його перезаписати.
  # Інакше оновлення, що не стартує, лишить телефон недосяжним, а шлях
  # усередину — саме те, що щойно зламалось; service.sh повертає цей файл
  # після повторних швидких провалів.
  if [ -x "$STATE/tailscaled" ] && ! cmp -s "$STATE/tailscaled" "$MODPATH/bin/tailscaled"; then
    cp -f "$STATE/tailscaled" "$STATE/tailscaled.prev" 2>/dev/null \
      && ui_print "- попередній бінарник збережено для відкату"
  fi

  # Замінюємо лише бінарник. tailscaled.state лишається недоторканим, тож
  # вузол зберігає свою ідентичність, адресу й місце в політиці tailnet —
  # оновлення не має виглядати як нова машина.
  cp -f "$MODPATH/bin/tailscaled" "$STATE/tailscaled.new"
  chmod 0755 "$STATE/tailscaled.new"
  mv -f "$STATE/tailscaled.new" "$STATE/tailscaled"
  ln -sf tailscaled "$STATE/tailscale"
  ui_print "- бінарник встановлено: $(sha256sum "$STATE/tailscaled" 2>/dev/null | cut -c1-16)…"
  rm -rf "${MODPATH:?}/bin"
else
  ui_print "! у пакеті немає bin/tailscaled — лишаю встановлений"
fi

if [ -f "$STATE/tailscaled.state" ]; then
  ui_print "- стан вузла збережено (оновлення, не нова машина)"
else
  ui_print "- вузол ще не авторизовано: після перезавантаження виконай"
  ui_print "  $STATE/tailscale up --ssh --accept-dns=false"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in service.sh uninstall.sh action.sh update.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done

ui_print "- готово, застосується після перезавантаження"
