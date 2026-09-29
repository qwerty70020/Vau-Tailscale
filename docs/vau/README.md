# Vau-Tailscale — форк під Android root (оглавлення)

Форк Tailscale для телефонів з root: демон як модуль у `/data/adb`, живе до першого
розблокування й не залежить від застосунку. Вузли: `moto-root` (Motorola), `nord-root` (Nord).

| файл | про що |
|---|---|
| `UPSTREAM.md` | стан гілки, що робити далі, чого не чіпати |
| `AUDIT.md` | аудит модуля: DNS, health-loop, співіснування з VPN застосунку |
| `../superpowers/plans/2026-09-10-vau-tailscale.md` | план появи форку |
| `../../scripts/android.sh`, `sign.sh`, `installer.sh` | збірка, підпис, встановлення |
| `../../server/moto-watch.sh` | сторож досяжності телефонів, крутиться на home-server |

## Звʼязок з іншими репо

Керування телефонами з сервера — спільна справа трьох репо:

- **Vau-Server** (`~/repos/Vau-Server`, home-server) — сервер, cron, токен домашнього бота
  (@vau_hs_bot). Звідти запускається `server/moto-watch.sh` (`*/5 * * * *`), він читає
  `BOT_TOKEN`/`BOT_CHAT_ID` з `Vau-Server/.env`. Серверний бік описано в `AGENT.md` §3.3–3.4.
- **Vau-AntLegion-Port** — мурашиний бот на Nord; ходить на телефон через `nord` (Termux)
  і запасною дорогою `nord-root` (цей модуль). Див. його `docs/README.md`.

Cron викликає скрипт прямо з клону: переключення гілки без `server/` вимкне сторожа.
