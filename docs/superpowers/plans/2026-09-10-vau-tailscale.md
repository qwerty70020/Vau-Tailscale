# Vau-Tailscale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** превратить форк `qwerty70020/Vau-Tailscale` в root-демон `tailscaled`, запускаемый KSU-модулем, который даёт SSH-доступ к Motorola Edge 50 Pro **до первой разблокировки** — безопасно (без чужих бинарников, без поломки DNS телефона) и без конфликта с приложением Tailscale.

**Architecture:** три независимо поставляемых этапа. Этап A — своя сборка и подпись в CI форка. Этап B — KSU-модуль `vau-tailscale`, который запускает демон в режиме `userspace-networking` (не трогает сеть телефона) и сторожит его как Phantom Tamer сторожит sshd. Этап C — исправления из аудита, которые открывают TUN-режим (весь телефон в tailnet) без блокеров DNS/SSH/обновлений. Этапы A и B дают рабочий результат сразу; C — только когда TUN действительно понадобится.

**Tech Stack:** Go 1.27 (`GOTOOLCHAIN=local GOEXPERIMENT=nojsonv2 CGO_ENABLED=0`), Android NDK r27c (только для CGO-сборки, по умолчанию nocgo), KernelSU (ksud 3.3.0), POSIX sh (busybox из KSU), GitHub Actions, minisign для подписи.

**Spec:** `docs/vau/AUDIT.md` (аудит от 2026-09-10, ревизия `d6a7411`). План реализует раздел «Что улучшить» этого отчёта; каждая находка C*/H*/M* ниже ссылается на него.

## Global Constraints

- **Целевое устройство:** Motorola Edge 50 Pro, `aarch64`, Android 16, KernelSU (`u:r:ksu:s0`), FBE (`ro.crypto.type=file`). Вторичная цель — OnePlus Nord (для профиля «lite», как в Phantom Tamer).
- **Состояние демона живёт в `/data/adb/tailscale`** — это DE-хранилище, доступно **до** разблокировки. Форк уже поддерживает этот путь (`paths/paths_unix.go`, `logpolicy`, `tsweb`). Каталог создать с `chmod 700`.
- **Никаких чужих бинарников.** Единственный источник — CI форка `qwerty70020/Vau-Tailscale`. Самообновление через сеть удаляется (C1).
- **KSU-скрипты только LF, не пересобирать zip на Windows** (как в Phantom Tamer; CI это проверяет).
- **Все GitHub Actions закреплены по SHA**, не по тегам. Известные SHA на 2026-09-10:
  - `actions/checkout` v7.0.1 → `3d3c42e5aac5ba805825da76410c181273ba90b1`
  - `actions/setup-go` v7.0.0 → `b7ad1dad31e06c5925ef5d2fc7ad053ef454303e`
  - `softprops/action-gh-release` v3.0.3 → `efb35369e0ad2afab669f228072c1b0d510eae64`
- **Сборочные теги** (nocgo, android/arm64) получаются из `./cmd/featuretags` с набором `--remove`, см. Task A1. Для безопасного режима из набора дополнительно удаляется `clientupdate`.
- **Не ломать существующий рабочий путь.** Приложение Tailscale + Termux sshd (`ssh phone` с home-server) должны продолжать работать всё время, пока идёт этап B. Демон в userspace-режиме отдельный узел tailnet, приложение не трогает.
- **Verify-before-claim.** Каждая задача заканчивается конкретной проверкой: сборка, `go vet`, on-device проба или строка в логе. Не отмечать задачу выполненной без вывода проверки.
- **Ветка разработки:** `1.98.8-android-dev` (текущая база = официальный `tailscale/tailscale@v1.98.8`, целостность подтверждена в аудите). Апстрим ушёл до v1.102.3 — перенос на новую версию это отдельная задача C9, не смешивать с фиксами.

---

## File Structure

**Этап A (CI и подпись):**
- `.github/workflows/build_android.yml` — переписать: nocgo по умолчанию, SHA-pinned actions, без UPX, публикация в релиз с подписью.
- `scripts/android.sh` — существующий build-скрипт; добавить проверку, что бинарник запускается (`--version`).
- `scripts/sign.sh` — создать: minisign-подпись артефактов.
- `docs/BUILD.md` — создать: как собрать локально и в CI, как проверить подпись.

**Этап B (KSU-модуль):** новый подкаталог `module/` в форке (или отдельный репозиторий `Vau-Tailscale-KSU` — решается в Task B0).
- `module/module.prop`
- `module/service.sh` — запуск демона после разблокировки-независимо (демон не требует разблокировки), сторож с проверкой здоровья.
- `module/post-fs-data.sh` или `boot-completed.sh` — по необходимости.
- `module/uninstall.sh` — снять правила, остановить демон.
- `module/vau-tailscale.conf.example` — образец `/data/adb/vau-tailscale.conf`.
- `module/webroot/index.html` — статус, лог, кнопки up/down (по образцу Phantom Tamer WebUI).
- `module/README.md`

**Этап C (фиксы аудита):** правки в дереве Go-форка, по файлам из аудита:
- `clientupdate/*` — C1
- `net/dns/manager_android.go`, `wgengine/netstack/netstack.go` — C2, C3, M1, M2, M3
- `util/osuser/user_android.go`, `util/osuser/group_ids.go`, `ssh/tailssh/incubator.go` — H1–H5
- `util/linuxfw/iptables_runner.go` — H6, M4
- `cmd/tailscaled/tailscaled.go` — H7
- `wgengine/router/osrouter/router_linux.go` — M5, M6
- `ipn/localapi/disabled_stubs.go` — M8

---

# ЭТАП A — Своя сборка и подпись в CI

Результат этапа: из твоего форка одной кнопкой (`workflow_dispatch`) выходит подписанный `tailscaled.arm64`, который ты можешь проверить по подписи. Закрывает C1 в части «источник».

### Task A1: Зафиксировать сборочную команду и убедиться, что nocgo-бинарник собирается

**Files:**
- Test/verify: локальная сборка на телефоне (или Linux-раннер)

