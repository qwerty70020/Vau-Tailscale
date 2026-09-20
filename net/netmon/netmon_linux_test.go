// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build linux && !android

package netmon

import (
	"net"
	"net/netip"
	"testing"

	"github.com/jsimonetti/rtnetlink"
	"github.com/mdlayher/netlink"
	"golang.org/x/sys/unix"
)

func newAddrMsg(iface uint32, addr string, typ netlink.HeaderType) netlink.Message {
	ip := net.ParseIP(addr)
	if ip == nil {
		panic("newAddrMsg: invalid addr: " + addr)
	}

	addrMsg := rtnetlink.AddressMessage{
		Index: iface,
		Attributes: &rtnetlink.AddressAttributes{
			Address: ip,
		},
	}

	b, err := addrMsg.MarshalBinary()
	if err != nil {
		panic(err)
	}

	return netlink.Message{
		Header: netlink.Header{Type: typ},
		Data:   b,
	}
}

// See issue #4282 and nlConn.addrCache.
func TestIgnoreDuplicateNEWADDR(t *testing.T) {
	mustReceive := func(c *nlConn) message {
		msg, err := c.Receive()
		if err != nil {
			t.Fatalf("mustReceive: unwanted error: %s", err)
		}
		return msg
	}

	t.Run("suppress-duplicate-NEWADDRs", func(t *testing.T) {
		c := nlConn{
			buffered: []netlink.Message{
				newAddrMsg(1, "192.168.0.5", unix.RTM_NEWADDR),
				newAddrMsg(1, "192.168.0.5", unix.RTM_NEWADDR),
			},
			addrCache: make(map[uint32]map[netip.Addr]bool),
		}

		msg := mustReceive(&c)
		if _, ok := msg.(*newAddrMessage); !ok {
			t.Fatalf("want newAddrMessage, got %T %v", msg, msg)
		}

		msg = mustReceive(&c)
		if _, ok := msg.(ignoreMessage); !ok {
			t.Fatalf("want ignoreMessage, got %T %v", msg, msg)
		}
	})

	t.Run("no-suppress-after-DELADDR", func(t *testing.T) {
		c := nlConn{
			buffered: []netlink.Message{
				newAddrMsg(1, "192.168.0.5", unix.RTM_NEWADDR),
				newAddrMsg(1, "192.168.0.5", unix.RTM_DELADDR),
				newAddrMsg(1, "192.168.0.5", unix.RTM_NEWADDR),
			},
			addrCache: make(map[uint32]map[netip.Addr]bool),
		}

		msg := mustReceive(&c)
		if _, ok := msg.(*newAddrMessage); !ok {
			t.Fatalf("want newAddrMessage, got %T %v", msg, msg)
		}

		msg = mustReceive(&c)
		if m, ok := msg.(*newAddrMessage); !ok {
			t.Fatalf("want newAddrMessage, got %T %v", msg, msg)
		} else {
			if !m.Delete {
				t.Fatalf("want delete, got %#v", m)
			}
		}

		msg = mustReceive(&c)
		if _, ok := msg.(*newAddrMessage); !ok {
			t.Fatalf("want newAddrMessage, got %T %v", msg, msg)
		}
	})
}

func TestParseRuleDeleted(t *testing.T) {
	u32 := func(v uint32) *uint32 { return &v }
	tests := []struct {
		name string
		msg  rtnetlink.RuleMessage
		want RuleDeleted
	}{
		{
			name: "plain", // ip -4 rule del pref 5210 table main
			msg: rtnetlink.RuleMessage{
				Family: unix.AF_INET, Table: unix.RT_TABLE_MAIN, Action: unix.FR_ACT_TO_TBL,
				Attributes: &rtnetlink.RuleAttributes{Priority: u32(5210), Table: u32(unix.RT_TABLE_MAIN)},
			},
			want: RuleDeleted{Table: 254, Priority: 5210},
		},
		{
			// Android's netd installs per-uid rules; FRA_UID_RANGE
			// collides with RTA_PREF when misread as a route message.
			name: "uidrange",
			msg: rtnetlink.RuleMessage{
				Family: unix.AF_INET, Table: unix.RT_TABLE_COMPAT, Action: unix.FR_ACT_TO_TBL,
				Attributes: &rtnetlink.RuleAttributes{
					Priority: u32(13000), Table: u32(1027),
					UIDRange: &rtnetlink.RuleUIDRange{Start: 0, End: 10092},
				},
			},
			want: RuleDeleted{Table: unix.RT_TABLE_COMPAT, Priority: 13000},
		},
		{
			name: "no attributes",
			msg:  rtnetlink.RuleMessage{Family: unix.AF_INET, Table: 100, Action: unix.FR_ACT_TO_TBL},
			want: RuleDeleted{Table: 100},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			data, err := tt.msg.MarshalBinary()
			if err != nil {
				t.Fatal(err)
			}
			got, err := parseRuleDeleted(data)
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Errorf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}
