//go:build android

package hostinfo

import (
	"os/exec"
	"strings"

	"tailscale.com/tailcfg"
)

func init() {
	RegisterHostinfoNewHook(func(hi *tailcfg.Hostinfo) {
		// Замінити узагальнене "node" чи "localhost" на осмислене Android-ім'я
		if hi.Hostname == "node" || hi.Hostname == "localhost" {
			hi.Hostname = sanitizeHostname(
				getSystemProperty("ro.product.manufacturer") + "-" +
					getSystemProperty("ro.product.model"),
			)
			if hi.Hostname == "" {
				hi.Hostname = "android"
			}
		}

		// Задати OSVersion, якщо ще не задано
		if hi.OSVersion == "" {
			hi.OSVersion = getSystemProperty("ro.build.version.release")
		}

		// Переконатися, що модель пристрою заповнена
		if hi.DeviceModel == "" {
			hi.DeviceModel = getSystemProperty("ro.product.model")
		}
	})
}

// getSystemProperty читає системні властивості Android через команду getprop.
// Абсолютний шлях навмисно: демон працює як root і не має шукати помічників
// через будь-який PATH, з яким його запустили (docs/vau/AUDIT.md, H5).
func getSystemProperty(prop string) string {
	out, err := exec.Command("/system/bin/getprop", prop).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// sanitizeHostname прибирає з імені хоста недопустимі символи.
// Коректне ім'я хоста містить лише літери/цифри та дефіси.
func sanitizeHostname(s string) string {
	s = strings.ToLower(s)
	var result strings.Builder

	for _, ch := range s {
		switch {
		case (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9'):
			result.WriteRune(ch)
		case ch == '-' || ch == '_' || ch == ' ':
			// Пробіли й підкреслення перетворюємо на дефіси
			if result.Len() > 0 && result.String()[result.Len()-1] != '-' {
				result.WriteRune('-')
			}
		}
	}

	hostname := result.String()
	// Прибрати дефіси на початку/в кінці
	hostname = strings.Trim(hostname, "-")
	// Схлопнути повторні дефіси
	for strings.Contains(hostname, "--") {
		hostname = strings.ReplaceAll(hostname, "--", "-")
	}

	// Обмежити 63 символами (максимальна довжина мітки в імені хоста)
	if len(hostname) > 63 {
		hostname = hostname[:63]
		hostname = strings.TrimRight(hostname, "-")
	}

	return hostname
}
