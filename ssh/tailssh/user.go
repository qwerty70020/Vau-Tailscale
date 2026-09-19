// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build linux || (darwin && !ios) || freebsd || openbsd || plan9

package tailssh

import (
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"go4.org/mem"
	"tailscale.com/envknob"
	"tailscale.com/hostinfo"
	"tailscale.com/util/lineiter"
	"tailscale.com/util/osuser"
	"tailscale.com/version/distro"
)

// userMeta is a wrapper around *user.User with extra fields.
type userMeta struct {
	user.User

	// loginShellCached is the user's login shell, if known
	// at the time of userLookup.
	loginShellCached string
}

// GroupIds returns the list of group IDs that the user is a member of.
func (u *userMeta) GroupIds() ([]string, error) {
	return osuser.GetGroupIds(&u.User)
}

// userLookup is like os/user.Lookup but it returns a *userMeta wrapper
// around a *user.User with extra fields.
func userLookup(username string) (*userMeta, error) {
	u, s, err := osuser.LookupByUsernameWithShell(username)
	if err != nil {
		return nil, err
	}

	return &userMeta{User: *u, loginShellCached: s}, nil
}

func (u *userMeta) LoginShell() string {
	if runtime.GOOS == "plan9" {
		return "/bin/rc"
	}
	if u.loginShellCached != "" {
		// This field should be populated on Linux, at least, because
		// func userLookup on Linux uses "getent" to look up the user
		// and that populates it.
		return u.loginShellCached
	}
	switch runtime.GOOS {
	case "darwin":
		// Note: /Users/username is key, and not the same as u.HomeDir.
		out, _ := exec.Command("dscl", ".", "-read", filepath.Join("/Users", u.Username), "UserShell").Output()
		// out is "UserShell: /bin/bash"
		s, ok := strings.CutPrefix(string(out), "UserShell: ")
		if ok {
			return strings.TrimSpace(s)
		}
	}
	if e := os.Getenv("SHELL"); e != "" {
		return e
	}
	return "/bin/sh"
}

// defaultPathTmpl specifies the default PATH template to use for new sessions.
//
// If empty, a default value is used based on the OS & distro to match OpenSSH's
// usually-hardcoded behavior. (see
// https://github.com/tailscale/tailscale/issues/5285 for background).
//
// The template may contain @{HOME} or @{PAM_USER} which expand to the user's
// home directory and username, respectively. (PAM is not used, despite the
// name)
var defaultPathTmpl = envknob.RegisterString("TAILSCALE_SSH_DEFAULT_PATH")

func defaultPathForUser(u *user.User) string {
	if s := defaultPathTmpl(); s != "" {
		return expandDefaultPathTmpl(s, u)
	}
	if runtime.GOOS == "plan9" {
		return "/bin"
	}
	isRoot := u.Uid == "0"
	switch distro.Get() {
	case distro.Debian, distro.Crostini:
		hi := hostinfo.New()
		if hi.Distro == "ubuntu" {
			// distro.Get's Debian includes Ubuntu. But see if it's actually Ubuntu.
			// Ubuntu doesn't empirically seem to distinguish between root and non-root for the default.
			// And it includes /snap/bin.
			return "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
		}
		if isRoot {
			return "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
		}
		return "/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games"
	case distro.NixOS:
		return defaultPathForUserOnNixOS(u)
	}
	if runtime.GOOS == "android" {
		// На Android немає жодного з Unix-каталогів, які називають типові
		// значення нижче: виміряно на Android 16 — існує лише /bin, і то як
		// симлінк на /system/bin, а /usr/bin, /usr/local/bin і /sbin відсутні.
		// Тож сесії працювали випадково, через той один симлінк.
		//
		// Кожен запис тут перевірено на існування на пристрої. /system/xbin і
		// /sbin вилучено саме тому, що їх немає, а root-інструментарій у
		// /data/adb/ksu/bin — бо PATH сесії не місце для нього; та сама логіка,
		// що й у H5: що виконує root, не має вирішувати каталог, який може
		// наповнити хтось інший.
		sys := "/system/bin:/system_ext/bin:/vendor/bin:/apex/com.android.art/bin:/apex/com.android.runtime/bin"
		// Власний bin-каталог застосунку йде першим, коли сесія належить цьому
		// застосунку: вхід під uid термінального застосунку має знаходити
		// інструменти, які той установив, точно як його власна оболонка.
		// Каталог виводиться з дому, який lookup уже резолвив, тож менеджер
		// пакетів не питають двічі. Додається лише для сесії ЦЬОГО uid —
		// ніколи для root, чий PATH не має містити нічого, куди може писати
		// не-root uid.
		if strings.HasPrefix(u.HomeDir, "/data/data/") && !isRoot {
			if root, ok := strings.CutSuffix(u.HomeDir, "/files/home"); ok {
				if bin := root + "/files/usr/bin"; dirExists(bin) {
					return bin + ":" + sys
				}
			}
		}
		return sys
	}
	if isRoot {
		return "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	}
	return "/usr/local/bin:/usr/bin:/bin"
}

func defaultPathForUserOnNixOS(u *user.User) string {
	for lr := range lineiter.File("/etc/pam/environment") {
		lineb, err := lr.Value()
		if err != nil {
			return ""
		}
		if v := pathFromPAMEnvLine(lineb, u); v != "" {
			return v
		}
	}
	return ""
}

func pathFromPAMEnvLine(line []byte, u *user.User) (path string) {
	if !mem.HasPrefix(mem.B(line), mem.S("PATH")) {
		return ""
	}
	rest := strings.TrimSpace(strings.TrimPrefix(string(line), "PATH"))
	if quoted, ok := strings.CutPrefix(rest, "DEFAULT="); ok {
		if path, err := strconv.Unquote(quoted); err == nil {
			return expandDefaultPathTmpl(path, u)
		}
	}
	return ""
}

func expandDefaultPathTmpl(t string, u *user.User) string {
	p := strings.NewReplacer(
		"@{HOME}", u.HomeDir,
		"@{PAM_USER}", u.Username,
	).Replace(t)
	if strings.Contains(p, "@{") {
		// If there are unknown expansions, conservatively fail closed.
		return ""
	}
	return p
}

func dirExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}