**Interfaces:**
- Produces: строка тегов `TAGS` и команда сборки, которые используют все остальные задачи.

- [ ] **Step 1: Получить строку тегов**

```bash
cd ~/Vau-Tailscale
export GOTOOLCHAIN=local GOEXPERIMENT=nojsonv2 CGO_ENABLED=0
TAGS=$(GOOS= GOARCH= go run ./cmd/featuretags \
  --remove "aws,bird,tap,kube,completion,completion_scripts,wakeonlan,capture,systray,syspolicy,appconnectors,identityfederation,usermetrics,logtail,netlog,linuxdnsfight,tpm,clientupdate" \
  --add "cli")
echo "$TAGS"
```

Примечание: `clientupdate` удалён намеренно (Task A4 / C1) — команда `tailscale update` в бинарнике будет отсутствовать. Проверено: без него `tailscale update` → `unknown subcommand`.

- [ ] **Step 2: Собрать демон под android/arm64**

```bash
GOOS=android GOARCH=arm64 go build -tags="$TAGS" -trimpath \
  -o /tmp/tailscaled.arm64 ./cmd/tailscaled
```

Expected: сборка проходит, файл ~36 МБ. (Измерено 2026-09-10: 1m34s на телефоне.)

- [ ] **Step 3: Проверить, что бинарник запускается и знает свою версию**

```bash
cp /tmp/tailscaled.arm64 /tmp/ts/tailscaled && ln -sf tailscaled /tmp/ts/tailscale
/tmp/ts/tailscaled --version
/tmp/ts/tailscale up --help | grep -- --ssh
/tmp/ts/tailscale update 2>&1   # ожидаем: unknown subcommand
```

Expected: версия `1.98.8-dev…`; флаг `--ssh` присутствует; `update` отсутствует.

- [ ] **Step 4: Commit** (только если менялись файлы; здесь скорее всего нечего коммитить — это разведка)

### Task A2: Починить сборку под Linux (M8) — снять ложную заглушку serveCert

**Files:**
- Modify: `ipn/localapi/disabled_stubs.go:4`

**Interfaces:**
- Produces: корректный build constraint, чтобы `go build ./ipn/localapi/` проходил на linux/arm64 (нужно для CI-раннера ubuntu).

- [ ] **Step 1: Убедиться в баге**

```bash
cd ~/Vau-Tailscale
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOTOOLCHAIN=local GOEXPERIMENT=nojsonv2 \
  go build ./ipn/localapi/ 2>&1 | head -3
```

Expected: `method Handler.serveCert already declared`.

- [ ] **Step 2: Прочитать текущий constraint**

```bash
sed -n '1,15p' ipn/localapi/disabled_stubs.go
```

Сейчас: `//go:build ios || !android || js` — из-за `!android` заглушка компилируется на linux вместе с настоящим `cert.go`.

- [ ] **Step 3: Исправить constraint**

Заменить строку 4 на:

```go
//go:build ios || js
```

Обоснование: форк снял `!android` из `cert.go` (`//go:build !ios && !js && !ts_omit_acme`), чтобы на Android работал настоящий `serveCert`. Значит заглушка не должна включать ни android, ни любую платформу, где компилируется `cert.go`. Текущее `!android` захватывает linux/darwin/windows — отсюда двойное объявление. Пара `cert.go` = «везде кроме ios/js/ts_omit_acme», заглушка = «ios или js» — взаимоисключающие, кроме сборок с `ts_omit_acme`: если такая сборка понадобится, добавить третий файл-заглушку с `//go:build ts_omit_acme && !ios && !js`.

- [ ] **Step 4: Проверить обе платформы**

```bash
GOOS=linux   GOARCH=arm64 CGO_ENABLED=0 GOTOOLCHAIN=local GOEXPERIMENT=nojsonv2 go build ./ipn/localapi/ && echo LINUX_OK
GOOS=android GOARCH=arm64 CGO_ENABLED=0 GOTOOLCHAIN=local GOEXPERIMENT=nojsonv2 go build -tags="$TAGS" ./ipn/localapi/ && echo ANDROID_OK
```

Expected: обе строки OK.

- [ ] **Step 5: Commit**

```bash
git add ipn/localapi/disabled_stubs.go
git commit -m "fix(localapi): serveCert stub build tag breaks non-android build (M8)"
```

### Task A3: Скрипт подписи артефактов (minisign)

**Files:**
- Create: `scripts/sign.sh`
- Create: `docs/BUILD.md` (раздел про ключи)

**Interfaces:**
- Consumes: `MINISIGN_SECRET_KEY` (секрет CI), артефакт-файл.
- Produces: `<artifact>.minisig` рядом с артефактом; публичный ключ в `docs/BUILD.md`.

- [ ] **Step 1: Сгенерировать ключевую пару локально (одноразово, вручную — НЕ в CI)**

```bash
minisign -G -p /tmp/vau-tailscale.pub -s /tmp/vau-tailscale.key
```

Приватный ключ положить в секрет репозитория `MINISIGN_SECRET_KEY` (base64 содержимого `.key`) через `gh secret set`. Публичный — в репо.

- [ ] **Step 2: Написать `scripts/sign.sh`**

```sh
#!/usr/bin/env bash
# Sign release artifacts with minisign. Reads the secret key from
# $MINISIGN_SECRET_KEY (raw key file contents), signs each argument.
set -euo pipefail
: "${MINISIGN_SECRET_KEY:?MINISIGN_SECRET_KEY not set}"
keyfile=$(mktemp); trap 'rm -f "$keyfile"' EXIT
printf '%s' "$MINISIGN_SECRET_KEY" > "$keyfile"
for f in "$@"; do
    minisign -S -s "$keyfile" -m "$f" -x "$f.minisig"
    echo "signed: $f.minisig"
done
```

- [ ] **Step 3: Проверить цикл подпись→проверка локально**

```bash
chmod +x scripts/sign.sh
MINISIGN_SECRET_KEY="$(cat /tmp/vau-tailscale.key)" scripts/sign.sh /tmp/tailscaled.arm64
minisign -V -p /tmp/vau-tailscale.pub -m /tmp/tailscaled.arm64
```

