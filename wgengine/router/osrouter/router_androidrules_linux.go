// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build linux

// Ім'я файлу навмисне не закінчується на _android: Go тоді вважав би його
// android-only і виключив би з linux-збірки, а тут потрібні обидві — правила
// вмикаються лише за runtime.GOOS == "android".

package osrouter

import (
	"sync/atomic"

	"github.com/tailscale/netlink"
	"tailscale.com/net/netmon"
	"tailscale.com/tsconst"
)

// androidUplinkTable — таблиця маршрутизації мережі, яку netd зараз вважає
// «за замовчуванням» (wlan0 → 1023, rmnet → 1019 …). 0 = невідомо.
// Оновлюється в refreshAndroidUplinkTable при кожній зміні мережі, тож
// exit-node продовжує працювати після перемикання Wi-Fi ↔ LTE (AUDIT M6).
var androidUplinkTable atomic.Int32

// androidIPRules — policy-routing для Android замість baseIPRules.
//
// Upstream-набір (5210 bypass→main, 5230 →default, 5250 unreachable, 5270 →52)
// написаний для Linux, де default-маршрут лежить у main. На Android main
// порожня, а маршрути кожної мережі netd тримає в окремих таблицях і обирає
// їх власними правилами з пріоритетами 10000–32000. Тому наші правила мають
// (а) не ловити маркований bypass-трафік демона — він має впасти в правила
// netd; (б) для решти — спершу подивитися в table 52 (tailnet, підмережі
// пірів, маршрут exit-node); (в) трафік, що ПРИЙШОВ із tailscale0 і не
// знайшов адресата в 52 (ми — exit-node), відправити в таблицю uplink'у,
// бо правило netd «fwmark 0x0/0xffff iif lo» вимагає iif lo і форвард не
// пропустить.
//
// Пріоритети відносні до ipPolicyPrefBase (5200): 7300 → 12500 (між
// 12000 «iif <vpn> lookup local_network» і 13000 «uidrange → tun»),
// 7801 → 13001.
func androidIPRules() []netlink.Rule {
	rules := []netlink.Rule{
		{
			Priority: 7300,
			Invert:   true,
			Mark:     tsconst.LinuxBypassMarkNum,
			Table:    tailscaleRouteTable.Num,
		},
	}
	if t := int(androidUplinkTable.Load()); t > 0 {
		rules = append(rules, netlink.Rule{
			Priority: 7801,
			Mark:     tsconst.LinuxSubnetRouteMarkNum,
			Table:    t,
		})
	}
	return rules
}

// refreshAndroidUplinkTable перечитує таблицю мережі за замовчуванням.
// Повертає true, якщо вона змінилася.
func (r *linuxRouter) refreshAndroidUplinkTable() bool {
	d, err := netmon.AndroidDefaultNetworkV4()
	if err != nil {
		if d6, err6 := netmon.AndroidDefaultNetworkV6(); err6 == nil {
			d, err = d6, nil
		}
	}
	old := androidUplinkTable.Load()
	if err != nil {
		r.logf("android: мережу за замовчуванням не визначено: %v", err)
		androidUplinkTable.Store(0)
		return old != 0
	}
	androidUplinkTable.Store(int32(d.Table))
	if int32(d.Table) != old {
		r.logf("android: uplink %s (table %d, gw %v)", d.IfName, d.Table, d.Gateway)
		return true
	}
	return false
}

// onAndroidNetworkChange — callback netmon: мережа змінилася — переставити
// правило 13001 на нову таблицю. Викликається поза r.mu.
func (r *linuxRouter) onAndroidNetworkChange(delta *netmon.ChangeDelta) {
	if !delta.DefaultInterfaceChanged && !delta.InterfaceIPsChanged {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.addIPRules(); err != nil {
		r.logf("android: не вдалося оновити ip rule після зміни мережі: %v", err)
	}
}
