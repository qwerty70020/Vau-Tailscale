#!/usr/bin/env bash
# Скрипт розробки Tailscale для Android
# Використання:
#   ./scripts/android.sh build [--pre] [--upx] [--nocgo] [--allow-dirty] <arm|arm64|amd64>
#   ./scripts/android.sh check [arm64]
#   ./scripts/android.sh compat [--check] [--build] [--rc] [--squash] [stop-tag]
#   ./scripts/android.sh update [--dry-run] [--squash] [--no-build] [target-tag]
#   ./scripts/android.sh manifest [--write]
#   ./scripts/android.sh verify [base-ref]
#
# Навіщо існують manifest/verify: cherry-pick, що завершився «✓», доводить лише,
# що git знайшов, куди покласти кожен hunk. Він не доводить, що hunk'и досі там.
# Конфлікт, розв'язаний руками, може тихо викинути додатковий hunk у файлі, який
# upstream і так постачає, — і результат усе одно компілюється. Саме так одного
# разу було втрачено патч build-тегу в router_linux.go. Див. docs/vau/UPSTREAM.md.

set -euo pipefail

NDK_VERSION="r27c"
NDK_DIR="/tmp/android-ndk-${NDK_VERSION}-linux"
MANIFEST_REL="scripts/fork-manifest.txt"

# --- Допоміжні функції ---

setup_ndk() {
    export ANDROID_NDK_PATH="${ANDROID_NDK_PATH:-${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin}"
    if [ -d "$ANDROID_NDK_PATH" ]; then return; fi
    echo "Завантажую NDK ${NDK_VERSION}..."
    curl -# -L "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" -o /tmp/android-ndk.zip
    unzip -q /tmp/android-ndk.zip -d /tmp
    mv "/tmp/android-ndk-${NDK_VERSION}" "$NDK_DIR"
    rm /tmp/android-ndk.zip
}

set_arch() {
    export GOOS=android
    case "$1" in
        arm)   export GOARCH=arm CC=armv7a-linux-androideabi21-clang CXX=armv7a-linux-androideabi21-clang++ ;;
        arm64) export GOARCH=arm64 CC=aarch64-linux-android21-clang CXX=aarch64-linux-android21-clang++ ;;
        amd64) export GOARCH=amd64 CC=x86_64-linux-android21-clang CXX=x86_64-linux-android21-clang++ ;;
        *)     echo "Невідома архітектура: $1"; exit 1 ;;
    esac
}

get_build_tags() {
    # clientupdate вимкнено навмисно: з ним бінарник несе `tailscale update`,
    # який завантажує tailscaled зі стороннього GitHub-репозиторію без перевірки
    # підпису і ставить його з правами 0777 (див. docs/vau/AUDIT.md, C1).
    # Оновлення приходять лише перевстановленням KSU-модуля, і ніяк інакше.
    local remove="aws,bird,tap,kube,completion,completion_scripts,wakeonlan,capture,systray,syspolicy,appconnectors,identityfederation,usermetrics,logtail,netlog,linuxdnsfight,tpm,clientupdate"
    GOOS= GOARCH= ./tool/go run ./cmd/featuretags --remove "$remove" --add "cli"
}

get_ldflags() {
    eval "$(./build_dist.sh shellvars)"
    if [ "${PRE_RELEASE:-}" = "1" ]; then
        VERSION_SHORT="${VERSION_SHORT}-pre"
    fi
    echo "-X tailscale.com/version.longStamp=${VERSION_LONG} -X tailscale.com/version.shortStamp=${VERSION_SHORT} -X tailscale.com/version.gitCommitStamp=${VERSION_GIT_HASH} -w -s"
}

compress() {
    if ! command -v upx &>/dev/null; then
        curl -# -L "https://github.com/upx/upx/releases/download/v5.0.2/upx-5.0.2-amd64_linux.tar.xz" -o /tmp/upx.tar.xz
        tar -xf /tmp/upx.tar.xz -C /tmp && sudo mv /tmp/upx-5.0.2-amd64_linux/upx /usr/local/bin/
        rm -rf /tmp/upx.tar.xz /tmp/upx-5.0.2-amd64_linux
    fi
    echo "До:    $(du -h "$1" | cut -f1)"
    upx --lzma --best "$1" 2>&1 | grep -v "^$" || true
    echo "Після: $(du -h "$1" | cut -f1)"
}

