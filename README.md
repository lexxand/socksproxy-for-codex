## Что это
`proxy.sh` — интерактивный shell-скрипт для управления прокси-схемой через `Privoxy` и настройки прокси для:
- VS Code Server (Remote-SSH);
- CLI-среды (`npm + Codex CLI`).

Скрипт рассчитан на Debian/Ubuntu и автоматизирует типовые шаги, чтобы не настраивать вручную `Privoxy`, `settings.json` VS Code и shell-переменные окружения.

---

## Для чего нужен
Скрипт полезен, когда:
- серверу нужен upstream SOCKS5-прокси для доступа в интернет;
- VS Code Server должен работать через локальный HTTP bridge `127.0.0.1:8118`;
- для `codex` и `npm` нужно быстро включать/выключать прокси (временно или постоянно).

---

## Как запустить
Скрипт требует `root`.

```bash
sudo bash /home/lexxand/proxy.sh
```

После запуска откроется цветное интерактивное меню.

---

## Пункты меню

### 1) Установить прокси (Privoxy + VS Code)
Что делает:
- устанавливает пакеты (`privoxy`, `curl`, `python3`) через `apt`;
- пишет конфиг `/etc/privoxy/config` с `forward-socks5`;
- включает/перезапускает сервис `privoxy`;
- записывает proxy-настройки в VS Code Server `settings.json`.

Результат:
- VS Code ходит через `http://127.0.0.1:8118`.

### 2) Удалить прокси (Privoxy + VS Code)
Что делает:
- возвращает чистый конфиг Privoxy;
- останавливает/отключает сервис `privoxy`;
- удаляет proxy-поля из VS Code `settings.json`.

### 3) Установить прокси для npm + Codex CLI
Перед установкой предлагает режим:
- `temporary` — до перезагрузки;
- `permanent` — сохраняется для пользователя.

Что делает:
- не трогает upstream-логин/пароль напрямую в shell;
- выставляет переменные для CLI через локальный bridge:
  - `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`
  - `NPM_CONFIG_PROXY`, `NPM_CONFIG_HTTPS_PROXY`
- добавляет source-строки в `~/.bashrc`.

### 4) Удалить прокси для npm + Codex CLI
Что делает:
- удаляет профиль `npm+cli` (временный/постоянный);
- при отсутствии профилей убирает source-строки из `~/.bashrc`.

### 5) Проверить текущие настройки
Показывает:
- состояние `privoxy`;
- установлен ли upstream SOCKS5 в `/etc/privoxy/config`;
- proxy в VS Code;
- типы прокси: `VS Code`, `npm`, `npm+cli`;
- режим shell-профиля: `temporary`/`permanent`;
- bridge-check через `curl -x http://127.0.0.1:8118 https://api.openai.com`.

### 6) Выход
Завершает скрипт.

---

## Принцип работы (коротко)

1. **Upstream SOCKS5** хранится в `Privoxy`:
- `/etc/privoxy/config`
- строка вида: `forward-socks5 / login:password@host:port .`

2. **Локальный bridge**:
- `Privoxy` слушает `127.0.0.1:8118` (HTTP proxy).

3. **VS Code**:
- получает `http.proxy = http://127.0.0.1:8118`.

4. **CLI (`npm + codex`)**:
- использует те же локальные адреса через переменные окружения.

Идея: чувствительные данные upstream-прокси остаются в `Privoxy`, а CLI/VS Code работает через локальный bridge.

---

## Временный и постоянный режим

### Temporary
- файл профиля: `/run/codex-proxy/<user>.env`
- исчезает после reboot.

### Permanent
- файл профиля: `~/.config/codex-proxy.env`
- сохраняется между перезагрузками.

### `.bashrc`
Скрипт добавляет source-строки с маркерами:
- `# codex-proxy-temp`
- `# codex-proxy-perm`

После установки в текущей сессии:

```bash
source ~/.bashrc
```

---

## Что важно помнить
- Скрипт рассчитан на Linux Debian/Ubuntu (`apt-get`).
- Для изменения окружения конкретного пользователя используется авто-определение пользователя (`TARGET_USER` / `SUDO_USER`).
- Если VS Code не подхватил изменения — перезапусти VS Code Server (Remote-SSH).

---

## Быстрая диагностика

Проверка сервиса:
```bash
systemctl status privoxy --no-pager -l
journalctl -u privoxy -n 100 --no-pager
```

Проверка bridge вручную:
```bash
curl -v -x http://127.0.0.1:8118 https://api.openai.com
```

Проверка активных переменных в shell:
```bash
env | grep -Ei 'proxy|no_proxy'
```

---

## Безопасность
- Upstream строка содержит секреты (`login:password`), скрипт в статусе показывает её в маскированном виде.
- Не публикуй полный `/etc/privoxy/config` в общий доступ.
