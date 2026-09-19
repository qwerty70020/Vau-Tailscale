// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build android

package dns

import (
	"path/filepath"

	"tailscale.com/paths"
)

// Vau: на Android немає /etc/resolv.conf, до якого можна писати, тому
// «resolv.conf» і його резервна копія живуть у власному каталозі демона.
// Реально їх торкається лише directManager, якого androidManager не
// використовує; шляхи потрібні, щоб пакет збирався з тим самим кодом.
var (
	resolvConf string
	backupConf string
)

func init() {
	dnsDir := filepath.Join(paths.AndroidBaseDir(), "etc")
	resolvConf = filepath.Join(dnsDir, "resolv.conf")
	backupConf = filepath.Join(dnsDir, "resolv.pre-tailscale-backup.conf")
}
