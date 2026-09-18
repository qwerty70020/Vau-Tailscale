# Сборка и проверка подлинности (Vau-Tailscale)

Форк собирается **только** в CI этого репозитория и подписывается ключом владельца.
Готовые бинарники из чужих репозиториев здесь не используются: самообновление через
сеть вырезано из сборки (см. `docs/vau/AUDIT.md`, находка C1).

## Публичный ключ

```
RWQrO9+IrOg9bpoqEIUiN6eVHn7GPYgtfvoHjjjPg9DdlMhv2vmWA7xl
```

Идентификатор ключа: `6E3DE8AC88DF3B2B`. Приватный ключ существует в двух местах:
у владельца (`~/.minisign/vau-tailscale.key`, вне git) и в секрете репозитория
`MINISIGN_SECRET_KEY`. Ключ без пароля — иначе `minisign` в CI ждал бы ввода.

## Проверка скачанного релиза

```bash
# 1) целостность
sha256sum -c SHA256SUMS

# 2) подлинность
minisign -Vm tailscale_<версия>_arm64.tgz \
  -P RWQrO9+IrOg9bpoqEIUiN6eVHn7GPYgtfvoHjjjPg9DdlMhv2vmWA7xl
```

Ожидается `Signature and comment signature verified`. Любой другой вывод —
не устанавливать. Проверено, что подпись, сделанная другим ключом, отвергается.

`minisign` в Termux: `pkg install minisign`.

## Сборка в CI

Workflow `.github/workflows/build_android.yml`, запуск вручную
(`gh workflow run build_android.yml`) или пушем тега `v*-vau*`.

- сборка без CGO (NDK не нужен), цели `arm64` и `arm`;
- **без UPX**: упакованный бинарник разворачивается в анонимную память целиком,
  это лишний RSS на телефоне, где регулярно срабатывает LOW_MEMORY, и повод для
  ложных срабатываний антивирусов;
- все `uses:` закреплены по SHA коммита, а не по тегу: владелец тега может
  переставить его на другой код, который соберёт наш root-бинарник;
- на выходе `.tgz`, `SHA256SUMS` и `.minisig` к каждому файлу.

## Локальная сборка (запасной путь)

На самом телефоне, Go 1.27 из Termux:

```bash
cd ~/Vau-Tailscale
export GOTOOLCHAIN=local GOEXPERIMENT=nojsonv2 CGO_ENABLED=0

TAGS=$(GOOS= GOARCH= go run ./cmd/featuretags \
  --remove "aws,bird,tap,kube,completion,completion_scripts,wakeonlan,capture,systray,syspolicy,appconnectors,identityfederation,usermetrics,logtail,netlog,linuxdnsfight,tpm,clientupdate" \
  --add "cli")

GOOS=android GOARCH=arm64 go build -tags="$TAGS" -trimpath -o /tmp/tailscaled ./cmd/tailscaled
```

Измерено 2026-09-10: 1 мин 34 с, 36 МБ.

`GOEXPERIMENT=nojsonv2` обязателен на Go 1.27: без него `go-json-experiment`
не собирается (`undefined: json.SkipFunc`). В CI используется версия из `go.mod`,
там этот флаг не нужен.

### Почему в наборе тегов нет `clientupdate`

С этим тегом в бинарнике появляется команда `tailscale update`, которая скачивает
`tailscaled` из **чужого** репозитория без проверки подписи и ставит его с правами
`0777` (находка C1). Без тега команда просто отсутствует:

```
$ tailscale update
tailscale: unknown subcommand: update
```

Обновление демона идёт только через переустановку модуля KSU.

## Проверка собранного бинарника

```bash
./tailscaled --version          # версия и коммит
./tailscale up --help | grep -- --ssh   # Tailscale SSH на месте
./tailscale update              # должно быть: unknown subcommand
```
