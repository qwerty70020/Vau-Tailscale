// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package osuser

import (
	"context"
	"fmt"
	"os/exec"
	"os/user"
	"runtime"
	"strings"
	"time"

	"tailscale.com/version/distro"
)

// GetGroupIds returns the list of group IDs that the user is a member of, or
// an error. It will first try to use the 'id' command to get the group IDs,
// and if that fails, it will fall back to the user.GroupIds method.
func GetGroupIds(user *user.User) ([]string, error) {
	if runtime.GOOS == "android" {
		// Two bugs lived in these three lines. `id -Gz` does not exist on
		// Android at all (toybox: "Unknown option 'z'", verified on Android 16),
		// and the command was run without a username, so it answered for the
		// DAEMON — every SSH session got root's groups instead of the user's.
		// The fallback then returned a hardcoded {"0"}, quietly granting group
		// root to whoever asked.
		//
		// Groups are an Android app's identity: without 3003 (inet) a session
		// has no network at all, and without 1077/1079 it cannot see /sdcard.
		// Getting them silently wrong is worse than failing, so failure is
		// returned to the caller.
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		who := user.Username
		if who == "" {
			who = user.Uid
		}
		out, err := exec.CommandContext(ctx, "/system/bin/id", "-G", who).Output()
		if err != nil {
			return nil, fmt.Errorf("running 'id -G %s': %w", who, err)
		}
		ids := parseGroupIds(out)
		if len(ids) == 0 {
			return nil, fmt.Errorf("'id -G %s' returned no groups", who)
		}
		return ids, nil
	}

	if runtime.GOOS == "plan9" {
		return nil, nil
	}

	if runtime.GOOS != "linux" && runtime.GOOS != "freebsd" {
		return user.GroupIds()
	}

	if distro.Get() == distro.Gokrazy {
		// Gokrazy is a single-user appliance with ~no userspace.
		// There aren't users to look up (no /etc/passwd, etc)
		// so rather than fail below, just hardcode root.
		// TODO(bradfitz): fix os/user upstream instead?
		return []string{"0"}, nil
	}

	if ids, err := getGroupIdsWithId(user.Username); err == nil {
		return ids, nil
	}
	return user.GroupIds()
}

func getGroupIdsWithId(usernameOrUID string) ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "id", "-Gz", usernameOrUID)
	if runtime.GOOS == "freebsd" {
		cmd = exec.CommandContext(ctx, "id", "-G", usernameOrUID)
	}

	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("running 'id' command: %w", err)
	}

	return parseGroupIds(out), nil
}

func parseGroupIds(cmdOutput []byte) []string {
	s := strings.TrimSpace(string(cmdOutput))
	// Parse NUL-delimited output.
	if strings.ContainsRune(s, '\x00') {
		return strings.Split(strings.Trim(s, "\x00"), "\x00")
	}
	// Parse whitespace-delimited output.
	return strings.Fields(s)
}