Expected: `Signature and comment signature verified`.

- [ ] **Step 4: Записать публичный ключ и инструкцию проверки в `docs/BUILD.md`**

- [ ] **Step 5: Commit**

```bash
git add scripts/sign.sh docs/BUILD.md
git commit -m "feat(ci): sign release artifacts with minisign"
```

### Task A4: Переписать workflow — nocgo, SHA-pinned, без UPX, с подписью

**Files:**
- Modify: `.github/workflows/build_android.yml`

**Interfaces:**
- Consumes: `TAGS` (Task A1), `scripts/sign.sh` (A3), секрет `MINISIGN_SECRET_KEY`.
- Produces: релиз с `tailscaled.arm64`, `tailscaled.arm`, `*.minisig`, `SHA256SUMS`.

- [ ] **Step 1: Заменить все `uses:` на SHA-pinned формы** (см. Global Constraints).

- [ ] **Step 2: Убрать шаги UPX** (M10 — UPX распаковывается в анонимную память, лишний RSS на телефоне с частым LOW_MEMORY; и лишний триггер антивирусов). Собирать `./scripts/android.sh build --nocgo arm64` и `--nocgo arm`.

- [ ] **Step 3: Добавить шаг вычисления SHA256 и подписи**

```yaml
      - name: Checksums + sign
        env:
          MINISIGN_SECRET_KEY: ${{ secrets.MINISIGN_SECRET_KEY }}
        run: |
          cd dist
          sha256sum tailscale_*_arm64.tgz tailscale_*_arm.tgz > SHA256SUMS
          ../scripts/sign.sh tailscale_*_arm64.tgz tailscale_*_arm.tgz SHA256SUMS
```

- [ ] **Step 4: Ограничить `permissions:` до `contents: write`** (уже так) и убедиться, что workflow триггерится `workflow_dispatch` + push тега `v*-vau`.

- [ ] **Step 5: Запустить workflow вручную и проверить артефакты**

```bash
gh workflow run build_android.yml -R qwerty70020/Vau-Tailscale
# дождаться; затем:
gh release view <tag> -R qwerty70020/Vau-Tailscale --json assets --jq '.assets[].name'
```

Expected: в списке есть `.tgz`, `.minisig`, `SHA256SUMS`. Скачать, проверить `minisign -V` и `sha256sum -c`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/build_android.yml
git commit -m "feat(ci): nocgo build, SHA-pinned actions, no UPX, signed release (C1,M10)"
```

**⚠️ Предусловие:** GitHub Actions в форке должны быть включены (Settings → Actions → Allow). Проверить `gh api repos/qwerty70020/Vau-Tailscale/actions/permissions` — раньше показывало `enabled:true`. Если workflow не виден в `gh workflow list`, сделать пустой commit в ветку с workflow-файлом.

---

# ЭТАП B — KSU-модуль (userspace-режим, безопасно рядом с приложением)

Результат этапа: демон `tailscaled` работает от root из `/data/adb/tailscale`, поднимается **до разблокировки**, виден в tailnet как отдельный узел `moto-root` с Tailscale SSH, и **не трогает сеть телефона** (`--tun=userspace-networking`). Приложение Tailscale продолжает работать. Закрывает задачу «доступ до разблокировки» из аудита, не открывая блокеры TUN.

### Task B0: Решить, куда кладём модуль, и создать скелет

**Files:**
- Create: `module/` в форке (рекомендуется — один репозиторий, один CI) ИЛИ отдельный репо.

- [ ] **Step 1:** Решение: держать `module/` в форке `Vau-Tailscale`. Плюс — CI кладёт и бинарник, и zip модуля в один релиз; минус — крупный Go-репозиторий ради shell-модуля. Альтернатива (отдельный `Vau-Tailscale-KSU`) выбирается, только если захочется отдельного цикла релизов. По умолчанию — `module/` в форке.
- [ ] **Step 2:** Создать `module/` со скелетом `module.prop` (id=`vau_tailscale`, version, versionCode), пустыми `service.sh`, `uninstall.sh`.
- [ ] **Step 3: Commit** скелета.

### Task B1: Демон в userspace-режиме — ручной прогон до автоматизации

**Files:**
- Verify: on-device, вручную (ещё без модуля)

**Interfaces:**
- Produces: подтверждённую команду запуска демона, которую Task B2 зашьёт в `service.sh`.

- [ ] **Step 1: Разложить бинарник и состояние**

```bash
su -c 'mkdir -p /data/adb/tailscale && chmod 700 /data/adb/tailscale'
su -c 'cp /tmp/tailscaled.arm64 /data/adb/tailscale/tailscaled && chmod 755 /data/adb/tailscale/tailscaled'
su -c 'ln -sf tailscaled /data/adb/tailscale/tailscale'
```

- [ ] **Step 2: Запустить демон в userspace-режиме (не трогает сеть телефона)**

```bash
su -c '/data/adb/tailscale/tailscaled \
  --state=/data/adb/tailscale/tailscaled.state \
  --socket=/data/adb/tailscale/tailscaled.sock \
  --tun=userspace-networking \
  --no-logs-no-support >/data/adb/tailscale/daemon.log 2>&1 &'
```

Обоснование `userspace-networking`: демон не создаёт интерфейс `tailscale0`, не пишет `ip rule`/iptables, поэтому не конфликтует с `tun0` приложения и не может уронить сеть телефона (M5–M7, H6 не активируются). `defaultTunName()` на android уже возвращает `tailscale0,userspace-networking`, но передаём явно.

- [ ] **Step 3: Авторизовать узел с Tailscale SSH**

```bash
su -c '/data/adb/tailscale/tailscale --socket=/data/adb/tailscale/tailscaled.sock \
  up --ssh --hostname=moto-root --accept-dns=false'
