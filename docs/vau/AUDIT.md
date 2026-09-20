# Vau-Tailscale — аудит Android-патча

Дата: 2026-09-10 · Ревизия: `d6a7411` (ветка `1.98.8-android-dev`) · Устройство проверки: Motorola Edge 50 Pro, Android 16, KernelSU

## Объём и метод

- **База:** Tailscale v1.98.8 (`05a91829`) плюс **один** squash-коммит `d6a7411 feat: android modifications` от anasfanani: 53 файла, +1555/−48 строк.
- **«Апстрим»** в этом отчёте — всегда официальный `tailscale/tailscale`, а не форк.
- **Целостность базы ✅:** родитель патча `05a91829316e…` и его дерево `a3b479447d0a…` совпадают с официальным тегом `tailscale/tailscale@v1.98.8`, проверено через GitHub API. Значит, чужой код в форке — только коммит `d6a7411`.
- **Что проверялось:** весь патч построчно. Код апстрима — только там, где патч меняет его поведение: DNS, маршрутизация, SSH, автообновление.
- **Как проверялось:**
  1. Чтение diff целиком.
  2. Трассировка вызовов по коду апстрима.
  3. Сборка `linux/arm64` и `android/arm64`, `go vet`.
  4. Пробы прямо на телефоне: поиск пользователей, `compileConfig` для DNS, поведение бинарника при запуске.
  5. Сверка с живым состоянием телефона: `ip rule`, iptables, маршруты, SELinux, `ip_forward`.
- **Статусы находок:**
  - ✅ подтверждено запуском или сборкой;
  - 🔍 подтверждено трассировкой кода, вживую не запускалось (запуск требует root и меняет сеть телефона);
  - ⚠️ проявляется только при определённом окружении.

## Вердикт

**В TUN-режиме как замену приложению ставить нельзя.** Три блокера:

1. **Автообновление качает root-бинарник из чужого репозитория без проверки подписи** (C1).
2. **DNS ломается на всём телефоне** в любой конфигурации, кроме случая, когда глобальные DNS-серверы — известные DoH-провайдеры: в конфигурации tailnet по умолчанию (C2) и с твоим AdGuard в tailnet (C3).
3. **Tailscale SSH выдаёт root вместо запрошенного пользователя** и путает группы и окружение (H1–H4).

Относительно безопасный режим «как есть»: `--tun=userspace-networking --accept-dns=false`, автообновление выключено, Tailscale SSH не используется. Но тогда теряется ровно то, ради чего всё затевалось.

---

## Стан на 2026-09-19 (гілка `android-v1.102.4`)

Повторний аудит усього форку + причина щоденних червоних збірок. Закрито в коді (усе нижче — у робочому дереві цієї дати):

| Пункт | Що зроблено |
|---|---|
| C1 | `clientupdate/clientupdate_android.go` і stub видалено фізично, `case "android"` з `clientupdate.go` прибрано; гейт у `vau-release` тепер прив'язаний до рядка `local remove=` і перевіряє відсутність файлів. |
| C2 | `GetBaseConfig` на Android читає системні резолвери з `dumpsys connectivity` (`DnsAddresses`), Tailscale-адреси й loopback відкидаються. |
| C3 / M1 / M3 | DNAT-правила: `-m mark ! --mark 0x10000000/0x1e000000` (bypass-mark форвардера), `-o tailscale0` замість `tun+`, `AppendUnique`, і UDP, і **TCP**/53 (netd після таймауту UDP повторює по TCP — той повтор витікав повз тунель). IPv6 — ті самі правила в `ip6tables` (на ядрі nord `v6nat=false`, тому лише v4, non-fatal). Перевірено на nord у kernel-режимі 2026-09-20. |
| H2 | `setGroups`: android-виняток прибрано, помилка `Setgroups` знову фатальна. |
| H3 | Мертве `cmd.Dir = $HOME` для android видалено (інкубатор сам робить `Chdir(homeDir)`). |
| H4 | `shouldAttemptLoginShell` на android завжди `false` (`login` там немає); тест `incubator_android_test.go`. |
| H5 | `getprop` → `/system/bin/getprop`; PATH демона в `service.sh` без неіснуючого `/system/xbin`. |
| H6 / M4 | Безумовний `-i tailscale0 ! -o tailscale0 -j MASQUERADE` прибрано — саме він ламав `TestSiteToSite` у `natlab-test` (правило потрапляло в linux/amd64). Роздача точки доступу тепер за `TS_ANDROID_HOTSPOT_SHARE` (`HOTSPOT_SHARE=1` у `/data/adb/vau-tailscale.conf`). MSS: `--clamp-mss-to-pmtu` лише на `tailscale0`, а не 1200 на весь трафік. |
| — | `NewOSConfigurator("")` у userspace-режимі повертає no-op менеджер: раніше кожен netmap викликав `iptables -D` ×4. |
| — | `TS_ASSUME_NETWORK_UP_FOR_TEST` (envknob на кожен `AnyInterfaceUp`) прибрано. |
| — | П'ять копій логіки `/data/adb/tailscale → $PREFIX → TempDir` замінено на `paths.AndroidBaseDir()`; `LogsDir` тепер створює теку. |
| — | `update.sh`: код виходу інсталятора більше не губиться в `| tail -5`. WebUI: `up` після першого входу — без прапорців (інакше `--reset`); перемикачі показують справжні prefs із `tailscaled.state`. |

