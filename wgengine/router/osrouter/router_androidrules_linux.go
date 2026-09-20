// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build linux

// Ім'я файлу навмисне не закінчується на _android: Go тоді вважав би його
// android-only і виключив би з linux-збірки, а тут потрібні обидві — правила
// вмикаються лише за runtime.GOOS == "android".

package osrouter

import (
	"errors"
	"fmt"
	"strconv"
	"sync/atomic"

	"github.com/tailscale/netlink"
	"tailscale.com/net/netmon"
	"tailscale.com/net/tsaddr"
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
// Три правила тут плюс uid-правило 12400 з androidUIDRules; пріоритети
// відносні до ipPolicyPrefBase (5200); перевірено на nord (Android 12) поруч
// із VPN офіційного застосунку (tun1):
//
//   - 7300 → 12500 «fwmark <subnet> iif lo lookup 52» — ВІДПОВІДІ нашого вузла.
//     ts-prerouting мітить усе вхідне з tailscale0 міткою subnet, а Android має
//     fwmark_reflect=1 і tcp_fwmark_accept=1, тож SYN-ACK/ICMP-reply/сокет
//     несуть ту саму мітку. Без цього правила відповідь ловить правило netd
//     13000 «fwmark 0x0/0x20000 iif lo uidrange … lookup tun1» (uid-less
//     відповіді ядра — overflowuid 65534, теж у діапазоні) і вона вилітає в
//     VPN застосунку з src нашої адреси — пір її відкидає. iif lo відсікає
//     форвард (у нього iif tailscale0).
//   - 11300 → 16500 «not fwmark <bypass> lookup 52» — усе немарковане.
//     Стоїть ПІСЛЯ 13000 (uid-правила VPN застосунку — поки той активний,
//     трафік до tailnet іде через нього, як і задумано користувачем) і ПІСЛЯ
//     16000 «fwmark 0x1006X/0x1ffff iif lo lookup X» — відповіді вузла
//     застосунку несуть відбиту мітку netd 0x30065 (routectrl_mangle_INPUT),
//     і саме 16000 повертає їх у tun1; на 12500 наше правило перехоплювало їх
//     у tailscale0, і вхідні з'єднання до Termux sshd :8022 висіли в SYN_RECV.
//     Bypass-трафік демона має біт 17 (0x20000, PROTECTED_FROM_VPN) і 13000
//     його не чіпає — він падає далі в netd 29000 → uplink.
//   - 11301 → 16501 «fwmark <subnet> lookup <uplink>» — форвард із tailscale0,
//     що не знайшов адресата в 52 (ми — exit-node).
func androidIPRules() []netlink.Rule {
	rules := []netlink.Rule{
		{
			// Відповіді нашого вузла (iif lo, відбита мітка) — у tailscale0,
			// раніше за uid-правила VPN застосунку.
			Priority: 7300,
			Mark:     tsconst.LinuxSubnetRouteMarkNum,
			IifName:  "lo",
			Table:    tailscaleRouteTable.Num,
		},
		{
			// Усе немарковане (і не bypass) — спершу table 52.
			Priority: 11300,
			Invert:   true,
			Mark:     tsconst.LinuxBypassMarkNum,
			Table:    tailscaleRouteTable.Num,
		},
	}
	if t := int(androidUplinkTable.Load()); t > 0 {
		rules = append(rules, netlink.Rule{
			// Форвард із tailscale0, що не знайшов адресата в 52 — в uplink.
			Priority: 11301,
			Mark:     tsconst.LinuxSubnetRouteMarkNum,
			Table:    t,
		})
	}
	return rules
}

// androidUIDRules ставить (add=true) або прибирає правило
// «12400: to <tailnet> uidrange 0-0 lookup 52» для v4 (100.64/10) і v6
// (fd7a:115c:a1e0::/48). Це трафік самого демона до пірів — форвардер DNS до
// tailnet-резолвера, peerapi, Taildrop: його сокети без мітки, і поки активний
// VPN застосунку, правило netd 13000 «uidrange 0-… lookup tun1» відправляло б
// їх у чужий тунель із src адреси tun1 (пір відкидає). Root у Android — лише
// система й наш демон, тож «root до tailnet → наш тунель» нікому не шкодить.
// Через `ip`, бо github.com/tailscale/netlink не вміє uidrange. Видалення
// best-effort: правила може ще не бути.
func (r *linuxRouter) androidUIDRules(add bool) error {
	verb := "del"
	if add {
		verb = "add"
	}
	pref := strconv.Itoa(7200 + r.ipPolicyPrefBase)
	var errAcc error
	for _, fam := range []struct{ flag, to string }{
		{"-4", tsaddr.CGNATRange().String()},
		{"-6", tsaddr.TailscaleULARange().String()},
	} {
		args := []string{"ip", fam.flag, "rule", verb, "pref", pref, "to", fam.to, "uidrange", "0-0", "table", strconv.Itoa(tailscaleRouteTable.Num)}
		if err := r.cmd.run(args...); err != nil && add {
			errAcc = errors.Join(errAcc, fmt.Errorf("android: %v: %w", args, err))
		}
	}
	return errAcc
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