# перейти по ссылке авторизации ОДИН раз
```

`--accept-dns=false` осознанно: в userspace-режиме перехват DNS всё равно не работает (C2/C3), а так демон точно не трогает резолвинг.

- [ ] **Step 4: Проверить с home-server доступ ДО фикса SSH (ожидаемо получить root)**

```bash
ssh -o BatchMode=yes root@moto-root 'id'   # через tailnet
```

Expected на этом шаге: соединение устанавливается. **Важно:** пока не сделан Task C5 (H1), Tailscale SSH выдаёт root вне зависимости от политики. До фикса — ограничить доступ ACL tailnet (Task B4) и не считать это безопасным для чужих пользователей.

- [ ] **Step 5: Проверить, что приложение не пострадало** — `ssh phone` с home-server по-прежнему работает, `tun0` приложения на месте (`ip -br addr show tun0`).

### ✅ Разбор 2026-09-10 (вечер): виноват не netstack, а пакетный фильтр tailnet

**Итог: узла `moto-root` нет в политике доступа tailnet.** В логе демона —
`netmap packet filter: 0 filters`. Ноль правил означает, что новому узлу не
разрешён обмен ни с кем; трафик отбрасывается на стороне получателей.

Что сходится с этим объяснением и что вводило в заблуждение:

- `tailscale ping` отвечает (`pong … 42ms`) — disco-пинги **не подчиняются**
  пакетному фильтру, поэтому «связь есть» было ложным сигналом;
- SOCKS до `1.1.1.1:443` работает — это выход в обычный интернет, фильтр
  tailnet к нему отношения не имеет;
- TCP одинаково не встаёт до **двух разных** устройств (home-server и nord) —
  это и был главный признак: дело не в конкретном получателе;
- рукопожатия WireGuard в логе успешны — шифрованный транспорт поднят, а
  отбрасывается уже расшифрованный пакет по правилам.

**Вывод для плана:** предпосылка этапа B в силе, userspace-режим не сломан.
Блокер один — правила доступа, и он же блокирует входящий Tailscale SSH.
Task B4 (ACL) становится **предусловием** проверки B1/B3, а не последним шагом.

Ниже сохранена первоначальная (ошибочная) гипотеза — как напоминание, что
«ping проходит» ничего не доказывает про TCP в tailnet.

### ⚠️ Первоначальная гипотеза (опровергнута): исходящий TCP через netstack не работает

Обнаружено на живом узле `moto-root` (сборка `v1.98.8-vau`, userspace-режим):

- `tailscale ping 100.102.182.105` → `pong … via 85.114.192.165 in 42ms`, пир `active; direct`,
  в логе успешные рукопожатия WireGuard;
- **но** любой исходящий TCP к пирам не встаёт: и через `--socks5-server`
  (`socks5: client connection failed: context deadline exceeded`), и через
  собственный диалер демона (`tailscale nc`, `localapi/v0/dial`):
  `dial failure: connect tcp 100.102.182.105:22: operation timed out`;
- падает не только до home-server, но и до другого устройства (`nord:8022`),
  поэтому firewall сервера ни при чём;
- SOCKS до публичного адреса (`1.1.1.1:443`) работает — сам SOCKS-сервер исправен.

**Что это значит для плана.** Предпосылка этапа B «userspace-режим достаточен»
подтверждена лишь наполовину: она опиралась на *входящий* доступ (Tailscale SSH
к узлу), а он с телефона непроверяем — нужен внешний инициатор. Исходящий TCP
сломан точно. Перед Task B3 нужно:

1. Проверить входящий Tailscale SSH к `moto-root` с home-server (после
   восстановления доступа к серверу).
2. Если входящий тоже не работает — искать причину в патче форка: правки
   `wgengine/netstack/netstack.go` (перехват DNS), `net/netmon/state.go`
   (список интерфейсов через `anet`) и `tsconst/linuxfw.go` (fwmark) лежат
   ровно на этом пути. Разделитель: собрать апстримный `tailscaled` тех же
   версии и тегов и повторить тест — если у апстрима TCP идёт, это баг патча.
3. Только после этого закрывать Task B3.

### Task B2: `service.sh` модуля — запуск и сторож с проверкой здоровья

**Files:**
- Create/modify: `module/service.sh`
- Create: `module/vau-tailscale.conf.example`

**Interfaces:**
- Consumes: `/data/adb/tailscale/tailscaled` (Task A) и команду из B1.
- Produces: демон, поднятый на каждой загрузке до разблокировки, со сторожем.

- [ ] **Step 1: Написать `service.sh`** по образцу Phantom Tamer. Ключевые свойства:
  - НЕ ждать `sys.user.0.ce_available` — смысл в запуске до разблокировки; состояние в DE-хранилище `/data/adb/tailscale` доступно сразу.
  - Ждать только сеть: `until getprop | grep -q ...` либо простой `until ping/route ready`.
  - Запуск демона командой из B1.
  - Конфиг `/data/adb/vau-tailscale.conf` (переживает обновления, как у Phantom Tamer): `TUN_MODE=userspace|kernel`, `EXTRA_ARGS`, `WATCH_INTERVAL`.
  - Дефолт `TUN_MODE=userspace`.
- [ ] **Step 2: Сторож с проверкой РЕЗУЛЬТАТА, а не только процесса** (урок из «цены» отката):
  - процесс жив: `pgrep -f /data/adb/tailscale/tailscaled`;
  - демон отвечает: `tailscale --socket=… status --json` возвращает `BackendState=Running`;
  - если процесс есть, но статус не отвечает N раз — убить и перезапустить.
  - В userspace-режиме правил iptables нет, поэтому «застрявших» правил быть не может; проверку снятия правил добавить в Task C-этапе для TUN.
- [ ] **Step 3: Логи** в `/data/local/tmp/vau_tailscale.log`, тримминг до ~600 строк (как Phantom Tamer).
- [ ] **Step 4: Проверить синтаксис в busybox KSU и в dash**

```bash
su -c '/data/adb/ksu/bin/busybox sh -n /path/module/service.sh' && echo OK
sh -n module/service.sh && echo OK
grep -c $'\r' module/service.sh   # ожидаем 0
```

- [ ] **Step 5: Commit**

### Task B3: Упаковка модуля в CI и установка

**Files:**
- Modify: `.github/workflows/build_android.yml` (добавить job сборки zip модуля) или отдельный workflow.

- [ ] **Step 1:** В CI после сборки бинарника класть его в `module/system/.../` или скачивать модулем при установке. Решение: модуль НЕ содержит бинарник (36 МБ × каждый релиз); вместо этого `customize.sh`/`service.sh` при первой установке берёт подписанный бинарник из релиза И проверяет minisign перед установкой. Публичный ключ зашит в модуль.
- [ ] **Step 2:** Валидация zip: LF-only, `sh -n`, наличие публичного ключа.
- [ ] **Step 3: Установить и перезагрузить**, проверить лог: демон поднялся до разблокировки, `status` = Running.
- [ ] **Step 4: Commit**

### ✅ Результат этапа B (2026-09-10 22:53): доступ до разблокировки доказан

Контрольная перезагрузка с пробой `~/moto-root-probe.sh` на home-server
(опрос `ssh moto-root` раз в 5 с, вывод `getprop sys.user.0.ce_available`
и `uptime` с отметками времени).

| Время (часы сервера) | Что в журнале пробы |
|---|---|
| 22:49:14 – 22:50:21 | `Connection timed out` × 7 — телефон перезагружается |
| **22:50:27 – 22:51:12** | **9 успешных root-сессий подряд, поле `ce_available` ПУСТОЕ** |
| 22:51:18 | впервые `true` — владелец ввёл PIN |

Сверка с логами телефона:

- `22:49:29` — модуль запустил наблюдателя и `tailscaled` (лог модуля);
- `22:50:27` — первый принятый входящий SSH (58 с после старта демона: узлу
  нужно зарегистрироваться в control-plane и поднять SSH-сервер);
- `22:51:17` — Phantom Tamer зафиксировал разблокировку, проба увидела `true`
  в `22:51:18` — двое независимых часов расходятся на секунду.

От команды перезагрузки до удалённой root-оболочки — **≈93 секунды**.
Правил `ts-` в iptables: 0, сеть телефона не затронута.

Почему это важнее прошлой проверки: 68-секундное окно в первой перезагрузке
было выведено из сопоставления меток времени, но никто в него не стучался.
Здесь окно измерено самим фактом входа, а состояние «заблокирован» записано
в тот же момент, что и успешный вход.

### Task B5: WebUI модуля — админка Tailscale українською

**Files:**
- Create: `module/webroot/index.html` (самодостаточный, CSP-safe, без внешних ассетов — как в Phantom Tamer)

**Interfaces:**
- Consumes: мост `ksu.exec` KernelSU (root-shell из WebUI), бинарник `/data/adb/tailscale/tailscale`, сокет `/data/adb/tailscale/tailscaled.sock`.
- Produces: сторінку, яку відкривають з KernelSU Manager → модуль → **Web UI**.

**Мова інтерфейсу — українська.** Технічні ідентифікатори (імена вузлів, IP, прапорці CLI, назви файлів) не перекладаються.

- [ ] **Step 1: Каркас і місток до shell**

Взяти за основу `webroot/index.html` з Phantom Tamer: темна тема, без зовнішніх ресурсів, виклики через `ksu.exec`. Обгортка:

```js
const TS = '/data/adb/tailscale/tailscale --socket=/data/adb/tailscale/tailscaled.sock';
async function sh(cmd) { /* ksu.exec → {errno, stdout, stderr} */ }
```

- [ ] **Step 2: Вкладка «Стан»**

Джерело даних — один виклик `TS status --json` (розбір у JS, без парсингу тексту):
- чіп стану бекенда: `Running` / `NeedsLogin` / `Stopped` (`BackendState`);
- ім'я вузла та його адреси: `Self.HostName`, `Self.TailscaleIPs`;
- «Ключ дійсний до»: `Self.KeyExpiry` — окремим жовтим чіпом, якщо лишилось менше 30 днів, і червоним, якщо термін минув (пам'ятаємо дедлайн ~2027-01-06 для інших вузлів);
- exit node, якщо задіяно: `ExitNodeStatus`;
- режим мережі: читати з `/data/adb/vau-tailscale.conf` (`TUN_MODE`), показувати `userspace` / `kernel`;
- перелік вузлів tailnet: `Peer[*]` → ім'я, IP, `Online`, `LastSeen`, «через DERP чи напряму» (`CurAddr` порожній = DERP).

- [ ] **Step 3: Вкладка «Дії»**

Кнопки, кожна з підтвердженням і показом реального виводу команди:
- **Підключити** → `TS up --ssh --hostname=moto-root --accept-dns=false`;
- **Від'єднати** → `TS down`;
- **Перезапустити демон** → зупинити й дати сторожу підняти (перевірка результату, а не процесу);
- **Скопіювати команду входу** — для випадку `NeedsLogin` показати URL авторизації з `TS status --json` (`AuthURL`) і кнопку копіювання;
- **Ping вузла** → `TS ping <ip>` з полем вибору вузла зі списку peers.

Кнопки, що змінюють стан мережі (`up`/`down`), блокуються на час виконання, щоб подвійний тап не залишив демон у半-стані.

- [ ] **Step 4: Вкладка «Журнал»**

- хвіст `/data/local/tmp/vau_tailscale.log` (лог модуля: старти, перезапуски сторожа, причини);
- хвіст `/data/adb/tailscale/daemon.log` (лог самого демона);
- кнопка «Оновити»; автооновлення кожні 5 с лише поки вкладка відкрита.

- [ ] **Step 5: Перевірка на пристрої**

```bash
su -c 'ksud module action vau_tailscale'   # якщо додано action.sh
# та вручну: KernelSU Manager → модуль → Web UI
```

Перевірити: сторінка відкривається без мережі (жодних зовнішніх ассетів), `status` показує реальні дані, `down`/`up` справді змінюють `BackendState`, помилки shell видно в UI, а не мовчки.

- [ ] **Step 6: Commit** `feat(webui): Tailscale admin panel for the KSU module (ua)`

### Task B4: ACL tailnet и обёртка доступа на home-server

**Files:**
- Внешнее: админка Tailscale (ACL), `~/.ssh/config` на home-server.

- [ ] **Step 1:** В ACL tailnet добавить SSH-правило для узла `moto-root`. До Task C5 (H1) ограничить: `"users": ["root"]`, `"src": ["<home-server, свои устройства>"]`. Отключить key expiry для `moto-root` (как для остальных узлов, дедлайн ~2027-01-06 из [[phone-remote-access]]).
- [ ] **Step 2:** На home-server добавить `Host moto-root` в `~/.ssh/config`.
- [ ] **Step 3:** Обёртка `phone`: пробовать app-путь (`ssh phone`, узел приложения), при неудаче — `root@moto-root`. Проверить оба.
- [ ] **Step 4:** Проверить доступ **после перезагрузки без разблокировки**: `ssh root@moto-root 'getprop sys.user.0.ce_available'` должно вернуть, пока телефон ещё заблокирован.

---

# ЭТАП C — Фиксы аудита (открывают TUN-режим и делают SSH безопасным)

Делать только когда нужен TUN (весь телефон в tailnet) или полноценный Tailscale SSH под конкретных пользователей. Каждая задача — отдельный фикс из аудита, независимо тестируемый. Порядок: сперва безопасность SSH (можно применить и в userspace-режиме), потом DNS и routing (нужны для TUN).

### Task C1: Удалить самообновление (C1) — уже частично сделано тегом

**Files:**
- Modify: `clientupdate/clientupdate.go:188` (ветка android), удалить `clientupdate/clientupdate_android.go` из сборки.

- [ ] **Step 1:** Тег `clientupdate` уже убран из сборки (Task A1) — команды `tailscale update` нет. Дополнительно в `getUpdateFunction` для android вернуть `nil, false`, чтобы даже при случайной сборке с тегом автообновление не включалось и tailnet-default (`onTailnetDefaultAutoUpdate`, `local.go:3765`) не смог его активировать.
- [ ] **Step 2:** `go vet` android-сборки пакета.
- [ ] **Step 3: Commit** `fix(update): disable network self-update on android (C1)`.

### ✅ C2 и C3 выполнены 2026-09-11 (коммит `9443625`)

Пара «до/после» снята через **реальный SSH** с home-server, а не только тестами.

| Вход | До | После |
|---|---|---|
| выдуманное имя `no-such-user-vau` | `id -u` = **0**, `id -un` = **root** | отказ: `tailscale: failed to look up local user` |
| `root@` (контроль) | uid 0 | uid 0 — путь доступа цел |
| `shell@` (реальный AID) | uid 2000, группы демона | uid 2000, `id -G` = **2000** |

Механика H1 оказалась проще, чем описано ниже: хелпер
`getAndroidCommandOutput` трактовал **последний аргумент как значение по
умолчанию**, поэтому запасная строка `(ctx, "id", "-u", "0")` выполняла
`id -u` — «кто я», — а не `id -u 0`. У root-демона это уверенно давало 0.

H2 в том же проходе: `id -Gz` в toybox отсутствует как опция, да и вызывался
без имени пользователя, поэтому сессия получала группы демона, а запасной
путь возвращал жёстко зашитое `{"0"}`. Теперь `id -G <user>`, а ошибка
возвращается наверх вместо тихой подмены.

H5 частично: `id` и оболочка входа — абсолютные пути в `/system/bin`.

Проверено: 4 теста в `util/osuser` падают на старом коде и проходят на новом;
`gofmt` чист; собираются linux/arm64 и android/arm64, включая `cmd/tailscaled`
и `ssh/tailssh`; `go vet` чист; запущенный на узле бинарник побайтно совпадает
с собранным (`27c40052…`), прежний сохранён как `tailscaled.prev`.

Следствие для политики tailnet: `users` в правиле SSH снова означает то, что
написано, — `autogroup:nonroot` больше не фикция на этом узле.

### ✅ H3 выполнен 2026-09-11 (коммит `7b429bb`), остаток C4 — только переносимость

Android-ветка `launchProcess` дописывала окружение демона **целиком** после
`envForUser`, а `os/exec` при дубликате оставляет последнее значение — поэтому
вычисленные для пользователя `HOME`, `PATH`, `USER` и `SHELL` молча
перетирались. Рабочий каталог тоже принудительно ставился в домашний каталог
демона.

Замер через реальный SSH, сессия под uid 2000:

| | До | После |
|---|---|---|
| `HOME` | `/data/adb/tailscale` (каталог root, права 700) | `/` |
| `ls $HOME` | **НЕТ** | да |
| `USER` | `shell` | `shell` |
| `TMPDIR` | `/data/local/tmp` | `/data/local/tmp` (через белый список) |
| `cwd` | `/` | `/` |

Вместо слепого копирования — белый список `TMPDIR`, `TZ`, `LANG`. Доступ под
`root@` не затронут, отказ неизвестному пользователю (H1) держится.

Важное уточнение к самой находке H3: опасной утечки (пути Termux, `LD_PRELOAD`,
прокси-креды) на этом телефоне **не было** — `service.sh` запускает демон через
`env -i`, поэтому в сессию попадало 9 чистых переменных. Дефект был в подмене
пользовательских значений, а не в утечке.

**Остаток C4 (переносимость, не поломка).** Сессии получают обобщённый
Unix-овый `PATH=/usr/local/bin:/usr/bin:/bin`. На этом устройстве он работает
исключительно потому, что `/bin` — ссылка на `/system/bin`, а `/usr/bin`,
`/usr/local/bin` и `/sbin` не существуют; проверено: `command -v ls` →
`/bin/ls`, `ls` и `id` работают. Сделать Android-овый `PATH` явным стоит, но
это отдельная правка, а не исправление существующей поломки.

### ✅ Один вход вместо двух, 2026-09-11 (коммит `fb70b39`)

Сессия под uid приложения получает домашний каталог **своего** приложения, а
его `bin` встаёт первым в `PATH`. До этого вход под uid Termux приземлялся в
`HOME=/` без единого инструмента Termux в `PATH`, поэтому до них приходилось
добираться вторым, другим входом.

Замер через реальный SSH:

| | До | После |
|---|---|---|
| `HOME` | `/` | `/data/data/com.termux/files/home` |
| `PATH` | `/system/bin:…` | `/data/data/com.termux/files/usr/bin:/system/bin:…` |
| `command -v bash` | пусто | `/data/data/com.termux/files/usr/bin/bash` |
| `root@` | `/data/adb/tailscale` | без изменений |
| `shell@` (uid 2000) | `/` | без изменений |

Соответствие uid↔пакет берётся из `/system/bin/pm list packages -U`, а не
собирается из строки: uid выдаются при установке и на разных аппаратах разные.
Спрашивается он **только** для uid ≥ 10000 — именно это отсечение не пускает
загрузочный вход root в этот код: до первой разблокировки системный сервер
может не ответить на binder-вызов, а ждать его будет единственный путь обратно
в телефон. Медленный `pm` ограничен уже существующим 10-секундным контекстом
поиска и деградирует до `/`, а не подвешивает вход. Цена измерена: ~120 мс и
только на входах под app-uid (637–736 мс против 511–567 мс у root).

`/data/data` зашифровано учётными данными, поэтому каталог используется лишь
когда он читаем; root остаётся в `/data/adb/tailscale` (DE-хранилище, читаемое
при загрузке). Тесты в `util/osuser/user_android_test.go` закрепляют обе
половины, включая отказ системному uid **до** `exec` — это проверяется по
затраченному времени, потому что `pm` дороже на два порядка.

### Task C2: SSH — неизвестный пользователь должен получать отказ, а не root (H1)

**Files:**
- Modify: `util/osuser/user_android.go:37-46`
- Test: on-device проба (как `zz_audit_test.go` в аудите)

- [ ] **Step 1:** Воспроизвести баг пробой: `lookup("no-such-user")` → сейчас `uid=<demon> username=root`. (В аудите подтверждено.)
- [ ] **Step 2:** Переписать `androidLookup`: если `id -u <user>` завершается ненулевым кодом (проверено: `id -u unknown` exit=1) — **вернуть ошибку**, не подставлять root. Хелпер `getAndroidCommandOutput` с «последний аргумент = дефолт» переписать так, чтобы неуспех был отличим от значения.
- [ ] **Step 3:** Проба: неизвестный → ошибка; `u0_a477` → `uid=10477`; `shell` → `uid=2000`; `root` → `uid=0`.
- [ ] **Step 4: Commit** `fix(ssh): reject unknown user instead of falling back to root (H1)`.

### Task C3: SSH — реальные группы пользователя (H2) + toybox не знает `id -Gz`

**Files:**
- Modify: `util/osuser/group_ids.go:23-32`

- [ ] **Step 1:** Зафиксировать факт: на телефоне `id -Gz` → `Unknown option 'z'` (toybox). Значит текущая ветка android вообще не работает и падает в возврат `["0"]`. А `id -G <user>` работает: `id -G u0_a477` → `10477`.
- [ ] **Step 2:** Заменить `id -Gz` (без пользователя) на `id -G <username>` с разбором по пробелам. Для app-uid дополнить группами как в Phantom Tamer keeper (`3003, 9997, 1077, 1079, 20xxx, 50xxx`) — это единственный проверенный способ дать сессии сеть и `/sdcard`.
- [ ] **Step 3:** Проба: `GetGroupIds(u0_a477)` содержит `3003` и `1077`; для разных пользователей списки разные (сейчас одинаковые).
- [ ] **Step 4:** В `incubator.go:1213` (android-ветка `setGroups`) убрать молчаливое игнорирование ошибки `Setgroups` у root — считать фатальной.
- [ ] **Step 5: Commit** `fix(ssh): per-user groups via id -G, toybox has no -Gz (H2)`.

### Task C4: SSH — окружение и HOME/PATH пользователя, не демона (H3)

**Files:**
- Modify: `ssh/tailssh/incubator.go:850-858`; `util/osuser/user_android.go:46`

- [ ] **Step 1:** Убрать копирование всего `os.Environ()` демона в сессию. Оставить явный allow-list.
- [ ] **Step 2:** `HOME`/`PATH` вычислять по пользователю: для Termux-uid (после разблокировки) — префикс Termux; иначе `/system/bin:/system/xbin`, `HOME=/data/local/tmp` или `/`.
- [ ] **Step 3:** Проба через реальный `ssh root@moto-root 'echo $HOME $PATH'` и под app-uid.
- [ ] **Step 4: Commit** `fix(ssh): per-user HOME/PATH/env, not the daemon's (H3)`.

