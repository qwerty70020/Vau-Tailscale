#!/usr/bin/env bash
# Tailscale Android development script
# Usage:
#   ./scripts/android.sh build [--pre] [--upx] [--nocgo] [--allow-dirty] <arm|arm64|amd64>
#   ./scripts/android.sh check [arm64]
#   ./scripts/android.sh compat [--check] [--build] [--rc] [--squash] [stop-tag]
#   ./scripts/android.sh update [--dry-run] [--squash] [--no-build] [target-tag]
#   ./scripts/android.sh manifest [--write]
#   ./scripts/android.sh verify [base-ref]
#
# Why manifest/verify exist: a cherry-pick that ends with "✓" only proves git
# found a place to put every hunk. It does not prove the hunks are still there.
# A hand-resolved conflict can quietly drop an additive hunk inside a file that
# upstream already ships — and the result still compiles. That is exactly how
# the router_linux.go build-tag patch was lost once. See docs/vau/UPSTREAM.md.

set -euo pipefail

NDK_VERSION="r27c"
NDK_DIR="/tmp/android-ndk-${NDK_VERSION}-linux"
MANIFEST_REL="scripts/fork-manifest.txt"

# --- Helpers ---

setup_ndk() {
    export ANDROID_NDK_PATH="${ANDROID_NDK_PATH:-${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin}"
    if [ -d "$ANDROID_NDK_PATH" ]; then return; fi
    echo "Downloading NDK ${NDK_VERSION}..."
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
        *)     echo "Unknown arch: $1"; exit 1 ;;
    esac
}

get_build_tags() {
    # clientupdate is removed on purpose: with it the binary carries a
    # `tailscale update` that downloads tailscaled from a third-party GitHub
    # repo with no signature check and installs it 0777 (see docs/vau/AUDIT.md, C1).
    # Updates come from reinstalling the KSU module, nothing else.
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
    echo "Before: $(du -h "$1" | cut -f1)"
    upx --lzma --best "$1" 2>&1 | grep -v "^$" || true
    echo "After:  $(du -h "$1" | cut -f1)"
}

# The upstream commit our patch sits on: the "VERSION.txt: this is vX.Y.Z"
# commit tailscale tags every release with. Used in three places, so it lives
# here instead of being re-typed each time.
find_base_commit() {
    local v="${1#v}"
    git log --oneline | grep "VERSION.txt: this is v\?${v}" | head -1 | cut -d' ' -f1
}

# `git clone --shared` shares objects but NOT .git/rr-cache, so a conflict
# resolved by hand in the real repo would have to be resolved again inside every
# throwaway clone. Symlinking the cache in is what makes rerere actually pay off
# here: build tags and go.mod conflict the same way on every single tag.
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
        echo "rerere включён: конфликт, разрешённый один раз, дальше применяется сам."
    fi
    mkdir -p "$(git rev-parse --git-dir)/rr-cache"
}

# --- Manifest ---

# Emit the manifest for base..head on stdout.
#
# [files]   the full numstat. After a rebase every path here must still show up
#           in the delta — a path that vanished is a patch that was dropped.
# [markers] ONE literal line per hunk, for files that ALREADY EXIST upstream at
#           base. A brand-new file either survives whole or disappears from
#           [files], so it needs no marker. The dangerous case is the opposite
#           one: +76 lines added to upstream's netstack.go, silently dropped
#           during a conflict, still compiles. Per hunk and not per file,
#           because a 7-hunk file pinned by 2 markers leaves 5 hunks unwatched.
#           A marker must be UNIQUE in the patched file: a line occurring twice
#           proves nothing about which copy survived, and boilerplate like
#           `if err != nil {` is present upstream regardless of our patch.
# [absent]  the mirror image, for hunks that only DELETE. Those have no added
#           line to pin — and that is exactly the shape of the patch we lost
#           once (`-//go:build !android`, nothing added). So pin the absence:
#           if the line is back in the tree, our deletion was reverted.
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
        # First input: the patched file, to count occurrences. Second: its diff.
        # The path goes through the environment for the same reason the marker
        # does in line_present() — awk expands backslash escapes in -v values.
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