# Upstream-коміт, на якому сидить наш патч: коміт «VERSION.txt: this is vX.Y.Z»,
# яким tailscale позначає кожен реліз. Потрібен у трьох місцях, тому живе тут,
# а не передруковується щоразу.
find_base_commit() {
    local v="${1#v}"
    git log --oneline | grep "VERSION.txt: this is v\?${v}" | head -1 | cut -d' ' -f1
}

# `git clone --shared` ділить об'єкти, але НЕ .git/rr-cache, тож конфлікт,
# розв'язаний руками у справжньому репозиторії, довелося б розв'язувати знову
# в кожному одноразовому клоні. Симлінк на кеш — саме те, завдяки чому rerere
# тут узагалі окупається: build-теги і go.mod конфліктують однаково на кожному
# тезі.
clone_shared() {
    local src="$1" dst="$2"
    git clone --quiet --shared "$src" "$dst"
    git -C "$dst" config rerere.enabled true
    git -C "$dst" config rerere.autoupdate true
    mkdir -p "$src/.git/rr-cache"
    rm -rf "$dst/.git/rr-cache"
    ln -sfn "$src/.git/rr-cache" "$dst/.git/rr-cache"
}

enable_rerere() {
    if [ "$(git config --get rerere.enabled 2>/dev/null || true)" != "true" ]; then
        git config rerere.enabled true
        git config rerere.autoupdate true
        echo "rerere увімкнено: конфлікт, розв'язаний один раз, далі застосовується сам."
    fi
    mkdir -p "$(git rev-parse --git-dir)/rr-cache"
}

# --- Маніфест ---

# Вивести маніфест для base..head на stdout.
#
# [files]   повний numstat. Після rebase кожен шлях звідси має й далі бути в
#           дельті — шлях, що зник, це патч, який викинули.
# [markers] ОДИН буквальний рядок на hunk, для файлів, які ВЖЕ ІСНУЮТЬ в upstream
#           на base. Цілком новий файл або виживає весь, або зникає з [files],
#           тож маркер йому не потрібен. Небезпечний випадок — протилежний:
#           +76 рядків, доданих до upstream'ового netstack.go, тихо викинуті під
#           час конфлікту, і все компілюється. На hunk, а не на файл, бо файл із
#           7 hunk'ів, закріплений 2 маркерами, лишає 5 hunk'ів без нагляду.
#           Маркер має бути УНІКАЛЬНИМ у пропатченому файлі: рядок, що трапляється
#           двічі, нічого не доводить про те, яка копія вижила, а шаблонне
#           `if err != nil {` є в upstream незалежно від нашого патчу.
# [absent]  дзеркальне відображення, для hunk'ів, які лише ВИДАЛЯЮТЬ. У них немає
#           доданого рядка, за який можна зачепитись, — і саме такої форми патч
#           ми одного разу втратили (`-//go:build !android`, нічого не додано).
#           Тож закріплюємо відсутність: якщо рядок знову в дереві, наше
#           видалення відкотилося.
gen_manifest() {
    local base="$1" head="$2"
    local base_name
    base_name=$(git describe --tags --exact-match "$base" 2>/dev/null || git rev-parse --short "$base")

    echo "# fork delta manifest — regenerate with: scripts/android.sh manifest --write"
    echo "# Checked automatically after every cherry-pick by compat/update."
    echo "# A '✓ tag' from git means the patch applied, not that it is all there."
    echo "base $base_name"
    echo "head $(git rev-parse --short "$head")"
    echo "[files]"
    git diff --no-renames --numstat "$base..$head"

    local mk
    mk=$(mktemp)
    git diff --no-renames --numstat "$base..$head" | cut -f3 | while IFS= read -r f; do
        git cat-file -e "$base:$f" 2>/dev/null || continue
        git cat-file -e "$head:$f" 2>/dev/null || continue
        # Перший вхід — пропатчений файл, щоб порахувати входження. Другий — його
        # diff. Шлях іде через оточення з тієї ж причини, що й маркер у
        # line_present(): awk розгортає backslash-екранування у значеннях -v.
        F="$f" awk '
            function emit() {
                if (add != "") print "M\t" f "\t" add
                else if (!hadadd && del != "") print "A\t" f "\t" del
                add = ""; addlen = 0; del = ""; dellen = 0; hadadd = 0
            }
            BEGIN { f = ENVIRON["F"] }
            NR == FNR { l = $0; sub(/^[ \t]+/, "", l); cnt[l]++; next }
            /^(\+\+\+|---)/ { next }
            /^@@/ { emit(); next }
            /^\+/ {
                hadadd = 1
                l = substr($0, 2); sub(/^[ \t]+/, "", l)
                if (index(l, "\t") > 0) next
                n = length(l)
                if (n < 12 || n > 200 || cnt[l] != 1) next
                if (n > addlen) { addlen = n; add = l }
                next
            }
            /^-/ {
                l = substr($0, 2); sub(/^[ \t]+/, "", l)
                if (index(l, "\t") > 0) next
                n = length(l)
                if (n < 12 || n > 200 || cnt[l] != 0) next
                if (n > dellen) { dellen = n; del = l }
                next
            }
            END { emit() }
        ' <(git show "$head:$f") <(git diff -U0 --no-renames "$base..$head" -- "$f")
    done > "$mk"

    echo "[markers]"
    grep '^M' "$mk" | cut -f2- || true
    echo "[absent]"
    grep '^A' "$mk" | cut -f2- || true
    rm -f "$mk"
}

