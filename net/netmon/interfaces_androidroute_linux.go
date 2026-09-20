// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build linux

package netmon

import (
	"errors"
	"fmt"
	"net"

	"github.com/jsimonetti/rtnetlink"
	"github.com/wlynxg/anet"
	"golang.org/x/sys/unix"
)

// AndroidDefaultNetwork описує мережу, яку netd зараз вважає «за
// замовчуванням» (Wi-Fi чи мобільна) — ту, куди Android відправляє трафік
// без явно обраної мережі.
type AndroidDefaultNetwork struct {
	Table   int    // таблиця маршрутизації цієї мережі (наприклад, 1023 для wlan0)
	IfName  string // інтерфейс маршруту за замовчуванням у цій таблиці
	IfIndex int
	Gateway net.IP
}

var errNoAndroidDefaultNetwork = errors.New("android: мережу за замовчуванням не знайдено")

// androidDefaultNetwork знаходить мережу за замовчуванням так, як це робить
// сам Android, а не Linux-евристиками.
//
// На Android таблиця main порожня: netd тримає маршрути кожної мережі в
// окремій таблиці (wlan0 → 1023, rmnet → 1019 …) і обирає активну правилом
//
//	from all fwmark 0x0/0xffff iif lo lookup <таблиця>
//
// (netId 0 у молодших 16 бітах мітки = «мережа за замовчуванням»). Тому
// /proc/net/route і дамп таблиці main дають порожній результат, а перебір усіх
// таблиць повертає й `default dev dummy0`, і таблицю чужого VPN. Читаємо
// саме це правило, а вже з його таблиці — маршрут за замовчуванням.
//
// Ім'я інтерфейсу беремо через anet: net.InterfaceByIndex ходить у
// RTM_GETLINK, який SELinux на Android не дозволяє навіть root-у.
func androidDefaultNetwork(family uint8) (AndroidDefaultNetwork, error) {
	var d AndroidDefaultNetwork
	c, err := rtnetlink.Dial(nil)
	if err != nil {
		return d, fmt.Errorf("androidDefaultNetwork: Dial: %w", err)
	}
	defer c.Close()

	rules, err := c.Rule.List()
	if err != nil {
		return d, fmt.Errorf("androidDefaultNetwork: Rule.List: %w", err)
	}
	var table uint32
	for _, r := range rules {
		a := r.Attributes
		if r.Family != family || a.FwMask == nil || a.Table == nil || a.IIFName == nil {
			continue
		}
		// Ядро не надсилає FRA_FWMARK, коли mark == 0 (лише маску), тому
		// відсутній атрибут і є «fwmark 0x0».
		if a.FwMark != nil && *a.FwMark != 0 {
			continue
		}
		if *a.FwMask == 0xffff && *a.IIFName == "lo" && *a.Table != 0 {
			table = *a.Table
			break
		}
	}
	if table == 0 {
		return d, errNoAndroidDefaultNetwork
	}

	routes, err := c.Route.List()
	if err != nil {
		return d, fmt.Errorf("androidDefaultNetwork: Route.List: %w", err)
	}
	for _, rm := range routes {
		a := rm.Attributes
		if rm.Family != family || a.Table != table || a.Dst != nil || a.Gateway == nil || a.OutIface == 0 {
			continue
		}
		d.Table = int(table)
		d.IfIndex = int(a.OutIface)
		d.Gateway = a.Gateway
		d.IfName = androidIfNameByIndex(d.IfIndex)
		if d.IfName == "" {
			return d, fmt.Errorf("androidDefaultNetwork: інтерфейс з індексом %d не знайдено", d.IfIndex)
		}
		return d, nil
	}
	return d, errNoAndroidDefaultNetwork
}

func androidIfNameByIndex(idx int) string {
	ifs, err := anet.Interfaces()
	if err != nil {
		if iface, err := net.InterfaceByIndex(idx); err == nil {
			return iface.Name
		}
		return ""
	}
	for _, i := range ifs {
		if i.Index == idx {
			return i.Name
		}
	}
	return ""
}

// AndroidDefaultNetworkV4 — публічний доступ для роутера: йому потрібен номер
// таблиці, щоб спрямувати туди трафік, що приходить із tailscale0
// (роль exit-node / subnet-router).
func AndroidDefaultNetworkV4() (AndroidDefaultNetwork, error) {
	return androidDefaultNetwork(unix.AF_INET)
}

// AndroidDefaultNetworkV6 — те саме для IPv6.
func AndroidDefaultNetworkV6() (AndroidDefaultNetwork, error) {
	return androidDefaultNetwork(unix.AF_INET6)
}

// androidDefaultRoute — заміна defaultRoute() для Android.
func androidDefaultRoute() (DefaultRouteDetails, error) {
	d, err := androidDefaultNetwork(unix.AF_INET)
	if err != nil {
		if d6, err6 := androidDefaultNetwork(unix.AF_INET6); err6 == nil {
			d, err = d6, nil
		}
	}
	if err != nil {
		return DefaultRouteDetails{}, err
	}
	return DefaultRouteDetails{InterfaceName: d.IfName, InterfaceIndex: d.IfIndex}, nil
}
