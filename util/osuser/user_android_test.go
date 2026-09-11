// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package osuser

import (
	"os"
	"os/user"
	"slices"
	"strconv"
	"testing"
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
