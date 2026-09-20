// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

//go:build android

package dns

import (
	"bytes"
	"context"
	"fmt"
	"net/netip"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/coreos/go-iptables/iptables"
	"tailscale.com/control/controlknobs"
	"tailscale.com/health"
	"tailscale.com/net/tsaddr"
	"tailscale.com/tsconst"
	"tailscale.com/types/logger"
	"tailscale.com/util/eventbus"
	"tailscale.com/util/syspolicy/policyclient"
)

// androidManager — OS-конфігуратор DNS для рутованого телефону, на якому
// tailscaled працює зі справжнім tailscale0 (TUN_MODE=kernel у модулі). На
// Android немає resolv.conf, який можна редагувати, і resolved, з яким можна
// говорити; єдиний важіль — DNAT порту 53 у сервісну IP tailscale, де
// відповідає власний резолвер tailscaled (MagicDNS) або форвардить далі.
type androidManager struct {
	logf     logger.Logf
	tunName  string
	hijacked bool
}

func NewOSConfigurator(logf logger.Logf, _ *health.Tracker, _ *eventbus.Bus, _ policyclient.Client, _ *controlknobs.Knobs, tunName string) (OSConfigurator, error) {
	// tailscaled створює OS-конфігуратор і для userspace-networking, з порожнім
	// іменем інтерфейсу. Тоді немає tailscale0, у який можна перенаправити
	// порт 53, а модуль обіцяє «жодного iptables» у цьому режимі — тож без
	// інтерфейсу менеджер перехоплення не має існувати взагалі, інакше кожен
	// SetDNS усе одно форкав би iptables/ip6tables, щоб видалити правила, яких
	// ніколи не додавали.
	if tunName == "" {
		return NewNoopManager()
	}
	return &androidManager{logf: logf, tunName: tunName}, nil
}

func (m *androidManager) SetDNS(cfg OSConfig) error {
	shouldHijack := len(cfg.Nameservers) > 0

	if shouldHijack && !m.hijacked {
		if err := m.setDNSRules(false, true); err != nil {
			m.logf("dns: failed to setup rules: %v", err)
			return err
		}
		if err := m.setDNSRules(true, true); err != nil {
			m.logf("dns: ipv6 rules failed (non-fatal): %v", err)
		}
		m.hijacked = true
		m.logf("dns: hijack enabled on %s", m.tunName)
	} else if !shouldHijack && m.hijacked {
		m.removeRules()
	}
	return nil
}

func (m *androidManager) SupportsSplitDNS() bool {
	return false
}

// GetBaseConfig повертає резолвери, якими телефон користувався б без
// Tailscale, щоб імена поза MagicDNS усе ще резолвились, коли tailnet не
// задає глобального перевизначення. Порожня відповідь тут колись була
// знахідкою C2 у docs/vau/AUDIT.md: кожен запит поза tailnet отримував SERVFAIL.
func (m *androidManager) GetBaseConfig() (OSConfig, error) {
	ns, err := androidSystemResolvers()
	if err != nil {
		return OSConfig{}, err
	}
	return OSConfig{Nameservers: ns}, nil
}

func (m *androidManager) Close() error {
	if m.hijacked {
		m.removeRules()
	}
	return nil
}

func (m *androidManager) removeRules() {
	if err := m.setDNSRules(false, false); err != nil {
		m.logf("dns: failed to remove rules: %v", err)
	}
	if err := m.setDNSRules(true, false); err != nil {
		m.logf("dns: ipv6 rules removal failed (non-fatal): %v", err)
	}
	m.hijacked = false
	m.logf("dns: hijack disabled")
}

// setDNSRules встановлює (або прибирає) два DNAT-правила для одного сімейства.
func (m *androidManager) setDNSRules(ipv6 bool, add bool) error {
	proto := iptables.ProtocolIPv4
	dnsIP := tsaddr.TailscaleServiceIPString
	if ipv6 {
		proto = iptables.ProtocolIPv6
		dnsIP = tsaddr.TailscaleServiceIPv6String
	}

	ipt, err := iptables.NewWithProtocol(proto)
	if err != nil {
		return err
	}

	// Форвардер tailscaled ходить до upstream-резолверів через сокети з
	// bypass-міткою. Без цього винятку правило OUTPUT повертало ці запити
	// назад у сервісну IP — DNS-петля з AUDIT.md C3. Значення маскується
	// вручну: xt_mark порівнює (mark & mask) == value і ніколи не маскує
	// value, а біт 17 bypass-мітки лежить поза fwmark-маскою.
	bypass := fmt.Sprintf("0x%x/%s", tsconst.LinuxBypassMarkNum&tsconst.LinuxFwmarkMaskNum, tsconst.LinuxFwmarkMask)

	type rule struct {
		table string
		chain string
		args  []string
	}
	var rules []rule
	// І UDP, і TCP: netd після таймауту UDP повторює запит по TCP, і без
	// TCP-правила той повтор ішов повз тунель прямо в uplink (витік DNS).
	for _, proto := range []string{"udp", "tcp"} {
		rules = append(rules,
			// Власні запити телефону (netd), крім форвардера tailscaled.
			rule{"nat", "OUTPUT", []string{"-m", "mark", "!", "--mark", bypass, "!", "-o", m.tunName, "!", "-d", dnsIP, "-p", proto, "--dport", "53", "-j", "DNAT", "--to-destination", "[" + dnsIP + "]:53"}},
			// Клієнти точки доступу (tethering).
			rule{"nat", "PREROUTING", []string{"!", "-i", m.tunName, "-p", proto, "--dport", "53", "-j", "DNAT", "--to-destination", "[" + dnsIP + "]:53"}},
		)
	}
	if !ipv6 {
		for i := range rules {
			// IPv4 DNAT не приймає форму в квадратних дужках.
			rules[i].args[len(rules[i].args)-1] = dnsIP + ":53"
		}
	}

	for _, rule := range rules {
		if add {
			// Unique, а не Append: демон перезапускається без Close() щоразу,
			// як supervisor його вбиває, і кожен перезапуск колись додавав
			// другу копію кожного правила (AUDIT.md M1).
			if err := ipt.AppendUnique(rule.table, rule.chain, rule.args...); err != nil {
				return err
			}
		} else {
			ipt.Delete(rule.table, rule.chain, rule.args...)
		}
	}

	return nil
}

var dumpsysDNSRe = regexp.MustCompile(`DnsAddresses: \[([^\]]*)\]`)

// androidSystemResolvers повертає резолвери поточної типової мережі телефону.
// Android ≥ 8 більше не показує їх як властивості net.dnsN; єдине джерело,
// доступне root'у, — дамп самого connectivity-сервісу, чий перший блок
// LinkProperties і є типовою мережею.
func androidSystemResolvers() ([]netip.Addr, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/system/bin/dumpsys", "connectivity").Output()
	if err != nil {
		return nil, fmt.Errorf("dumpsys connectivity: %w", err)
	}
	return parseDumpsysDNS(out), nil
}

func parseDumpsysDNS(out []byte) []netip.Addr {
	m := dumpsysDNSRe.FindSubmatch(out)
	if m == nil {
		return nil
	}
	var addrs []netip.Addr
	for _, f := range bytes.Split(m[1], []byte(",")) {
		s := strings.TrimPrefix(strings.TrimSpace(string(f)), "/")
		a, err := netip.ParseAddr(s)
		if err != nil || a.IsLoopback() || tsaddr.IsTailscaleIP(a) {
			// Резолвер у tailnet був би петлею через DNAT.
			continue
		}
		addrs = append(addrs, a.Unmap())
	}
	return addrs
}
