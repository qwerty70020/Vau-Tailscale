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
		// У цих трьох рядках жили два баги. `id -Gz` на Android не існує
		// взагалі (toybox: "Unknown option 'z'", перевірено на Android 16), а
		// команда запускалась без імені користувача, тож відповідала за
		// ДЕМОНА — кожна SSH-сесія отримувала групи root замість своїх.
		// Fallback потім повертав зашитий {"0"}, тихо видаючи групу root
		// будь-кому, хто спитав.
		//
		// Групи — це ідентичність Android-застосунку: без 3003 (inet) сесія
		// не має мережі взагалі, а без 1077/1079 не бачить /sdcard. Тихо
		// помилитися тут гірше, ніж впасти, тож помилка повертається тому,
		// хто викликав.
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