### Task C5: SSH — не использовать `login`, абсолютные пути (H4, H5)

**Files:**
- Modify: `ssh/tailssh/incubator.go` (android-ветки `shouldAttemptLoginShell`, `loginArgs`, `tryExecLogin`); `util/osuser/*`, `hostinfo/hostinfo_android.go`

- [ ] **Step 1:** На телефоне `/system/bin/login` отсутствует, `login` в чистом PATH — алиас-builtin. Значит риск H4 реализуется только если в PATH демона окажется чужой `login` (Termux). Убрать android из пути через `login`: сразу `handleInProcess` со сбросом привилегий.
- [ ] **Step 2:** H5: заменить `exec.Command("id"/"getprop")` и `LookPath` на абсолютные `/system/bin/id`, `/system/bin/getprop`, `/system/bin/sh`. Демон в модуле всегда стартует с чистым PATH (Task B2).
- [ ] **Step 3:** Флаг `--is-selinux-enforcing` передавать и на android (сейчас только linux; телефон Enforcing).
- [ ] **Step 4:** Проба доступа под разными пользователями; проверить, что подмена `id` в PATH пользователя больше не влияет.
- [ ] **Step 5: Commit** `fix(ssh): drop login path, use absolute system binaries (H4,H5)`.

### Task C6: DNS — не ломать телефон в userspace и починить петлю (C2, C3, M1, M2, M3)

