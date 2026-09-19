//go:build android

package osuser

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"time"
)

func init() {
	overrideLookupFunc = androidLookup
}

// Абсолютний шлях навмисно. tailscaled на цій платформі працює як root, а пошук
// через PATH дозволив би власнику будь-якого каталогу в PATH обирати, який
// бінарник виконає root — на телефоні цей PATH легко може бути префіксом
// термінального застосунку.
const idBin = "/system/bin/id"

// Єдина оболонка, яку Android гарантовано постачає і яка існує ще до першого
// розблокування власником. Приємніша оболонка для кожного користувача (bash
// термінального застосунку для app-uid) потребує роботи над per-user
// середовищем, що ведеться як H3/C4 у docs/vau/AUDIT.md; брати її з PATH —
// саме те, про що H5.
const defaultShell = "/system/bin/sh"

// androidLookup резолвить користувача через команду `id`, бо на Android немає
// ні getent, ні /etc/passwd.
//
// Невідоме ім'я — це ПОМИЛКА, ніколи не запасний варіант. Tailscale SSH бере
// локального користувача, яким може стати peer, з політики tailnet; якби
// нерозв'язне ім'я тихо ставало власною ідентичністю демона, кожен запис
// `users` у тій політиці фактично читався б як "root". Саме так цей код колись
// і робив — його fallback запускав `id -u`, тобто «хто я», бо старий помічник
// трактував останній аргумент як типове значення замість передати його команді.
func androidLookup(usernameOrUID string, wantShell bool) (*user.User, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	uid, err := idField(ctx, "-u", usernameOrUID)
	if err != nil {
		return nil, "", fmt.Errorf("osuser: unknown user %q: %w", usernameOrUID, err)
	}
	gid, err := idField(ctx, "-g", usernameOrUID)
	if err != nil {
		return nil, "", fmt.Errorf("osuser: no gid for user %q: %w", usernameOrUID, err)
	}
	// Запасний варіант допустимий лише для відображуваного імені: на цей момент
	// обліковий запис уже точно існує, тож у найгіршому разі покажемо ім'я,
	// яке нам передали.
	username, err := idField(ctx, "-un", usernameOrUID)
	if err != nil {
		username = usernameOrUID
	}

	var shell string
	if wantShell {
		shell = defaultShell
	}

	return &user.User{
		Uid:      uid,
		Gid:      gid,
		Username: username,
		Name:     "Android",
		HomeDir:  androidHomeDir(ctx, uid),
	}, shell, nil
}

// idField запускає `id <прапорець> <користувач>` і повертає обрізаний вивід.
// Ненульовий код виходу означає, що облікового запису не існує, і про це
// повідомляється, а не замовчується.
func idField(ctx context.Context, flag, usernameOrUID string) (string, error) {
	out, err := exec.CommandContext(ctx, idBin, flag, usernameOrUID).Output()
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(string(out))
	if v == "" {
		return "", fmt.Errorf("%s %s %q: empty output", idBin, flag, usernameOrUID)
	}
	return v, nil
}

// androidHomeDir повертає домашній каталог для uid.
//
// App-uid отримує дім власного застосунку — саме це робить можливою єдину точку
// входу по SSH: вхід під uid термінального застосунку приводить туди ж, куди
// і його власна оболонка. На Android немає per-user домашніх каталогів для
// простих AID, тож усі інші отримують "/" — будь-що інше означало б видати
// каталог, який сесія не може прочитати, як це колись робив власний HOME демона.
func androidHomeDir(ctx context.Context, uid string) string {
	if dir := appDataDirForUID(ctx, uid); dir != "" {
		if h := dir + "/files/home"; isDir(h) {
			return h
		}
	}
	if n, err := strconv.Atoi(uid); err == nil && n == os.Getuid() {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			return strings.TrimSpace(home)
		}
	}
	return "/"
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// appDataDirForUID повертає /data/data/<pkg> для app-uid Android або "".
//
// Питаємо менеджер пакетів, а не вгадуємо по файловій системі: app-uid
// призначаються під час встановлення і різняться між телефонами, тож нічого
// не можна зашивати. До першого розблокування власником саме ім'я каталогу
// зашифроване, і функція повертає "" — промах тут нормальний, не помилка, і
// той, хто викликає, відкочується до "/".
func appDataDirForUID(ctx context.Context, uid string) string {
	if n, err := strconv.Atoi(uid); err != nil || n < 10000 {
		return "" // не app-uid; системні AID не мають data-каталогу
	}
	out, err := exec.CommandContext(ctx, "/system/bin/pm", "list", "packages", "-U").Output()
	if err != nil {
		return ""
	}
	want := "uid:" + uid
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasSuffix(line, want) {
			continue
		}
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		pkg := strings.TrimPrefix(f[0], "package:")
		if pkg == "" {
			continue
		}
		if dir := "/data/data/" + pkg; isDir(dir) {
			return dir
		}
	}
	return ""
}