# line_present <file> <literal-line>
# Whole-line match modulo leading indent — the same trimming gen_manifest does
# when it picks the line. Substring matching (grep -F) is not enough: our
# build-tag patches SHORTEN the tag, so the fork line is a literal prefix of
# upstream's and grep would report a hit on an unpatched file.
# The line goes through the environment, never through awk -v: awk expands
# backslash escapes in -v values, and Go source lines carry \n inside string
# literals.
line_present() {
    [ -f "$1" ] || return 1
    MARKER="$2" awk '
        BEGIN { m = ENVIRON["MARKER"] }
        { l = $0; sub(/^[ \t]+/, "", l); if (l == m) { found = 1; exit } }
        END { exit !found }' "$1"
}

# verify_manifest <base-ref> <manifest-path>
# Exit 0 = every patch accounted for, 1 = something was lost.
verify_manifest() {
    local base="$1" mf="$2"
    if [ ! -f "$mf" ]; then
        echo "  ! манифеста нет ($mf) — scripts/android.sh manifest --write"
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
                echo "  ✗ патч потерян целиком: $p"
                lost=$((lost + 1))
            elif [ "${act_add[$p]}" != "$a" ] || [ "${act_del[$p]}" != "$d" ]; then
                # Upstream drifts legitimately; this is information, not a failure.
                drifted=$((drifted + 1))
            fi
        elif [ "$section" = "markers" ]; then
            p="${line%%$'\t'*}"
            local marker="${line#*$'\t'}"
            [ -n "$marker" ] || continue
            if ! line_present "$p" "$marker"; then
                echo "  ✗ кусок патча пропал внутри файла: $p"
                echo "      ожидалась строка: $marker"
                lost=$((lost + 1))
            fi
        elif [ "$section" = "absent" ]; then
            p="${line%%$'\t'*}"
            local gone="${line#*$'\t'}"
            [ -n "$gone" ] || continue
            if line_present "$p" "$gone"; then
                echo "  ✗ удаление откатилось: $p"
                echo "      строка снова на месте: $gone"
                lost=$((lost + 1))
            fi
        fi
    done < "$mf"

    local newfiles=0
    for p in "${!act_add[@]}"; do
        [ -n "${expected[$p]+x}" ] || newfiles=$((newfiles + 1))
    done

    if [ "$lost" -gt 0 ]; then
        echo "  ✗ манифест: потеряно $lost из $seen"
        return 1
    fi
    local note="манифест ✓ ($seen файлов"
    [ "$drifted" -gt 0 ] && note="$note, у $drifted разъехались строки"
    [ "$newfiles" -gt 0 ] && note="$note, +$newfiles вне манифеста"
    echo "  ${note})"
    return 0
}

# --- Commands ---

cmd_check() {
    local arch="${1:-arm64}"
    set_arch "$arch"
    export CGO_ENABLED=0
    local tags=$(get_build_tags)
    echo "Checking android/$GOARCH..."
    ./tool/go vet -tags="$tags" ./cmd/tailscaled ./cmd/tailscale
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
    [ "$#" -eq 0 ] && { echo "Usage: $0 build [--pre] [--upx] [--nocgo] [--allow-dirty] <arm|arm64|amd64>"; exit 1; }

    set_arch "$1"

    # Версия приходит из mkversion (build_dist.sh shellvars) и выглядит как
    # 1.102.4-5-tde9187c6a: тег, расстояние, коммит. Суффикса -dirty там нет
    # никогда — mkversion грязь не отражает, так что грепать ldflags бесполезно.
    # Единственный свидетель того, что бинарь соответствует коммиту, — само дерево.
    # Untracked считаем грязью осознанно: лишний .go в пакете компилируется
    # наравне с остальными, а git describe его не замечает.
    # Демон ходит root'ом и откатывается сравнением бинарей — это гейт, не предупреждение.
    # Стоит до setup_ndk: на грязном дереве NDK качать незачем.
    if [ -z "$ALLOW_DIRTY" ]; then
        local dirt n
        dirt=$(git status --porcelain 2>/dev/null) || dirt=""
        if [ -n "$dirt" ]; then
            n=$(printf '%s\n' "$dirt" | wc -l)
            echo "✗ дерево грязное — бинарь не будет соответствовать $(git rev-parse --short HEAD 2>/dev/null || echo '?') ($n путей):"
            printf '%s\n' "$dirt" | sed -n '1,5s/^/    /p'
            if [ "$n" -gt 5 ]; then echo "    … и ещё $((n - 5))"; fi
            echo "  Закоммить или спрячь; --allow-dirty если это осознанно."
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
    echo "Built: dist/tailscaled.${GOARCH} ($(du -h "./dist/tailscaled.${GOARCH}" | cut -f1))"

    if [ -n "$USE_UPX" ]; then compress "./dist/tailscaled.${GOARCH}"; fi
}

