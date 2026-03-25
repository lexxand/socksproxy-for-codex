#!/usr/bin/env bash
set -euo pipefail

CFG="/etc/privoxy/config"
LOCAL_HTTP_PROXY="http://127.0.0.1:8118"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Запусти от root: sudo bash $0"
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  if ! need_cmd apt-get; then
    echo "Этот скрипт рассчитан на Debian/Ubuntu (apt-get)."
    exit 1
  fi

  apt-get update
  apt-get install -y privoxy curl python3
}

get_target_user() {
  if [[ -n "${TARGET_USER:-}" ]]; then
    echo "${TARGET_USER}"
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
    return
  fi

  echo "root"
}

get_user_home() {
  local user="$1"
  getent passwd "$user" | cut -d: -f6
}

get_vscode_settings_file() {
  local user="$1"
  local home
  home="$(get_user_home "$user")"
  echo "${home}/.vscode-server/data/Machine/settings.json"
}

backup_config() {
  if [[ -f "$CFG" ]]; then
    local backup="/etc/privoxy/config.bak.$(date +%F-%H%M%S)"
    cp -a "$CFG" "$backup"
    echo "Бэкап: $backup"
  fi
}

write_clean_privoxy_config() {
  cat > "$CFG" <<'EOF'
confdir /etc/privoxy
logdir /var/log/privoxy

listen-address  127.0.0.1:8118

toggle 1
enable-remote-toggle 0
enable-edit-actions 0
enable-remote-http-toggle 0

actionsfile match-all.action
actionsfile default.action
actionsfile user.action

filterfile default.filter
EOF

  chmod 644 "$CFG"
}

write_proxy_privoxy_config() {
  local proxy_raw="$1"

  cat > "$CFG" <<EOF
confdir /etc/privoxy
logdir /var/log/privoxy

listen-address  127.0.0.1:8118

toggle 1
enable-remote-toggle 0
enable-edit-actions 0
enable-remote-http-toggle 0

actionsfile match-all.action
actionsfile default.action
actionsfile user.action

filterfile default.filter

forward-socks5  /  ${proxy_raw} .
EOF

  chmod 644 "$CFG"
}

cleanup_old_env_proxy() {
  local user="$1"
  local home
  home="$(get_user_home "$user")"

  mkdir -p "${home}/.config"
  touch "${home}/.bashrc"

  sed -i '/codex-proxy\.env/d' "${home}/.bashrc" || true
  rm -f "${home}/.config/codex-proxy.env"

  chown -R "${user}:${user}" "${home}/.config" "${home}/.bashrc" 2>/dev/null || true
}

set_vscode_proxy_settings() {
  local user="$1"
  local settings_file
  settings_file="$(get_vscode_settings_file "$user")"

  mkdir -p "$(dirname "$settings_file")"

  python3 - <<PY
import json, os

p = os.path.expanduser("${settings_file}")
os.makedirs(os.path.dirname(p), exist_ok=True)

try:
    with open(p, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}

data["http.proxy"] = "${LOCAL_HTTP_PROXY}"
data["http.proxySupport"] = "override"
data["http.noProxy"] = ["127.0.0.1", "localhost", "::1"]

with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\\n")
PY

  chown -R "${user}:${user}" "$(dirname "$(dirname "$settings_file")")" 2>/dev/null || true

  echo "VS Code settings обновлены: $settings_file"
}

remove_vscode_proxy_settings() {
  local user="$1"
  local settings_file
  settings_file="$(get_vscode_settings_file "$user")"

  mkdir -p "$(dirname "$settings_file")"

  python3 - <<PY
import json, os

p = os.path.expanduser("${settings_file}")
if not os.path.exists(p):
    print("settings.json ещё не существует")
    raise SystemExit(0)

try:
    with open(p, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}

for key in ["http.proxy", "http.proxySupport", "http.noProxy"]:
    data.pop(key, None)

with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\\n")
PY

  chown -R "${user}:${user}" "$(dirname "$(dirname "$settings_file")")" 2>/dev/null || true

  echo "Proxy-настройки VS Code удалены: $settings_file"
}

mask_proxy_raw() {
  local raw="$1"

  if [[ "$raw" =~ ^([^:]+):([^@]+)@([^:]+):([0-9]+)$ ]]; then
    local login="${BASH_REMATCH[1]}"
    local host="${BASH_REMATCH[3]}"
    local port="${BASH_REMATCH[4]}"
    echo "${login}:********@${host}:${port}"
  else
    echo "$raw"
  fi
}

current_proxy_raw() {
  if [[ -f "$CFG" ]]; then
    local line
    line="$(grep -E '^[[:space:]]*forward-socks5[[:space:]]+/[[:space:]]+' "$CFG" | tail -n1 || true)"
    if [[ -n "$line" ]]; then
      echo "$line" | sed -E 's/^[[:space:]]*forward-socks5[[:space:]]+\/[[:space:]]+(.+)[[:space:]]+\.[[:space:]]*$/\1/'
      return 0
    fi
  fi
  return 1
}