# line_present <файл> <буквальний-рядок>
# Збіг цілого рядка з точністю до початкового відступу — те саме обрізання, що
# робить gen_manifest, обираючи рядок. Підрядкового збігу (grep -F) замало: наші
# патчі build-тегів СКОРОЧУЮТЬ тег, тож рядок форку — буквальний префікс
# upstream'ового, і grep доповів би про збіг на непропатченому файлі.
# Рядок іде через оточення, ніколи через awk -v: awk розгортає backslash-
# екранування у значеннях -v, а рядки Go-коду несуть \n усередині рядкових
# літералів.
line_present() {
    [ -f "$1" ] || return 1
    MARKER="$2" awk '
        BEGIN { m = ENVIRON["MARKER"] }
        { l = $0; sub(/^[ \t]+/, "", l); if (l == m) { found = 1; exit } }
        END { exit !found }' "$1"
}

# verify_manifest <base-ref> <шлях-до-маніфесту>
# Вихід 0 = кожен патч на місці, 1 = щось втрачено.
verify_manifest() {
    local base="$1" mf="$2"
    if [ ! -f "$mf" ]; then
        echo "  ! маніфесту немає ($mf) — scripts/android.sh manifest --write"
        return 0
    fi

    declare -A act_add act_del
    local p a d
    while IFS=$'\t' read -r a d p; do
        [ -n "$p" ] || continue
        act_add["$p"]="$a"; act_del["$p"]="$d"
    done < <(git diff --no-renames --numstat "$base..HEAD")

    local section="" lost=0 drifted=0 seen=0
    declare -A expected
    local line
    while IFS= read -r line; do
        case "$line" in
            '#'*|'') continue ;;
            'base '*|'head '*) continue ;;
            '[files]')   section="files";   continue ;;
            '[markers]') section="markers"; continue ;;
            '[absent]')  section="absent";  continue ;;
        esac
        if [ "$section" = "files" ]; then
            a="${line%%$'\t'*}"; local rest="${line#*$'\t'}"
            d="${rest%%$'\t'*}"; p="${rest#*$'\t'}"
            [ -n "$p" ] || continue
            expected["$p"]=1
            seen=$((seen + 1))
            if [ -z "${act_add[$p]+x}" ]; then
                echo "  ✗ патч втрачено цілком: $p"
                lost=$((lost + 1))
            elif [ "${act_add[$p]}" != "$a" ] || [ "${act_del[$p]}" != "$d" ]; then
                # Upstream законно дрейфує; це інформація, а не провал.
                drifted=$((drifted + 1))
            fi
        elif [ "$section" = "markers" ]; then
            p="${line%%$'\t'*}"
            local marker="${line#*$'\t'}"
            [ -n "$marker" ] || continue
            if ! line_present "$p" "$marker"; then
                echo "  ✗ шматок патчу зник усередині файлу: $p"
                echo "      очікувався рядок: $marker"
                lost=$((lost + 1))
            fi
        elif [ "$section" = "absent" ]; then
            p="${line%%$'\t'*}"
            local gone="${line#*$'\t'}"
            [ -n "$gone" ] || continue
            if line_present "$p" "$gone"; then
                echo "  ✗ видалення відкотилося: $p"
                echo "      рядок знову на місці: $gone"
                lost=$((lost + 1))
            fi
        fi
    done < "$mf"

    local newfiles=0
    for p in "${!act_add[@]}"; do
        [ -n "${expected[$p]+x}" ] || newfiles=$((newfiles + 1))
    done

    if [ "$lost" -gt 0 ]; then
        echo "  ✗ маніфест: втрачено $lost із $seen"
        return 1
    fi
    local note="маніфест ✓ ($seen файлів"
    [ "$drifted" -gt 0 ] && note="$note, у $drifted роз'їхалися рядки"
    [ "$newfiles" -gt 0 ] && note="$note, +$newfiles поза маніфестом"
    echo "  ${note})"
    return 0
}