cmd_manifest() {
    local write=""
    [ "${1:-}" = "--write" ] && write="1"

    local from="v$(cat VERSION.txt)"
    local base_commit
    base_commit=$(find_base_commit "$from")
    if [ -z "$base_commit" ]; then
        echo "Cannot find base commit for $from"; exit 1
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
    echo "✓ $MANIFEST_REL: $nf файлов, $nm маркеров, $na удалений (база $from)"
    echo "  Манифест сам входит в дельту — после коммита перегенерируй ещё раз."
}

cmd_verify() {
    local base="${1:-}"
    if [ -z "$base" ]; then
        base=$(find_base_commit "v$(cat VERSION.txt)")
    fi
    [ -n "$base" ] || { echo "Cannot resolve base"; exit 1; }
    echo "Проверка дельты против $base:"
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

    # The manifest is taken from the real repo, not from the test worktree: if a
    # cherry-pick drops the manifest itself we still want to check against it.
    local manifest_copy="/tmp/fork-manifest-$$.txt"
    if [ -f "$repo_root/$MANIFEST_REL" ]; then
        cp "$repo_root/$MANIFEST_REL" "$manifest_copy"
    fi
    trap 'rm -rf "/tmp/tailscale-compat-$$" "/tmp/fork-manifest-$$.txt"' EXIT

    echo "Base: $from (from VERSION.txt)"
    echo "Cloning to $tmp..."
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
        echo "Cannot find base commit for $from"
        rm -rf "$tmp" "$manifest_copy"
        exit 1
    fi

    # Default: replay the real commits, one by one, exactly as CI does. A
    # conflict then names the patch that conflicts instead of naming "the
    # android patch", and a patch that stops applying is a visible event.
    # --squash keeps the old single-synthetic-commit behaviour.
    local patch_commit=""
    if [ -n "$squash" ]; then
        git checkout -q -b android-patch HEAD
        git reset --soft "$base_commit"
        git commit -q -m "android patch" --allow-empty
        patch_commit=$(git rev-parse HEAD)
    fi

    # Upstream tags only (our own -vau/-android tags are not upstream releases).
    # Default is stable; --rc is the early-warning pass over -pre/-rc tags, run
    # weeks before the stable tag exists so moving day has no surprises.
    local tags all
    all=$(git tag -l 'v[0-9]*' --sort=version:refname | grep -v "android" | grep -v -- "-vau" || true)
    if [ -n "$rc_only" ]; then
        all=$(printf '%s\n' "$all" | grep -E -- '-(pre|rc)' || true)
    else
        all=$(printf '%s\n' "$all" | grep -v -- '-' || true)
    fi
    # Порядок версий, а не порядок строк. Как строка "v1.61.0-pre" больше
    # "v1.102.4" — на третьем символе 6 бьёт 1, — и прогон --rc уходил
    # переигрывать два десятка тегов старше нашей же базы. vnum() снимает v,
    # отбрасывает -pre/-rc и сворачивает остаток в число, где 1.61.0 стоит ниже
    # 1.102.4. Сортировка на входе (--sort=version:refname) здесь не помогает:
    # фильтр сравнивает заново и по-своему.
    local vnum='function vnum(t,  p) { sub(/^v/, "", t); sub(/-.*$/, "", t); split(t, p, "."); return p[1] * 1000000 + p[2] * 1000 + p[3] }'
    if [ -n "$to" ]; then
        tags=$(printf '%s\n' "$all" | awk -v f="$from" -v t="$to" "$vnum"' vnum($0) > vnum(f) && vnum($0) <= vnum(t)')
    else
        tags=$(printf '%s\n' "$all" | awk -v f="$from" "$vnum"' vnum($0) > vnum(f)' | head -30)
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
                    bad="1"; tail=" [манифест]"
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

    # Ensure upstream remote
    if ! git remote get-url upstream &>/dev/null; then
        git remote add upstream https://github.com/tailscale/tailscale.git
    fi
    git fetch upstream --tags --quiet

    # Determine target
    if [ -z "$target" ]; then
        target=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | grep -v -- '-' | head -1)
    fi
    if [[ ! "$target" =~ ^v ]]; then target="v${target}"; fi

    if ! git rev-parse "$target" >/dev/null 2>&1; then
        echo "Tag $target not found"; exit 1
    fi

    if [ "$from" = "$target" ]; then
        echo "Already at $target"; exit 0
    fi

    echo "Update: $from → $target"

    local head_sha
    head_sha=$(git rev-parse HEAD)
    local base_commit
    base_commit=$(find_base_commit "$from")
    if [ -z "$base_commit" ]; then
        echo "Cannot find base commit for $from"; exit 1
    fi

    local manifest_copy="/tmp/fork-manifest-$$.txt"
    if [ -f "$repo_root/$MANIFEST_REL" ]; then
        cp "$repo_root/$MANIFEST_REL" "$manifest_copy"
    fi
    trap 'rm -rf "/tmp/fork-manifest-$$.txt" "/tmp/tailscale-update-$$"' EXIT

    if [ -n "$dry_run" ]; then
        echo "[dry-run] Would replay $(git rev-list --count "$base_commit..$head_sha") patch commit(s) onto $target"
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
            echo "✓ Would apply cleanly"
            [ -f "$manifest_copy" ] && verify_manifest "$target" "$manifest_copy" || true
        else
            echo "✗ Would have conflicts:"
            git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/  /'
            git cherry-pick --abort 2>/dev/null || git cherry-pick --quit 2>/dev/null || true
        fi
        cd "$repo_root"
        rm -rf "$tmp" "$manifest_copy"
        return
    fi

    local new_branch="${target#v}-android-dev"
    if git rev-parse --verify "$new_branch" >/dev/null 2>&1; then
        echo "Branch $new_branch already exists. Delete it first or use a different target."
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
        echo "✗ Conflicts on:"
        git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/  /'
        echo ""
        echo "Resolve with:"
        echo "  edit conflicted files"
        echo "  git add <file>"
        echo "  git cherry-pick --continue"
        echo ""
        echo "Then, before trusting it:"
        echo "  scripts/android.sh verify $target"
        echo "  scripts/android.sh build --nocgo arm64"
        echo ""
        echo "Or abort:"
        echo "  git cherry-pick --abort"
        echo "  git checkout $original_branch"
        echo "  git branch -D $new_branch${squash:+ _update_tmp}"
        rm -f "$manifest_copy"
        exit 1
    fi

    [ -n "$squash" ] && git branch -q -D _update_tmp
    echo "✓ Cherry-pick прошёл, ветка: $new_branch"

    # Gate 1: is every patch still in there? git said "applied", which is not
    # the same claim.
    echo ""
    echo "Манифест:"
    if [ -f "$manifest_copy" ]; then
        if ! verify_manifest "$target" "$manifest_copy"; then
            echo ""
            echo "✗ Патч применился, но часть его отсутствует. Не собираю."
            echo "  Смотри список выше, восстанови куски, затем:"
            echo "    scripts/android.sh verify $target"
            rm -f "$manifest_copy"
            exit 1
        fi
    fi
    rm -f "$manifest_copy"

    # Gate 2: does it build? Advice that a human has to remember to follow is
    # not a gate, and this is the step that was skipped last time.
    if [ -n "$no_build" ]; then
        echo ""
        echo "! сборка пропущена (--no-build) — ветка НЕ проверена"
        echo "  scripts/android.sh build --nocgo arm64"
        return
    fi
    echo ""
    echo "Сборка android/arm64:"
    if ! "$0" build --nocgo arm64; then
        echo ""
        echo "✗ Не собирается на $target. Ветка $new_branch оставлена как есть."
        exit 1
    fi

    echo ""
    echo "✓ $target: патч на месте, собирается. Ты на ветке $new_branch."
    echo ""
    echo "Дальше — только руками:"
    echo "  на телефоне: вход под выдуманным именем отклоняется (H1),"
    echo "               shell@ получает свои группы (H2), HOME не каталог демона (H3)"
    echo "  git checkout $original_branch  — вернуться"
}

# --- Main ---

case "${1:-}" in
    build)    shift; cmd_build "$@" ;;
    check)    shift; cmd_check "$@" ;;
    compat)   shift; cmd_compat "$@" ;;
    update)   shift; cmd_update "$@" ;;
    manifest) shift; cmd_manifest "$@" ;;
    verify)   shift; cmd_verify "$@" ;;
    *)        echo "Usage: $0 {build|check|compat|update|manifest|verify} [options]"; exit 1 ;;
esac