### Kernel-режим — 2026-09-20, перевірено на nord (OnePlus AC2003, Android 12, Magisk)

- **M2** — перехоплення DNS у netstack (`handleDNSQueryCopy` + блок у `handleLocalPackets`) **видалено**. Воно не лише ловило TCP/53 і плодило горутини — воно ковтало власний форвард резолвера до tailnet-DNS (`100.102.182.105:53` через `tailscale0`), тому будь-який запит поза MagicDNS падав у `context deadline exceeded`. У kernel-режимі системний DNS уже загортає iptables DNAT (C3), у userspace-режимі netstack і так бачить лише tailnet-трафік.
- **M5 / M6** — `getAndroidIPRules()` справді зник у `c77f750ba`, і апстримні `baseIPRules` на телефоні непридатні (`main` порожня, `ip rule` netd 10000–32000). Новий набір у `wgengine/router/osrouter/router_androidrules_linux.go`: `12500: not fwmark <bypass> lookup 52` (нема окремого правила для 100.64/10 — петлі CGNAT M5 більше немає) і `13001: fwmark <subnet> lookup <uplink>`, де таблицю uplink (`wlan0`=1023, `r_rmnet_data0`=1019…) дає `netmon.AndroidDefaultNetworkV4/V6()` — читання правила netd `fwmark 0x0/0xffff iif lo lookup <table>` (`net/netmon/interfaces_androidroute_linux.go`; увага: ядро не надсилає `FRA_FWMARK` при mark 0). На кожну зміну мережі (`RegisterChangeCallback`) правила перезаписуються: старе 13001 видаляється **до** перерахунку таблиці — витік M6 закрито. Ті самі детектор дає `netmon` `defaultRoute=wlan0` (раніше порожньо).
- **netmon** (нове, апстримна вада) — `RTM_DELRULE` розбирався як `RouteMessage`; правила netd з `uidrange` (`FRA_UID_RANGE`=20, у route-просторі це `RTA_PREF` uint8) ламали парсер ×10 на кожну зміну мережі, а `RuleDeleted` публікувалася з нульовим пріоритетом. Тепер `RuleMessage`.
- **M7** — на Android `setBypassMark` ставить мітку завжди: без неї пакети демона впираються в 12500 і йдуть у власний тунель.