# --- Команди ---

cmd_check() {
    local arch="${1:-arm64}"
    set_arch "$arch"
    export CGO_ENABLED=0
    local tags=$(get_build_tags)
    echo "Перевіряю android/$GOARCH..."
    ./tool/go vet -tags="$tags" ./cmd/tailscaled ./cmd/tailscale ./util/osuser ./ssh/tailssh ./net/dns ./util/linuxfw ./hostinfo ./paths
    ./tool/go build -tags="$tags" -o /dev/null -trimpath ./cmd/tailscaled
    ./tool/go build -tags="$tags" -o /dev/null -trimpath ./cmd/tailscale
    echo "✓ OK"
}

cmd_build() {
    local PRE_RELEASE="" USE_UPX="" NO_CGO="" ALLOW_DIRTY=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pre)         PRE_RELEASE="1"; shift ;;
            --upx)         USE_UPX="1"; shift ;;
            --nocgo)       NO_CGO="1"; shift ;;
            --allow-dirty) ALLOW_DIRTY="1"; shift ;;
            *)             break ;;
        esac
    done
    [ "$#" -eq 0 ] && { echo "Використання: $0 build [--pre] [--upx] [--nocgo] [--allow-dirty] <arm|arm64|amd64>"; exit 1; }

    set_arch "$1"

    # Версія приходить із mkversion (build_dist.sh shellvars) і виглядає як
    # 1.102.4-5-tde9187c6a: тег, відстань, коміт. Суфікса -dirty там немає
    # ніколи — mkversion бруд не відображає, тож грепати ldflags марно.
    # Єдиний свідок того, що бінарник відповідає коміту, — саме дерево.
    # Untracked вважаємо брудом свідомо: зайвий .go у пакеті компілюється
    # нарівні з рештою, а git describe його не помічає.
    # Демон ходить root'ом і відкочується порівнянням бінарників — це гейт, а не
    # попередження. Стоїть до setup_ndk: на брудному дереві NDK качати нема чого.
    if [ -z "$ALLOW_DIRTY" ]; then
        local dirt n
        dirt=$(git status --porcelain 2>/dev/null) || dirt=""
        if [ -n "$dirt" ]; then
            n=$(printf '%s\n' "$dirt" | wc -l)
            echo "✗ дерево брудне — бінарник не відповідатиме $(git rev-parse --short HEAD 2>/dev/null || echo '?') ($n шляхів):"
            printf '%s\n' "$dirt" | sed -n '1,5s/^/    /p'
            if [ "$n" -gt 5 ]; then echo "    … і ще $((n - 5))"; fi
            echo "  Закоміть або сховай; --allow-dirty, якщо це свідомо."
            exit 1
        fi
    fi

    if [ -z "$NO_CGO" ]; then
        export CGO_ENABLED=1
        setup_ndk
        export PATH="$ANDROID_NDK_PATH:$PATH"
    else
        export CGO_ENABLED=0
    fi

    local tags=$(get_build_tags)
    local ldflags=$(get_ldflags)

    mkdir -p ./dist
    ./tool/go build -tags="$tags" -ldflags="$ldflags" -o "./dist/tailscaled.${GOARCH}" -trimpath ./cmd/tailscaled
    chmod +x "./dist/tailscaled.${GOARCH}"
    echo "Зібрано: dist/tailscaled.${GOARCH} ($(du -h "./dist/tailscaled.${GOARCH}" | cut -f1))"

    if [ -n "$USE_UPX" ]; then compress "./dist/tailscaled.${GOARCH}"; fi
}

