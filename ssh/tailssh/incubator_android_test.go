// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

//go:build android

package tailssh

import (
	"testing"

	"tailscale.com/types/logger"
)

// Android has no login(1); the root daemon must never try to exec it, whatever
// the SELinux flag says (it is only passed on GOOS linux).
func TestShouldAttemptLoginShellAndroid(t *testing.T) {
	for _, ia := range []incubatorArgs{
		{isShell: true},
		{isShell: true, isSELinuxEnforcing: true},
		{isSFTP: true, forceV1Behavior: true},
	} {
		if shouldAttemptLoginShell(logger.Discard, ia) {
			t.Errorf("shouldAttemptLoginShell(%+v) = true on android, want false", ia)
		}
	}
}
