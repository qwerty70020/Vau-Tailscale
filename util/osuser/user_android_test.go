// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package osuser

import (
	"context"
	"os"
	"os/user"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Not a valid Android AID name and not an installed package, so `id` must fail
// on it. The point of the test is what happens then.
const noSuchAndroidUser = "no-such-user-vau-test"

// A Tailscale SSH policy says which local users a peer may log in as. On this
// platform that promise is only worth what the lookup does with a name it does
// not know: resolving it to the daemon's own identity turns every `users` entry
// into "root" and makes the policy fiction.
func TestAndroidLookupRejectsUnknownUser(t *testing.T) {
	u, _, err := LookupByUsernameWithShell(noSuchAndroidUser)
	if err == nil {
		t.Fatalf("unknown user %q resolved to uid=%q gid=%q username=%q instead of failing",
			noSuchAndroidUser, u.Uid, u.Gid, u.Username)
	}
}

func TestAndroidLookupKnownUsers(t *testing.T) {
	for _, tt := range []struct{ name, wantUID string }{
		{"root", "0"},
		{"shell", "2000"}, // fixed AID on every Android build
	} {
		u, shell, err := LookupByUsernameWithShell(tt.name)
		if err != nil {
			t.Errorf("lookup(%q): unexpected error %v", tt.name, err)
			continue
		}
		if u.Uid != tt.wantUID {
			t.Errorf("lookup(%q): uid = %q, want %q", tt.name, u.Uid, tt.wantUID)
		}
		if u.Username != tt.name {
			t.Errorf("lookup(%q): username = %q, want %q", tt.name, u.Username, tt.name)
		}
		if shell == "" {
			t.Errorf("lookup(%q): empty shell", tt.name)
		}
	}
}

// The shell must be an absolute path inside the system image. Finding it on
// PATH lets a non-root uid that owns a PATH directory decide which binary root
// execs — on this phone the daemon's PATH could easily include a terminal app's
// own prefix (AUDIT H5).
func TestAndroidLoginShellIsNotUserWritable(t *testing.T) {
	_, shell, err := LookupByUsernameWithShell("root")
	if err != nil {
		t.Fatalf("lookup(root): %v", err)
	}
	if shell == "" || shell[0] != '/' {
		t.Fatalf("login shell %q is not an absolute path", shell)
	}
	inSystem := len(shell) >= 8 && shell[:8] == "/system/"
	inApex := len(shell) >= 6 && shell[:6] == "/apex/"
	if !inSystem && !inApex {
		t.Fatalf("login shell %q lives outside the system image: root exec'ing a binary a non-root uid can replace hands over the account", shell)
	}
	if _, err := os.Stat(shell); err != nil {
		t.Fatalf("login shell %q does not exist: %v", shell, err)
	}
}

// Groups must belong to the user being asked about, not to whoever is running.
// The Android branch used `id -Gz`, which toybox does not implement at all, and
// fell back to a hardcoded root group.
func TestAndroidGroupIdsBelongToTheAskedUser(t *testing.T) {
	got, err := GetGroupIds(&user.User{Username: "shell", Uid: "2000"})
	if err != nil {
		t.Fatalf("GetGroupIds(shell): %v", err)
	}
	if !slices.Contains(got, "2000") {
		t.Errorf("GetGroupIds(shell) = %v, want it to contain the shell gid 2000", got)
	}
	self := strconv.Itoa(os.Getuid())
	if self != "2000" && slices.Contains(got, self) {
		t.Errorf("GetGroupIds(shell) = %v, which contains the CALLER's own id %s — the username was ignored", got, self)
	}
}

// The package manager may only be asked about app uids. Root's is the login
// that has to work during early boot, before the system server can answer a
// binder call at all: sending uid 0 down this path would spend the whole lookup
// budget on a call that cannot complete, and the thing it would break is the
// only way back into the phone.
func TestAndroidAppDataDirIgnoresSystemUIDs(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, uid := range []string{"0", "1000", "2000", "9999", "", "root"} {
		start := time.Now()
		got := appDataDirForUID(ctx, uid)
		elapsed := time.Since(start)
		if got != "" {
			t.Errorf("appDataDirForUID(%q) = %q, want empty: no system uid owns an app data dir", uid, got)
		}
		// One `pm list packages -U` measured ~120ms on this handset, so
		// returning this fast is evidence the uid was rejected before the exec,
		// rather than by the package manager having nothing to report.
		if elapsed > 50*time.Millisecond {
			t.Errorf("appDataDirForUID(%q) took %v — the uid must be rejected without asking the package manager", uid, elapsed)
		}
	}
}

// Root's home must stay out of /data/data. That storage is credential
// encrypted and unreadable until the owner's first unlock — exactly the window
// in which the root session has to work.
func TestAndroidRootHomeIsReadableBeforeUnlock(t *testing.T) {
	u, _, err := LookupByUsernameWithShell("root")
	if err != nil {
		t.Fatalf("lookup(root): %v", err)
	}
	if strings.HasPrefix(u.HomeDir, "/data/data/") {
		t.Fatalf("root HomeDir = %q, which is CE storage: unreadable until the first unlock", u.HomeDir)
	}
}

// The other half: an app uid gets its own app's home instead of "/", which is
// what makes a single SSH entry point enough. Runs against whatever uid the
// tests run as, and skips when that is not an app.
func TestAndroidAppUIDGetsItsOwnHome(t *testing.T) {
	self := os.Getuid()
	if self < 10000 {
		t.Skipf("tests run as uid %d, which is not an app uid", self)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	home := androidHomeDir(ctx, strconv.Itoa(self))
	if !strings.HasPrefix(home, "/data/data/") || !strings.HasSuffix(home, "/files/home") {
		t.Fatalf("androidHomeDir(%d) = %q, want the app's own <data dir>/files/home", self, home)
	}
	if fi, err := os.Stat(home); err != nil || !fi.IsDir() {
		t.Fatalf("androidHomeDir(%d) = %q, which is not a directory (err %v)", self, home, err)
	}
}