cmd_manifest() {
    local write=""
    [ "${1:-}" = "--write" ] && write="1"

    local from="v$(cat VERSION.txt)"
    local base_commit
    base_commit=$(find_base_commit "$from")
    if [ -z "$base_commit" ]; then
        echo "Не знайдено базовий коміт для $from"; exit 1
    fi

    if [ -z "$write" ]; then
        gen_manifest "$base_commit" HEAD
        return
    fi

    gen_manifest "$base_commit" HEAD > "$MANIFEST_REL"
    local nf nm na
    nf=$(awk '/^\[files\]/{f=1;next} /^\[markers\]/{f=0} f&&NF' "$MANIFEST_REL" | wc -l)
    nm=$(awk '/^\[markers\]/{m=1;next} /^\[absent\]/{m=0} m&&NF' "$MANIFEST_REL" | wc -l)
    na=$(awk '/^\[absent\]/{a=1;next} a&&NF' "$MANIFEST_REL" | wc -l)
    echo "✓ $MANIFEST_REL: $nf файлів, $nm маркерів, $na видалень (база $from)"
    echo "  Маніфест сам входить у дельту — після коміту перегенеруй ще раз."
}

cmd_verify() {
    local base="${1:-}"
    if [ -z "$base" ]; then
        base=$(find_base_commit "v$(cat VERSION.txt)")
    fi
    [ -n "$base" ] || { echo "Не вдалося визначити базу"; exit 1; }
    echo "Перевірка дельти проти $base:"
    verify_manifest "$base" "$MANIFEST_REL"
}

