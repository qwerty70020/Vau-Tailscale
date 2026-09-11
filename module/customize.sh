#!/system/bin/sh
#
# KernelSU / Magisk installer hook. Runs with $MODPATH pointing at the staged
# module directory while the zip is being installed.
#
# The binary is moved out of the module directory into /data/adb/tailscale on
# purpose: that is where the daemon's state already lives, it is DE storage
# (readable before the owner's first unlock, which is the whole point of this
# module), and keeping one copy avoids carrying 36 MB twice on the device.

SKIPUNZIP=0
STATE=/data/adb/tailscale

ui_print "- Vau Tailscale"

mkdir -p "$STATE"
chmod 700 "$STATE"

if [ -f "$MODPATH/bin/tailscaled" ]; then
  # Keep the outgoing binary as the fallback BEFORE overwriting it. An update
  # that cannot start would otherwise leave the phone unreachable, and the way
  # back in is exactly the thing that just broke; service.sh restores this file
  # after repeated fast failures.
  if [ -x "$STATE/tailscaled" ] && ! cmp -s "$STATE/tailscaled" "$MODPATH/bin/tailscaled"; then
    cp -f "$STATE/tailscaled" "$STATE/tailscaled.prev" 2>/dev/null \
      && ui_print "- попередній бінарник збережено для відкату"
  fi

  # Replace the binary only. tailscaled.state stays untouched, so the node
  # keeps its identity, its address and its place in the tailnet policy —
  # an update must not look like a new machine.
  cp -f "$MODPATH/bin/tailscaled" "$STATE/tailscaled.new"
  chmod 0755 "$STATE/tailscaled.new"
  mv -f "$STATE/tailscaled.new" "$STATE/tailscaled"
  ln -sf tailscaled "$STATE/tailscale"
  ui_print "- бінарник встановлено: $(sha256sum "$STATE/tailscaled" 2>/dev/null | cut -c1-16)…"
  rm -rf "$MODPATH/bin"
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