Перевірено: реальний TUN, `tailscale ping` до пірів, зовнішній HTTP, три DNS-сценарії (MagicDNS, публічне ім'я через tailnet-резолвер, сирий UDP до 1.1.1.1:53 — усі йдуть через 100.100.100.100), доступ по Tailscale SSH після перезапуску. **Не перевірено:** телефон як exit-node з реальним клієнтом (маршрут не схвалено в консолі) і перемикання Wi-Fi↔LTE вживу.

Пастка експлуатації: `service.sh stop` по Tailscale SSH вбиває власну сесію до старту нового демона — перезапускати тільки через ADB (`setsid sh /data/adb/modules/vau_tailscale/service.sh </dev/null >/dev/null 2>&1 &`).

---

## CRITICAL

### C1. Автообновление: root-бинарник из стороннего репозитория, без подписи ✅/🔍
- **Где:**
  - `clientupdate/clientupdate_android.go:21`: `androidGitHubRepoURL = ".../anasfanani/tailscale-magisk-build/releases"`;
  - `clientupdate/clientupdate.go:188`: для Android `canAutoUpdate=true`.
- **Суть:**
  - `tailscale update` скачивает `.tgz` через GitHub API и заменяет `tailscaled` рядом с исполняемым файлом.
  - Не проверяются подпись, контрольная сумма и источник.
  - Бинарник получает режим `0777`: `os.FileMode(0755)|os.ModePerm` (`:350`).
  - Нет таймаута HTTP, `fsync` и отката. Если питание пропадёт во время записи, бинарник останется битым и демон не запустится.
- **Источник:** `tailscale-magisk-build` — старое имя репо, GitHub перенаправляет его на `anasfanani/tailscale-android-cli` (✅ проверено через `gh`). Твой форк будет ставить **бинарники anasfanani**, а не свои.
- **Как срабатывает без твоего участия:** `ipn/ipnlocal/local.go:3765` (`onTailnetDefaultAutoUpdate`). Если в tailnet включено «Auto-update clients», узел сам включает `AutoUpdate.Apply`, потому что `CanAutoUpdate()==true`. Ещё обновление можно запустить кнопкой в админке (c2n `/update`).
- **Исправление:** убрать самообновление совсем и обновлять через `updateJson` модуля KSU из своего CI. Если оставлять — только из `qwerty70020/Vau-Tailscale`, с проверкой sha256 и подписи (minisign или cosign), атомарной заменой через `fsync`, режимом `0755` и копией предыдущей версии. По умолчанию `canAutoUpdate=false`.

### C2. MagicDNS без глобальных серверов → `SERVFAIL` на все публичные домены ✅
- **Где:** `net/dns/manager_android.go:61`: `GetBaseConfig()` возвращает пустой `OSConfig{}` без ошибки.
- **Цепочка:**
  1. `compileConfig` (`net/dns/manager.go:390-433`) видит, что split DNS не поддерживается, берёт base config.
  2. Маршрут `Routes["."]` получается с пустым списком серверов.
  3. `forwarder.resolvers()` возвращает пустой список, форвардер пишет `"no upstream resolvers set, returning SERVFAIL"` (`forwarder.go:1194-1201`).
  4. При этом `SetDNS` видит непустой `Nameservers=[100.100.100.100, fd7a:…::53]` и перенаправляет **весь** DNS телефона через iptables.
- **Проба на телефоне:** `magicdns-only → OS nameservers=[100.100.100.100 fd7a:115c:a1e0::53] (hijack=true), route "." upstreams=[]`.
- **Для тебя:** это конфигурация tailnet по умолчанию. У тебя включён Override с сервером `100.102.182.105`, поэтому тебя это не касается, но касается C3.
- **Исправление:** реализовать `GetBaseConfig` через DNS-серверы текущей сети Android (netd / `dumpsys connectivity`, либо `ndc resolver`). Если серверы получить не удалось, не включать перехват.

### C3. Петля DNS для любого upstream по UDP/53, в том числе твоего AdGuard `100.102.182.105` 🔍
Три независимых механизма сходятся в одну петлю:
- **Сокет форвардера без метки.** Форвардер шлёт запросы через обычный сокет без `SO_MARK`: `stdNetPacketListener = MakePacketListenerWithNetIP(new(net.ListenConfig))` (`forwarder.go:498`).
- **Правило `nat OUTPUT` не исключает интерфейс Tailscale.** Правило `! -o tun+ ! -d 100.100.100.100 -p udp --dport 53 -j DNAT` (`manager_android.go:94`) исключает `tun+`, а интерфейс Tailscale называется `tailscale0`. Собственный запрос демона к AdGuard (или к любому публичному серверу через `rmnet`) перенаправляется обратно на `100.100.100.100`.
- **Перехват в netstack.** `handleLocalPackets` (`wgengine/netstack/netstack.go:~902`) перехватывает любой пакет на порт 53 не к `100.100.100.100`, который идёт в TUN (а через `PreFilterPacketOutboundToWireGuardNetstackIntercept` проходит весь трафик ОС в TUN). Запрос форвардера к `100.102.182.105:53` снова попадает в резолвер.
- **Защиты от петель в резолвере нет.**
- **Итог:** работают только upstream, которые форвардер переводит на DoH (1.1.1.1, 8.8.8.8, 9.9.9.9 и т.п.), потому что это порт 443. С твоим AdGuard DNS не работает совсем.
- **Исправление:**
  - в правила DNAT добавить `-m mark ! --mark 0x10000000/0x1e000000` и `-o tailscale0`, либо исключить uid 0;
  - перехват в netstack убрать или ограничить: только UDP и только если адресат не в tailnet;
  - форвардеру давать сокет с меткой обхода.

## HIGH

### H1. SSH: неизвестный пользователь → root ✅
- **Где:** `util/osuser/user_android.go:37-42`.
- **Суть:** если `id -u <имя>` не находит пользователя, выполняется запасной вызов `getAndroidCommandOutput(ctx, "id", "-u", "0")`. Хелпер считает **последний аргумент значением по умолчанию**, поэтому на деле запускается `id -u`, то есть «кто я». У демона это 0. Кроме того, gid по умолчанию `"0"`, а имя пользователя становится `root`.
- **Проба:** `lookup("no-such-user-xyz") → uid=<uid процесса> gid=0 username=root`, то же для `lookup("vau")`.
- **Последствие:** правило SSH в tailnet `users: ["autogroup:nonroot"]` или список конкретных пользователей даёт **root-оболочку** при входе под любым выдуманным именем.
- **Исправление:** неизвестный пользователь → ошибка, вход отклонён. Пользователей брать только из AID Android или из явного списка.

### H2. SSH: группы сессии = группы демона ✅
- **Где:** `util/osuser/group_ids.go:23-32`: выполняется `id -Gz` **без имени пользователя**. При ошибке возвращается `["0"]`.
- **Проба:** `GetGroupIds("root") == GetGroupIds("shell") == GetGroupIds("u0_a477")` — всегда группы вызывающего процесса.
- **Последствие:**
  - вход под `u0_a477` от демона-root даёт дополнительную группу `0`;
  - настоящих групп пользователя нет. Без `3003 (inet)` в сессии **нет сети** (то же, что в README Phantom Tamer), без `1077/1079` нет доступа к `/sdcard`.
  - `setGroups` на Android (`incubator.go:1213`) молча игнорирует ошибку `Setgroups` у root.
- **Исправление:** `id -G <user>`. Для app-uid собирать группы так же, как Phantom Tamer (3003, 9997, 1077, 1079, 20xxx, 50xxx). Ошибку `Setgroups` считать фатальной.

### H3. SSH: окружение демона затирает окружение пользователя 🔍
- **Где:** `ssh/tailssh/incubator.go:850-858`: сразу после `envForUser` к окружению дописывается **весь** `os.Environ()` демона, кроме `TS_*`.
- **Суть:** в `os/exec` при повторяющемся ключе побеждает последнее значение, поэтому `HOME`, `PATH`, `USER` и `SHELL` становятся значениями демона. Туда же уходят все его переменные, например `LD_PRELOAD` из Termux и прокси. `cmd.Dir` берётся из `HOME` демона.
- **Проба:** у всех пользователей `home=<HOME вызывающего процесса>` (`user_android.go:46` вызывает `os.UserHomeDir()` для любого пользователя).
- **Исправление:** явный список безопасных переменных и `HOME`/`PATH` для конкретного пользователя: для Termux-uid — префикс Termux, иначе `/system/bin`.

### H4. SSH: `login` от root без имени пользователя и без проверки TTY ⚠️🔍
- **Где:**
  - `incubator.go:202`: флаг `--is-selinux-enforcing` передаётся только при `runtime.GOOS == "linux"`. На Android он всегда `false`, хотя на телефоне SELinux в режиме Enforcing (✅ `getenforce`).
  - `shouldAttemptLoginShell` поэтому возвращает `true` для root.
  - `tryExecLogin` (`:524-533`): Android не входит в список ОС с проверкой TTY.
  - `loginArgs` для Android (`:1181`) — `[loginPath]`, **без `-f <user>`**.
- **Последствие:** если в `PATH` демона есть `login` (например, `$PREFIX/bin/login` Termux), оболочка запускается от root при входе под любым пользователем. Сессии без TTY (mosh, VS Code, `ssh -T`) ломаются.
- **Исправление:** на Android не использовать `login`. Сразу `handleInProcess` со сбросом привилегий и явным `setgroups`.

### H5. Root запускает бинарники через поиск по `PATH` ⚠️🔍
- **Суть:** демон вызывает через `PATH`, а не по абсолютному пути:
  - `exec.Command("id", …)` и `exec.Command("getprop", …)` (`user_android.go`, `group_ids.go`, `hostinfo_android.go`);
  - `exec.LookPath("bash"/"sh")`;
  - `exec.LookPath("login")`.
- **Последствие:** если демон запущен с `PATH` Termux (например, `su` из Termux), любой код, работающий под uid Termux (u0_a477) — pip- или npm-пакет, скрипт, — подменяет `$PREFIX/bin/id`, `bash` или `login` и **получает root**.
- **Исправление:** абсолютные пути `/system/bin/id`, `/system/bin/getprop`, `/system/bin/sh`. Демон должен всегда стартовать с чистым `PATH` (`service.sh` KSU).

### H6. Раздача tailnet через точку доступа от твоего имени, безусловно ✅/🔍
- **Где:** `util/linuxfw/iptables_runner.go:265-275`:
  - безусловные `-o tailscale0 -j MASQUERADE` («Allow hotspot clients…»);
  - `-i tailscale0 ! -o tailscale0 -j MASQUERADE`.
- **Суть:**
  - На телефоне цепочка `FORWARD` Android завершается `tetherctrl_FORWARD -j DROP` (✅). Цепочка `ts-forward` вставляется **перед** ней и содержит `-o tailscale0 -j ACCEPT`.
  - Когда включена точка доступа (`ip_forward=1`), клиенты точки (и соседи, которые направят маршрут через телефон) попадают в tailnet **с идентичностью телефона**: SSH на home-server, Nextcloud, админка AdGuard.
  - `nat PREROUTING` перенаправляет **на всех интерфейсах** их DNS на резолвер tailnet: видны имена MagicDNS.
  - `--snat-subnet-routes=false` не действует: MASQUERADE безусловный, а апстрим добавляет SNAT только при включённой опции (`addSNATRule`).
- **Исправление:** раздачу через точку доступа сделать отдельной опцией, по умолчанию выключенной. Правила ограничить `-i <интерфейс точки доступа>`. Уважать `--snat-subnet-routes`.

### H7. Бинарник удаляет сам себя, если назван `tailscale` ✅
- **Где:** `cmd/tailscaled/tailscaled.go:72-107` (`createTailscaleSymlink`, вызывается на **каждом** запуске, включая CLI).
- **Проба:** копия под именем `tailscale` → `./tailscale version` → файла больше нет, на его месте `tailscale -> tailscale`, следующий запуск падает с «Too many symbolic links».
- **Кроме того:** функция молча удаляет **любой** обычный файл `tailscale` рядом с бинарником.
- **Исправление:** создавать симлинк только при установке (из скрипта модуля). Никогда не удалять обычный файл и не трогать путь, совпадающий с собственным.

## MEDIUM

| # | Проблема | Где | Статус |
|---|---|---|---|
| M1 | Правила перехвата DNS добавляются через `Append`, а не `AppendUnique`, и при старте не чистятся. После падения и перезапуска правила **дублируются**, а при остановке удаляется одна копия. Остаётся DNAT на `100.100.100.100`, и **DNS на телефоне мёртв**, пока жив хоть один дубль. | `manager_android.go:101`, `:66-73` | 🔍 |
| M2 | Перехват в netstack ловит и **TCP**/53. SYN без полезной нагрузки просто отбрасывается, так что TCP-DNS к хостам tailnet (большие ответы, DNSSEC, AXFR) не работает. На TCP-запрос с данными приходит ответ **по UDP**. На каждый пакет запускается отдельная горутина без лимита. | `netstack.go:~839-917` | 🔍 |
| M3 | DNS по IPv6 обходит перехват: в ядре нет `ip6tables nat` (✅ на телефоне), ошибка IPv6 молча «non-fatal». Перехватывается только UDP. Private DNS в режиме `opportunistic` (✅) может уйти на DoT :853 мимо AdGuard. | `manager_android.go:78-80` | ✅ |
| M4 | MSS-clamp `--set-mss 1200` висит на **всех** входящих SYN и SYN-ACK в `mangle PREROUTING` без фильтра по интерфейсу. Весь TCP телефона урезается до MSS 1200. `--set-mss` может и **повысить** MSS меньше 1200. Надо ставить только на пересылаемый трафик `tailscale0` с `--clamp-mss-to-pmtu`. | `iptables_runner.go:277` | 🔍 |
| M5 | Правило `100.64.0.0/10 → table 52` (приоритет 12500) не исключает собственный помеченный трафик демона. У операторов с CGNAT (адреса 100.64/10 у шлюза, DNS или пиров) трафик демона уходит в `tailscale0`: петля. Плюс апстримный `ts-input` DROP для 100.64/10 не с `tailscale0`. | `router_linux.go:1420-1431` | 🔍 |
| M6 | Правило exit node фиксирует таблицу текущей сети **один раз** при добавлении. После переключения Wi-Fi↔LTE правило указывает на устаревшую таблицу. `delIPRules` пересчитывает таблицу и не находит старое правило, так что оно **остаётся навсегда** (утечка). | `router_linux.go:1407-1466`, `:1560-1595` | 🔍 |
| M7 | `setBypassMark` молча отключает метку обхода, если netmon не нашёл default route. Бывает у операторов с default route без шлюза. Тогда трафик демона уходит в exit node (петля) или в чужой VPN. **У тебя шлюз есть** (✅ `via 10.170.160.165`), так что не проявляется. На каждый сокет выполняется полный дамп маршрутов. | `net/netns/netns_linux.go:114` | ✅/⚠️ |
| M8 | **Сборка под Linux сломана:** тег `ios \|\| !android \|\| js` включает заглушку на всех не-Android платформах, отсюда `method Handler.serveCert already declared`. | `ipn/localapi/disabled_stubs.go:4` | ✅ |
| M9 | Тесты `net/dns` под Android не компилируются (`directFS`, `HookWatchFile` не определены). CI только собирает, тесты не запускаются. Сам автор в релизе пишет «CI Build untested». | `net/dns/*_test.go`, `build_android.yml` | ✅ |
| M10 | Цепочка поставок CI: сторонние actions закреплены тегами, а не SHA, при этом `contents: write`. Релиз сжат UPX: весь бинарник распаковывается в анонимную память. RSS выше, а на этом телефоне и так регулярные убийства `LOW_MEMORY`. Возможны ложные срабатывания антивирусов. | `.github/workflows/build_android.yml` | 🔍 |
| M11 | `go.mod replace github.com/wlynxg/anet => github.com/BieHDC/anet` (pseudo-version из чужого форка) используется в netmon root-демона. | `go.mod:6` | ✅ |

## LOW
- **`--no-logs-no-support` по умолчанию `true`.** Для приватности это плюс, но поддержки Tailscale нет (`tailscaled.go`).
- **Taildrop пишет в `/sdcard/Download/Taildrop`.** До разблокировки каталог недоступен, повторной попытки нет. Полученные файлы видны всем приложениям с доступом к хранилищу (`feature/taildrop/paths.go`).
- **Android-ветка `logpolicy.LogsDir` не создаёт каталог.** В апстриме каталог создаётся (`MkdirAll`) до возврата.
- **Поиск ассета — regexp с неэкранированной версией.** Точки в версии совпадают с любым символом; нестабильный канал берёт `releases[0]` по дате создания.

## Проверено и отброшено
- **Правила IPv4/IPv6 в `justAddIPRules` с «чужим» семейством.** `netlink` берёт семейство из `Dst`, дубликат получает EEXIST и игнорируется.
- **Запасной путь `su` в SSH.** `findSU` работает только для `GOOS=linux`, на Android не срабатывает.
- **Отключённый fake-listener peerapi.** Если слушать не удалось, есть запасной вариант на netstack (`peerapi.go:120-123`).
- **Определение default route на этом телефоне.** Работает через netlink, у маршрута `rmnet_data2` есть шлюз.

## Что улучшить (по приоритету)

1. **Собственный канал обновлений:** модуль KSU с `updateJson` на релизы `qwerty70020/Vau-Tailscale`. Подписанные артефакты (minisign), sha256, без UPX, actions закреплены по SHA. Самообновление `tailscale update` выключено.
2. **Безопасный режим по умолчанию:** `userspace-networking`, `--accept-dns=false`, TUN как явная опция. Минимальная ценность сразу, без риска для сети телефона.
3. **Модуль KSU с watchdog** в стиле Phantom Tamer:
   - ожидание сети;
   - при старте и остановке очистка «своих» iptables-цепочек и `ip rule` (идемпотентно, `AppendUnique`);
   - проверка здоровья по результату: процесс жив **и** `100.100.100.100` отвечает. Иначе снять DNAT и перезапустить;
   - конфиг в `/data/adb/tailscale/vau.conf`, который переживает обновления;
   - WebUI: статус, лог, exit node, кнопка «reapply».
4. **DNS по-андроидному:**
   - `GetBaseConfig` из netd;
   - DNAT с исключением собственного трафика по mark или uid;
   - только UDP;
   - REJECT для DNS по IPv6, если в ядре нет ip6 nat;
   - опция «выключить Private DNS»;
   - исключения по uid для приложений (AnyBalance, Messages, Android Auto…) — аналог «Excluded apps» приложения.
5. **SSH для Android:**
   - строгое сопоставление пользователей: только существующие AID, неизвестный — отказ;
   - корректные группы (как в keeper Phantom Tamer);
   - `HOME` и `PATH` для каждого пользователя;
   - для Termux-uid после разблокировки — окружение Termux, до разблокировки `/system/bin/sh`;
   - абсолютные пути;
   - без `login`.
6. **Удалённая разблокировка через root-оболочку Tailscale SSH:** `input keyevent WAKEUP` + `input text` (см. статью kxxt в `tsconst/linuxfw.go`). PIN нигде не хранить, вводить в сессии.
7. **Точка доступа:** раздача tailnet — опция, по умолчанию выключена. MSS-clamp только для пересылаемого трафика `tailscale0`.
8. **Смена сети:** пересчитывать правило exit node по событиям netmon и удалять правило по сохранённой таблице, а не пересчитанной.
9. **Мониторинг:** Uptime Kuma на home-server проверяет оба узла телефона (`:8022` на узле приложения и SSH на root-узле), алерт в Telegram-бот VauServer.
10. **Гигиена репозитория:**
    - разбить squash-патч на тематические коммиты (DNS / routing / SSH / paths / updater) для ревью и переноса на новые версии Tailscale;
    - чинить сборку и тесты под Linux и Android в CI;
    - следить за security-фиксами апстрима (например, `a98b177b`, фильтрация `LD_*` в `acceptEnv`).

## Как воспроизвести

```sh
cd ~/Vau-Tailscale
export GOTOOLCHAIN=local GOEXPERIMENT=nojsonv2 CGO_ENABLED=0   # Go 1.27: без nojsonv2 не собирается go-json-experiment
TAGS=$(GOOS= GOARCH= go run ./cmd/featuretags --remove "aws,bird,tap,kube,completion,completion_scripts,wakeonlan,capture,systray,syspolicy,appconnectors,identityfederation,usermetrics,logtail,netlog,linuxdnsfight,syspolicy,tpm" --add cli)
GOOS=android GOARCH=arm64 go build -tags="$TAGS" -trimpath -o /tmp/tailscaled ./cmd/tailscaled   # ~1.5 мин на телефоне, 36.7 МБ
GOOS=linux   GOARCH=arm64 go build ./ipn/localapi/                                             # M8: serveCert already declared
```