cmd_compat() {
    local to="" do_check="" do_build="" rc_only="" squash=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check)  do_check="1"; shift ;;
            --build)  do_build="1"; shift ;;
            --rc)     rc_only="1"; shift ;;
            --squash) squash="1"; shift ;;
            *)        to="$1"; shift ;;
        esac
    done

    local from="v$(cat VERSION.txt)"

    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    enable_rerere
    local tmp="/tmp/tailscale-compat-$$"

    # Маніфест береться зі справжнього репозиторію, а не з тестового дерева:
    # якщо cherry-pick викине сам маніфест, ми все одно хочемо звірятися з ним.
    local manifest_copy="/tmp/fork-manifest-$$.txt"
    if [ -f "$repo_root/$MANIFEST_REL" ]; then
        cp "$repo_root/$MANIFEST_REL" "$manifest_copy"
    fi
    trap 'rm -rf "/tmp/tailscale-compat-$$" "/tmp/fork-manifest-$$.txt"' EXIT

    echo "База: $from (з VERSION.txt)"
    echo "Клоную в $tmp..."
    clone_shared "$repo_root" "$tmp"
    cd "$tmp"

    if ! git tag | grep -q "^v1.9"; then
        git remote add upstream https://github.com/tailscale/tailscale.git 2>/dev/null
        git fetch upstream --tags --quiet
    fi

    local head_sha
    head_sha=$(git rev-parse HEAD)
    local base_commit
    base_commit=$(find_base_commit "$from")
    if [ -z "$base_commit" ]; then
        echo "Не знайдено базовий коміт для $from"
        rm -rf "$tmp" "$manifest_copy"
        exit 1
    fi

    # Типово: переграти справжні коміти по одному, точно як це робить CI.
    # Конфлікт тоді називає патч, який конфліктує, замість «android-патчу»,
    # а патч, що перестав застосовуватись, — видима подія.
    # --squash зберігає стару поведінку з одним синтетичним комітом.
    local patch_commit=""
    if [ -n "$squash" ]; then
        git checkout -q -b android-patch HEAD
        git reset --soft "$base_commit"
        git commit -q -m "android patch" --allow-empty
        patch_commit=$(git rev-parse HEAD)
    fi

    # Лише upstream-теги (наші власні -vau/-android теги — не upstream-релізи).
    # Типово — стабільні; --rc це раннє попередження по -pre/-rc тегах, яке
    # запускається за тижні до появи стабільного тегу, щоб день переїзду не
    # приніс сюрпризів.
    local tags all
    all=$(git tag -l 'v[0-9]*' --sort=version:refname | grep -v "android" | grep -v -- "-vau" || true)
    if [ -n "$rc_only" ]; then
        all=$(printf '%s\n' "$all" | grep -E -- '-(pre|rc)' || true)
    else
        all=$(printf '%s\n' "$all" | grep -v -- '-' || true)
    fi
    # Порядок версій, а не порядок рядків. Як рядок «v1.61.0-pre» більший за
    # «v1.102.4» — на третьому символі 6 б'є 1, — і прогін --rc ішов
    # перегравати два десятки тегів, старших за нашу ж базу. vnum() знімає v,
    # відкидає -pre/-rc і згортає решту в число, де 1.61.0 стоїть нижче за
    # 1.102.4. Сортування на вході (--sort=version:refname) тут не допомагає:
    # фільтр порівнює наново і по-своєму.
    local vnum='function vnum(t,  p) { sub(/^v/, "", t); sub(/-.*$/, "", t); split(t, p, "."); return p[1] * 1000000 + p[2] * 1000 + p[3] }'
    if [ -n "$to" ]; then
        tags=$(printf '%s\n' "$all" | awk -v f="$from" -v t="$to" "$vnum"' vnum($0) > vnum(f) && vnum($0) <= vnum(t)')
    else
        # Без stop-tag беремо лише найближчі теги: кожен — це клон + cherry-pick
        # + маніфест, а RC-watch у CI ганяє це щодня.
        tags=$(printf '%s\n' "$all" | awk -v f="$from" "$vnum"' vnum($0) > vnum(f)' | head -10)
    fi

    if [ -z "$tags" ]; then
        echo "No tags found after $from"
        rm -rf "$tmp" "$manifest_copy"
        exit 1
    fi

    echo ""
    local passed=0 failed=0
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        git checkout -q -f "$tag" 2>/dev/null
        git checkout -q -b "test-$tag"

        local applied=""
        if [ -n "$squash" ]; then
            git cherry-pick "$patch_commit" --quiet >/dev/null 2>&1 && applied="1"
        else
            git cherry-pick --empty=drop "$base_commit..$head_sha" >/dev/null 2>&1 && applied="1"
        fi

        if [ -n "$applied" ]; then
            local mf_out="" bad="" tail=""
            if [ -f "$manifest_copy" ]; then
                if mf_out=$(verify_manifest "$tag" "$manifest_copy"); then :; else
                    bad="1"; tail=" [маніфест]"
                fi
            fi
            if [ -n "$do_check" ] || [ -n "$do_build" ]; then
                local btags
                btags=$(get_build_tags 2>/dev/null)
                if [ -n "$do_check" ]; then
                    if GOOS=android GOARCH=arm64 CGO_ENABLED=0 ./tool/go vet -tags="$btags" ./cmd/tailscaled ./cmd/tailscale 2>/dev/null; then
                        tail="$tail [vet ✓]"
                    else
                        tail="$tail [vet ✗]"
                        bad="1"
                    fi
                fi
                if [ -n "$do_build" ]; then
                    if GOOS=android GOARCH=arm64 CGO_ENABLED=0 ./tool/go build -tags="$btags" -o /dev/null -trimpath ./cmd/tailscaled 2>/dev/null; then
                        tail="$tail [build ✓]"
                    else
                        tail="$tail [build ✗]"
                        bad="1"
                    fi
                fi
            fi
            if [ -n "$bad" ]; then
                echo "✗ $tag$tail"
                failed=$((failed + 1))
            else
                echo "✓ $tag$tail"
                passed=$((passed + 1))
            fi
            [ -n "$mf_out" ] && printf '%s\n' "$mf_out"
        else
            local conflicts
            conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
            echo "✗ $tag → $conflicts"
            failed=$((failed + 1))
            git cherry-pick --abort 2>/dev/null || git cherry-pick --quit 2>/dev/null || true
        fi
        git checkout -q -f "$tag" 2>/dev/null
        git branch -q -D "test-$tag" 2>/dev/null
    done <<< "$tags"

    echo ""
    echo "Passed: $passed  Failed: $failed"
    rm -rf "$tmp" "$manifest_copy"
}

