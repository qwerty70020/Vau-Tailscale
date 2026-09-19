// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package tsconst

// Linux firewall constants used by Tailscale.

// The following bits are added to packet marks for Tailscale use.
//
// We tried to pick bits sufficiently out of the way that it's
// unlikely to collide with existing uses. We have 4 bytes of mark
// bits to play with. We leave the lower byte alone on the assumption
// that sysadmins would use those. Kubernetes uses a few bits in the
// second byte, so we steer clear of that too.
//
// Довідка: https://www.kxxt.dev/blog/full-tailscale-on-android-and-remote-unlocking/
// Розподіл fwmark в AOSP:
// https://android.googlesource.com/platform/system/netd/+/master/include/Fwmark.h
//
// Нижні біти 0–20 Android уже зайняв. Біти 21–28 наразі вільні.
// Tailscale бере біти 25–28 і додатково ставить біт 17 (ProtectedFromVPN).
//
// The constants are in the iptables/iproute2 string format for
// matching and setting the bits, so they can be directly embedded in
// commands.
const (
	// The mask for reading/writing the 'firewall mask' bits on a packet.
	// Забираємо біти 25:28 цілком.
	LinuxFwmarkMask    = "0x1e000000"
	LinuxFwmarkMaskNum = 0x1e000000

	// Packet is from Tailscale and to a subnet route destination, so
	// is allowed to be routed through this machine.
	LinuxSubnetRouteMark    = "0x8000000"
	LinuxSubnetRouteMarkNum = 0x8000000

	// Packet was originated by tailscaled itself, and must not be
	// routed over the Tailscale network.
	// Містить біт 17 (0x20000) ProtectedFromVPN, щоб обійти VPN-маршрутизацію Android.
	LinuxBypassMark    = "0x10020000"
	LinuxBypassMarkNum = 0x10020000
)