**Files:**
- Modify: `net/dns/manager_android.go`, `wgengine/netstack/netstack.go`

Делать только для TUN-режима; в userspace `--accept-dns=false` уже обходит проблему.

- [ ] **Step 1:** `GetBaseConfig` реализовать через DNS текущей сети (netd / `getprop net.dns1` / `ndc resolver`); при неуспехе — не включать перехват (иначе C2: SERVFAIL на всё).
- [ ] **Step 2:** Правила DNAT: исключить собственный трафик демона (по mark обхода `0x10020000/0x1e000000` или по uid 0) и интерфейс `tailscale0`, а не только `tun+` (C3).
- [ ] **Step 3:** Правила добавлять `AppendUnique` и чистить при старте (M1), только UDP (M2), REJECT для DNS по IPv6 если нет ip6 nat (M3).
- [ ] **Step 4:** Перехват в netstack (`handleLocalPackets`) ограничить: не перехватывать запросы к адресам tailnet и собственные (иначе петля C3).
- [ ] **Step 5:** Проба на телефоне: с `--accept-dns` и глобальным сервером `100.102.182.105` (AdGuard) резолвинг работает, петли нет; `dig @100.100.100.100 example.com` отвечает.
- [ ] **Step 6: Commit** `fix(dns): android base config + loop-free hijack (C2,C3,M1,M2,M3)`.