cmd_update() {
    local target="" dry_run="" squash="" no_build=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)  dry_run="1"; shift ;;
            --squash)   squash="1"; shift ;;
            --no-build) no_build="1"; shift ;;
            *)          target="$1"; shift ;;
        esac
    done

    local from="v$(cat VERSION.txt)"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    local original_branch
    original_branch=$(git rev-parse --abbrev-ref HEAD)
    enable_rerere

    # Переконатися, що є remote upstream
    if ! git remote get-url upstream &>/dev/null; then
        git remote add upstream https://github.com/tailscale/tailscale.git
    fi
    git fetch upstream --tags --quiet

    # Визначити ціль
    if [ -z "$target" ]; then
        target=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | grep -v -- '-' | head -1)
    fi
    if [[ ! "$target" =~ ^v ]]; then target="v${target}"; fi

    if ! git rev-parse "$target" >/dev/null 2>&1; then
        echo "Тег $target не знайдено"; exit 1
    fi

    if [ "$from" = "$target" ]; then
        echo "Уже на $target"; exit 0
    fi

    echo "Оновлення: $from → $target"

    local head_sha
    head_sha=$(git rev-parse HEAD)
    local base_commit
    base_commit=$(find_base_commit "$from")
    if [ -z "$base_commit" ]; then
        echo "Не знайдено базовий коміт для $from"; exit 1
    fi

    local manifest_copy="/tmp/fork-manifest-$$.txt"
    if [ -f "$repo_root/$MANIFEST_REL" ]; then
        cp "$repo_root/$MANIFEST_REL" "$manifest_copy"
    fi
    trap 'rm -rf "/tmp/fork-manifest-$$.txt" "/tmp/tailscale-update-$$"' EXIT

    if [ -n "$dry_run" ]; then
        echo "[dry-run] Переграв би $(git rev-list --count "$base_commit..$head_sha") коміт(ів) патчу на $target"
        local tmp="/tmp/tailscale-update-$$"
        clone_shared "$repo_root" "$tmp"
        cd "$tmp"
        local pc=""
        if [ -n "$squash" ]; then
            git checkout -q -b patch HEAD
            git reset --soft "$base_commit"
            git commit -q -m "android patch"
            pc=$(git rev-parse HEAD)
        fi
        git checkout -q -f "$target"
        git checkout -q -b test
        local ok=""
        if [ -n "$squash" ]; then
            git cherry-pick "$pc" --quiet >/dev/null 2>&1 && ok="1"
        else
            git cherry-pick --empty=drop "$base_commit..$head_sha" >/dev/null 2>&1 && ok="1"
        fi
        if [ -n "$ok" ]; then
            echo "✓ Застосувався б чисто"
            [ -f "$manifest_copy" ] && verify_manifest "$target" "$manifest_copy" || true
        else
            echo "✗ Були б конфлікти:"
            git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/  /'
            git cherry-pick --abort 2>/dev/null || git cherry-pick --quit 2>/dev/null || true
        fi
        cd "$repo_root"
        rm -rf "$tmp" "$manifest_copy"
        return
    fi

    local new_branch="${target#v}-android-dev"
    if git rev-parse --verify "$new_branch" >/dev/null 2>&1; then
        echo "Гілка $new_branch уже існує. Спершу видали її або обери іншу ціль."
        exit 1
    fi

    local patch_commit=""
    if [ -n "$squash" ]; then
        local short_head
        short_head=$(git rev-parse --short HEAD)
        local commit_list
        commit_list=$(git log --format="  %h %s" "$base_commit"..HEAD --reverse)
        local coauthors
        coauthors=$(git log --format="Co-authored-by: %an <%ae>" "$base_commit"..HEAD | sort -u)
        local commit_msg="feat: android modifications

