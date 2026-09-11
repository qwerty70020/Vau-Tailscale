//go:build android

package osuser

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"time"
)

func init() {
	overrideLookupFunc = androidLookup
}

// Absolute on purpose. tailscaled runs as root on this platform, and a PATH
// lookup would let whoever owns a directory on PATH choose which binary root
// executes — on a phone that PATH can easily be a terminal app's own prefix.
const idBin = "/system/bin/id"

// The only shell Android is guaranteed to ship, and one that exists before the
// owner's first unlock. A nicer per-user shell (a terminal app's bash for an
// app uid) needs the per-user environment work tracked as H3/C4 in
// docs/vau/AUDIT.md; picking it up from PATH is what H5 is about.
const defaultShell = "/system/bin/sh"

// androidLookup resolves a user through the `id` command, because Android has
// neither getent nor /etc/passwd.
//
// An unknown name is an ERROR, never a fallback. Tailscale SSH takes the local
// user a peer may become from the tailnet policy; if an unresolvable name
// quietly became the daemon's own identity, every `users` entry in that policy
// would effectively read "root". That is what this code used to do — its
// fallback ran `id -u`, i.e. "who am I", because the old helper treated the
// last argument as a default value instead of passing it to the command.
func androidLookup(usernameOrUID string, wantShell bool) (*user.User, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	uid, err := idField(ctx, "-u", usernameOrUID)
	if err != nil {
		return nil, "", fmt.Errorf("osuser: unknown user %q: %w", usernameOrUID, err)
	}
	gid, err := idField(ctx, "-g", usernameOrUID)
	if err != nil {
		return nil, "", fmt.Errorf("osuser: no gid for user %q: %w", usernameOrUID, err)
	}
	// Only the display name may fall back: by this point the account is known
	// to exist, so the worst case is showing the name we were handed.
	username, err := idField(ctx, "-un", usernameOrUID)
	if err != nil {
		username = usernameOrUID
	}

	var shell string
	if wantShell {
		shell = defaultShell
	}

	return &user.User{
		Uid:      uid,
		Gid:      gid,
		Username: username,
		Name:     "Android",
		HomeDir:  androidHomeDir(uid),
	}, shell, nil
}

// idField runs `id <flag> <user>` and returns its trimmed output. A non-zero
// exit means the account does not exist, and that is reported rather than
// papered over.
func idField(ctx context.Context, flag, usernameOrUID string) (string, error) {
	out, err := exec.CommandContext(ctx, idBin, flag, usernameOrUID).Output()
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(string(out))
	if v == "" {
		return "", fmt.Errorf("%s %s %q: empty output", idBin, flag, usernameOrUID)
	}
	return v, nil
}

// androidHomeDir returns a home directory for uid. Android has no per-user home
// directories for AIDs, so anyone other than the calling process gets "/".
// Handing the daemon's own HOME to every session is how an SSH login as an app
// uid ended up pointed at root's directory.
func androidHomeDir(uid string) string {
	if n, err := strconv.Atoi(uid); err == nil && n == os.Getuid() {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			return strings.TrimSpace(home)
		}
	}
	return "/"
}