### Task C7: Routing/точка доступа — не раздавать tailnet по умолчанию, чинить MSS (H6, M4, M5, M6)

**Files:**
- Modify: `util/linuxfw/iptables_runner.go`, `wgengine/router/osrouter/router_linux.go`

- [ ] **Step 1:** Безусловные `-o tailscale0 -j MASQUERADE` для клиентов точки доступа сделать опцией (по умолчанию off), ограничить интерфейсом точки (H6).
- [ ] **Step 2:** MSS-clamp только для forward-трафика `tailscale0`, с `--clamp-mss-to-pmtu` (M4).
- [ ] **Step 3:** Правило `100.64/10 → table 52` исключает собственный помеченный трафик (M5).
- [ ] **Step 4:** Правило exit node пересчитывать по событиям netmon; удалять по сохранённой таблице (M6).
- [ ] **Step 5:** Проба в TUN-режиме на телефоне; проверить, что бэкап Nextcloud и AdGuard-логи не сломались.
- [ ] **Step 6: Commit** `fix(router): hotspot opt-in, MSS scope, route leaks (H6,M4,M5,M6)`.

### Task C8: Симлинк tailscale не должен удалять себя (H7)

**Files:**
- Modify: `cmd/tailscaled/tailscaled.go:72-107`

- [ ] **Step 1:** Воспроизвести (в аудите: бинарник с именем `tailscale` удаляет себя, остаётся `tailscale -> tailscale`).
- [ ] **Step 2:** Создавать симлинк только из установочного скрипта модуля (Task B), из `createTailscaleSymlink` убрать удаление обычного файла и случай «путь == собственный бинарник».
- [ ] **Step 3:** Проба: запуск бинарника с именем `tailscale` не разрушает установку.
- [ ] **Step 4: Commit** `fix(daemon): symlink helper must not delete itself (H7)`.