Updated from $from to $target
Squashed from branch: $original_branch ($base_commit..$short_head)

Commits:
$commit_list

$coauthors"

        git branch -q -D _update_tmp 2>/dev/null || true
        git checkout -q -b _update_tmp HEAD
        git reset --soft "$base_commit"
        git commit -q -m "$commit_msg"
        patch_commit=$(git rev-parse HEAD)
    fi

    git checkout -q -b "$new_branch" "$target"
    local ok=""
    if [ -n "$squash" ]; then
        git cherry-pick "$patch_commit" >/dev/null 2>&1 && ok="1"
    else
        git cherry-pick --empty=drop "$base_commit..$head_sha" && ok="1"
    fi

    if [ -z "$ok" ]; then
        echo "✗ Конфлікти в:"
        git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/  /'
        echo ""
        echo "Розв'язати так:"
        echo "  відредагувати конфліктні файли"
        echo "  git add <файл>"
        echo "  git cherry-pick --continue"
        echo ""
        echo "Потім, перш ніж довіряти:"
        echo "  scripts/android.sh verify $target"
        echo "  scripts/android.sh build --nocgo arm64"
        echo ""
        echo "Або скасувати:"
        echo "  git cherry-pick --abort"
        echo "  git checkout $original_branch"
        echo "  git branch -D $new_branch${squash:+ _update_tmp}"
        rm -f "$manifest_copy"
        exit 1
    fi

    [ -n "$squash" ] && git branch -q -D _update_tmp
    echo "✓ Cherry-pick пройшов, гілка: $new_branch"

    # Гейт 1: чи кожен патч досі всередині? git сказав «застосовано», а це не
    # те саме твердження.
    echo ""
    echo "Маніфест:"
    if [ -f "$manifest_copy" ]; then
        if ! verify_manifest "$target" "$manifest_copy"; then
            echo ""
            echo "✗ Патч застосувався, але частини його бракує. Не збираю."
            echo "  Дивись список вище, віднови шматки, потім:"
            echo "    scripts/android.sh verify $target"
            rm -f "$manifest_copy"
            exit 1
        fi
    fi
    rm -f "$manifest_copy"

    # Гейт 2: чи збирається? Порада, про яку людина має пам'ятати, — не гейт,
    # і саме цей крок минулого разу пропустили.
    if [ -n "$no_build" ]; then
        echo ""
        echo "! збірку пропущено (--no-build) — гілку НЕ перевірено"
        echo "  scripts/android.sh build --nocgo arm64"
        return
    fi
    echo ""
    echo "Збірка android/arm64:"
    if ! "$0" build --nocgo arm64; then
        echo ""
        echo "✗ Не збирається на $target. Гілку $new_branch залишено як є."
        exit 1
    fi

    echo ""
    echo "✓ $target: патч на місці, збирається. Ти на гілці $new_branch."
    echo ""
    echo "Далі — лише руками:"
    echo "  на телефоні: вхід під вигаданим іменем відхиляється (H1),"
    echo "               shell@ отримує свої групи (H2), HOME не каталог демона (H3)"
    echo "  git checkout $original_branch  — повернутися"
}

# --- Головна частина ---

case "${1:-}" in
    build)    shift; cmd_build "$@" ;;
    check)    shift; cmd_check "$@" ;;
    compat)   shift; cmd_compat "$@" ;;
    update)   shift; cmd_update "$@" ;;
    manifest) shift; cmd_manifest "$@" ;;
    verify)   shift; cmd_verify "$@" ;;
    *)        echo "Використання: $0 {build|check|compat|update|manifest|verify} [опції]"; exit 1 ;;
esac
