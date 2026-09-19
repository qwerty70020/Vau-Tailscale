// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

//go:build android

package dns

import (
	"net/netip"
	"slices"
	"testing"
)

func TestParseDumpsysDNS(t *testing.T) {
	const dump = `Current per-App default networks:
  NetworkAgentInfo{ ni{[type: WIFI[], state: CONNECTED]} lp{{InterfaceName: wlan0 LinkAddresses: [ 192.168.1.20/24 ] DnsAddresses: [ /192.168.1.1,/2001:db8::1,/127.0.0.1,/100.100.100.100 ] Domains: null }} }
  NetworkAgentInfo{ ni{[type: MOBILE[LTE]]} lp{{InterfaceName: rmnet0 DnsAddresses: [ /10.0.0.1 ] }} }
`
	got := parseDumpsysDNS([]byte(dump))
	want := []netip.Addr{netip.MustParseAddr("192.168.1.1"), netip.MustParseAddr("2001:db8::1")}
	if !slices.Equal(got, want) {
		t.Errorf("parseDumpsysDNS = %v, want %v", got, want)
	}
	if got := parseDumpsysDNS([]byte("no dns here")); got != nil {
		t.Errorf("parseDumpsysDNS(no match) = %v, want nil", got)
	}
}