### Task C9: Перенос патча на актуальный upstream (после стабилизации фиксов)

**Files:**
- Все android-патчи; `scripts/android.sh update`.

- [ ] **Step 1:** Апстрим ушёл до v1.102.3 (форк на v1.98.8). Разбить squash-коммит `d6a7411` на тематические (DNS/routing/SSH/paths/updater) — легче переносить и ревьюить.
- [ ] **Step 2:** `scripts/android.sh update v1.102.3`, разрешить конфликты, собрать.
- [ ] **Step 3:** Проверить, что база = официальный тег (как в аудите: сравнить commit/tree hash).
- [ ] **Step 4:** Прогнать все пробы этапов A–C.
- [ ] **Step 5: Commit**.

---

## Self-Review

**Spec coverage (VAU-AUDIT.md → задача):**
- C1 → A1(тег)+C1 · C2 → C6 · C3 → C6 · H1 → C2 · H2 → C3 · H3 → C4 · H4 → C5 · H5 → C5 · H6 → C7 · H7 → C8
- M1/M2/M3 → C6 · M4/M5/M6 → C7 · M8 → A2 · M10 → A4 · M9(тесты android) → отдельно, см. ниже · M11(anet replace) → принять как есть, следить · M7 → не проявляется на этом телефоне (есть шлюз), закрыть при C7
- LOW-находки (no-logs default, Taildrop путь, LogsDir mkdir, regexp версии) → мелкие, приложить к ближайшим задачам, отдельных не заводить.
- **Пробел:** M9 (тесты `net/dns`/`net/netmon` не компилируются под android). Не блокирует сборку демона, но чинить перед C6, иначе `go test` недоступен. Добавить как под-шаг Task C6 Step 0.
- **Не из аудита, но найдено сегодня:** toybox без `id -Gz` — учтено в C3 Step 1.

**Placeholder scan:** команды и constraints конкретны; где правка Go описана словами (C2–C8), причина — точный код зависит от результата пробы на устройстве, поэтому каждая такая задача начинается с воспроизводящей пробы и заканчивается проверяющей. Это осознанный формат для systems-задач, не заглушки.

**Type/naming consistency:** `TAGS`, пути `/data/adb/tailscale/{tailscaled,tailscaled.sock,tailscaled.state}`, `TUN_MODE`, узел `moto-root`, конфиг `/data/adb/vau-tailscale.conf` — использованы единообразно между этапами.

## Порядок и что даёт каждый этап

1. **Этап A** (A1–A4): подписанный бинарник из своего CI. День работы. Ничего на телефоне не меняет.
2. **Этап B** (B0–B4): доступ **до разблокировки** через отдельный узел `moto-root`, userspace-режим, без риска для сети телефона и без конфликта с приложением. Это и есть исходная цель. **Пока не сделан C2, root-доступ по Tailscale SSH держать за ACL.**
3. **Этап C** (C1–C9): безопасность SSH (C2–C5) — можно применить сразу после B; DNS/routing (C6–C7) — только если понадобится TUN-режим (весь телефон в tailnet вместо приложения).