check_bridge() {
  local http_code
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' -x "${LOCAL_HTTP_PROXY}" https://api.openai.com || true)"

  if [[ "$http_code" =~ ^[0-9]{3}$ ]] && [[ "$http_code" != "000" ]]; then
    echo "OK: bridge работает, api.openai.com ответил кодом $http_code"
    return 0
  fi

  echo "Bridge не подтвердился."
  echo "Проверь вручную:"
  echo "  curl -v -x ${LOCAL_HTTP_PROXY} https://api.openai.com"
  return 1
}

show_current_proxy() {
  local user
  user="$(get_target_user)"

  echo
  echo "Пользователь VS Code: $user"
  echo "Сервис privoxy: $(systemctl is-active privoxy 2>/dev/null || echo inactive)"

  local raw=""
  if raw="$(current_proxy_raw)"; then
    echo "Privoxy upstream proxy: $(mask_proxy_raw "$raw")"
  else
    echo "Privoxy upstream proxy: не установлен"
  fi

  local settings_file
  settings_file="$(get_vscode_settings_file "$user")"

  if [[ -f "$settings_file" ]]; then
    python3 - <<PY
import json
p = "${settings_file}"
try:
    with open(p, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}

proxy = data.get("http.proxy")
support = data.get("http.proxySupport")
no_proxy = data.get("http.noProxy")

print(f"VS Code settings file: {p}")
print(f"http.proxy: {proxy!r}")
print(f"http.proxySupport: {support!r}")
print(f"http.noProxy: {no_proxy!r}")
PY
  else
    echo "VS Code settings file: ещё не создан"
  fi

  if current_proxy_raw >/dev/null 2>&1; then
    echo
    check_bridge || true
  else
    echo
    echo "Прокси не установлен."
  fi
}

install_proxy() {
  local user
  user="$(get_target_user)"

  echo
  echo "Установка прокси для пользователя VS Code: $user"
  echo "Ввод скрыт."
  read -r -s -p "Дайте строку в формате логин:пароль@айпишка:порт : " PROXY_RAW
  echo

  if [[ ! "$PROXY_RAW" =~ ^[^:@]+:[^@]+@[^:]+:[0-9]+$ ]]; then
    echo "Неверный формат."
    echo "Нужно так: логин:пароль@айпишка:порт"
    return
  fi

  install_packages
  backup_config
  write_proxy_privoxy_config "$PROXY_RAW"

  mkdir -p /var/log/privoxy
  chown -R privoxy:privoxy /var/log/privoxy 2>/dev/null || true

  systemctl enable privoxy >/dev/null 2>&1 || true
  systemctl restart privoxy

  if ! systemctl is-active --quiet privoxy; then
    echo "Privoxy не поднялся."
    echo "Смотри:"
    echo "  systemctl status privoxy --no-pager -l"
    echo "  journalctl -u privoxy -n 100 --no-pager"
    return
  fi

  cleanup_old_env_proxy "$user"
  set_vscode_proxy_settings "$user"

  echo "Privoxy поднят."
  check_bridge || true

  echo
  echo "Готово."
  echo "Теперь в VS Code:"
  echo "1) F1"
  echo "2) Remote-SSH: Kill VS Code Server on Host..."
  echo "3) Подключиться заново"
}

remove_proxy() {
  local user
  user="$(get_target_user)"

  echo
  read -r -p "Точно удалить прокси? [y/N] : " ans
  if [[ ! "${ans:-}" =~ ^[Yy]$ ]]; then
    echo "Отмена."
    return
  fi

  backup_config
  write_clean_privoxy_config

  systemctl stop privoxy || true
  systemctl disable privoxy >/dev/null 2>&1 || true

  cleanup_old_env_proxy "$user"
  remove_vscode_proxy_settings "$user"

  echo "Прокси удалён."
  echo "Privoxy остановлен."
  echo
  echo "Теперь в VS Code:"
  echo "1) F1"
  echo "2) Remote-SSH: Kill VS Code Server on Host..."
  echo "3) Подключиться заново"
}

pause() {
  echo
  read -r -p "Нажми Enter, чтобы вернуться в меню..." _
}

menu() {
  clear || true
  echo "=============================="
  echo "  Proxy / Privoxy / VS Code"
  echo "=============================="
  echo "1. Установить прокси"
  echo "2. Удалить прокси"
  echo "3. Проверить текущий установленный прокси"
  echo "4. Выход"
  echo
  read -r -p "Выбери пункт: " choice

  case "${choice:-}" in
    1)
      install_proxy
      pause
      ;;
    2)
      remove_proxy
      pause
      ;;
    3)
      show_current_proxy
      pause
      ;;
    4)
      exit 0
      ;;
    *)
      echo "Неверный пункт."
      pause
      ;;
  esac
}

while true; do
  menu
done
