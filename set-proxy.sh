#!/usr/bin/env bash
set -euo pipefail

CFG="/etc/privoxy/config"
LOCAL_HTTP_PROXY="http://127.0.0.1:8118"
TEMP_PROXY_DIR="/run/codex-proxy"
PERM_PROXY_ENV_REL=".config/codex-proxy.env"
SOURCE_MARKER_TEMP="# codex-proxy-temp"
SOURCE_MARKER_PERM="# codex-proxy-perm"


setup_colors() {
  CLR_RESET=""
  CLR_BOLD=""
  CLR_RED=""
  CLR_GREEN=""
  CLR_YELLOW=""
  CLR_CYAN=""

  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    local ncolors
    ncolors="$(tput colors 2>/dev/null || echo 0)"
    if [[ "${ncolors:-0}" -ge 8 ]]; then
      CLR_RESET="$(tput sgr0)"
      CLR_BOLD="$(tput bold)"
      CLR_RED="$(tput setaf 1)"
      CLR_GREEN="$(tput setaf 2)"
      CLR_YELLOW="$(tput setaf 3)"
      CLR_CYAN="$(tput setaf 6)"
    fi
  fi
}

setup_colors

if [[ "${EUID}" -ne 0 ]]; then
  echo "Запусти от root: sudo bash $0"
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_as_user() {
  local user="$1"
  shift
  runuser -u "$user" -- "$@"
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

get_perm_proxy_env_file() {
  local user="$1"
  local home
  home="$(get_user_home "$user")"
  echo "${home}/${PERM_PROXY_ENV_REL}"
}

get_temp_proxy_env_file() {
  local user="$1"
  echo "${TEMP_PROXY_DIR}/${user}.env"
}

backup_config() {
  if [[ -f "$CFG" ]]; then
    local backup="/etc/privoxy/config.bak.$(date +%F-%H%M%S)"
    cp -a "$CFG" "$backup"
    echo "Бэкап: $backup"
  fi
}

write_clean_privoxy_config() {
  cat > "$CFG" <<'PRIVOXY_CLEAN'
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
PRIVOXY_CLEAN

  chmod 644 "$CFG"
}

write_proxy_privoxy_config() {
  local proxy_raw="$1"

  cat > "$CFG" <<PRIVOXY_PROXY
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
PRIVOXY_PROXY

  chmod 644 "$CFG"
}

ensure_shell_source_lines() {
  local user="$1"
  local home bashrc temp_file perm_file
  home="$(get_user_home "$user")"
  bashrc="${home}/.bashrc"
  temp_file="$(get_temp_proxy_env_file "$user")"
  perm_file="$(get_perm_proxy_env_file "$user")"

  touch "$bashrc"

  local temp_line="[[ -f ${temp_file} ]] && source ${temp_file} ${SOURCE_MARKER_TEMP}"
  local perm_line="[[ -f ${perm_file} ]] && source ${perm_file} ${SOURCE_MARKER_PERM}"

  if ! grep -Fq "$SOURCE_MARKER_TEMP" "$bashrc"; then
    echo "$temp_line" >> "$bashrc"
  fi
  if ! grep -Fq "$SOURCE_MARKER_PERM" "$bashrc"; then
    echo "$perm_line" >> "$bashrc"
  fi

  chown "${user}:${user}" "$bashrc" 2>/dev/null || true
}

remove_shell_source_lines() {
  local user="$1"
  local home bashrc
  home="$(get_user_home "$user")"
  bashrc="${home}/.bashrc"

  if [[ -f "$bashrc" ]]; then
    sed -i "/${SOURCE_MARKER_TEMP//\//\\/}/d" "$bashrc" || true
    sed -i "/${SOURCE_MARKER_PERM//\//\\/}/d" "$bashrc" || true
    chown "${user}:${user}" "$bashrc" 2>/dev/null || true
  fi
}

read_profile_from_file() {
  local file="$1"
  local default_mode="$2"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  local profile mode
  profile="$(grep -E '^PROXY_PROFILE=' "$file" | tail -n1 | cut -d= -f2- | tr -d '"' || true)"
  mode="$(grep -E '^PROXY_MODE=' "$file" | tail -n1 | cut -d= -f2- | tr -d '"' || true)"

  if [[ -z "$mode" ]]; then
    mode="$default_mode"
  fi

  if [[ -z "$profile" ]]; then
    if grep -q '^export[[:space:]]\+HTTP_PROXY=' "$file"; then
      profile="npm+cli"
    else
      profile="npm"
    fi
  fi

  echo "${profile}|${mode}|${file}"
}

detect_shell_proxy_profile() {
  local user="$1"
  local temp_file perm_file
  temp_file="$(get_temp_proxy_env_file "$user")"
  perm_file="$(get_perm_proxy_env_file "$user")"

  if [[ -f "$temp_file" ]]; then
    read_profile_from_file "$temp_file" "temporary"
    return 0
  fi

  if [[ -f "$perm_file" ]]; then
    read_profile_from_file "$perm_file" "permanent"
    return 0
  fi

  return 1
}

write_shell_proxy_env() {
  local user="$1"
  local profile="$2"
  local mode="$3"

  local target
  local temp_file perm_file
  temp_file="$(get_temp_proxy_env_file "$user")"
  perm_file="$(get_perm_proxy_env_file "$user")"

  rm -f "$temp_file" "$perm_file"

  if [[ "$mode" == "temporary" ]]; then
    mkdir -p "$TEMP_PROXY_DIR"
    chmod 755 "$TEMP_PROXY_DIR"
    target="$temp_file"
  else
    local home
    home="$(get_user_home "$user")"
    mkdir -p "${home}/.config"
    target="$perm_file"
  fi

  cat > "$target" <<EOF_ENV
# managed by proxy.sh
PROXY_PROFILE="$profile"
PROXY_MODE="$mode"
EOF_ENV

  if [[ "$profile" == "npm" ]]; then
    cat >> "$target" <<EOF_ENV
export NPM_CONFIG_PROXY="${LOCAL_HTTP_PROXY}"
export NPM_CONFIG_HTTPS_PROXY="${LOCAL_HTTP_PROXY}"
EOF_ENV
  else
    cat >> "$target" <<EOF_ENV
export HTTP_PROXY="${LOCAL_HTTP_PROXY}"
export HTTPS_PROXY="${LOCAL_HTTP_PROXY}"
export ALL_PROXY="${LOCAL_HTTP_PROXY}"
export NO_PROXY="127.0.0.1,localhost,::1"

export http_proxy="${LOCAL_HTTP_PROXY}"
export https_proxy="${LOCAL_HTTP_PROXY}"
export all_proxy="${LOCAL_HTTP_PROXY}"
export no_proxy="127.0.0.1,localhost,::1"

export NPM_CONFIG_PROXY="${LOCAL_HTTP_PROXY}"
export NPM_CONFIG_HTTPS_PROXY="${LOCAL_HTTP_PROXY}"
EOF_ENV
  fi

  chmod 644 "$target"
  if [[ "$mode" == "permanent" ]]; then
    chown "${user}:${user}" "$target" 2>/dev/null || true
    chown -R "${user}:${user}" "$(dirname "$target")" 2>/dev/null || true
  fi
}

remove_shell_proxy_profile() {
  local user="$1"
  local expected_profile="$2"

  local removed_any=0
  local temp_file perm_file
  temp_file="$(get_temp_proxy_env_file "$user")"
  perm_file="$(get_perm_proxy_env_file "$user")"

  local entry profile
  if entry="$(read_profile_from_file "$temp_file" "temporary" 2>/dev/null || true)"; then
    profile="${entry%%|*}"
    if [[ "$profile" == "$expected_profile" ]]; then
      rm -f "$temp_file"
      removed_any=1
    fi
  fi

  if entry="$(read_profile_from_file "$perm_file" "permanent" 2>/dev/null || true)"; then
    profile="${entry%%|*}"
    if [[ "$profile" == "$expected_profile" ]]; then
      rm -f "$perm_file"
      removed_any=1
    fi
  fi

  if [[ ! -f "$temp_file" && ! -f "$perm_file" ]]; then
    remove_shell_source_lines "$user"
  fi

  if [[ "$removed_any" -eq 1 ]]; then
    return 0
  fi
  return 1
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

ensure_privoxy_ready_for_local_bridge() {
  if ! current_proxy_raw >/dev/null 2>&1; then
    echo "Сначала установи upstream-прокси для Privoxy (пункт для VS Code)."
    echo "Сейчас в ${CFG} нет forward-socks5."
    return 1
  fi

  systemctl enable privoxy >/dev/null 2>&1 || true
  systemctl restart privoxy

  if ! systemctl is-active --quiet privoxy; then
    echo "Privoxy не поднялся."
    echo "Смотри:"
    echo "  systemctl status privoxy --no-pager -l"
    echo "  journalctl -u privoxy -n 100 --no-pager"
    return 1
  fi

  return 0
}

prompt_install_mode() {
  echo >&2
  echo "Режим установки:" >&2
  echo "1) Временно (до перезагрузки)" >&2
  echo "2) Постоянно" >&2
  read -r -p "Выбери [1/2]: " mode_choice

  case "${mode_choice:-}" in
    1) echo "temporary" ;;
    2) echo "permanent" ;;
    *)
      echo "Неверный выбор режима." >&2
      return 1
      ;;
  esac
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
  read -r -p "Точно удалить прокси для VS Code и остановить Privoxy? [y/N] : " ans
  if [[ ! "${ans:-}" =~ ^[Yy]$ ]]; then
    echo "Отмена."
    return
  fi

  backup_config
  write_clean_privoxy_config

  systemctl stop privoxy || true
  systemctl disable privoxy >/dev/null 2>&1 || true

  remove_vscode_proxy_settings "$user"

  echo "Прокси для VS Code удалён."
  echo "Privoxy остановлен."
  echo
  echo "Теперь в VS Code:"
  echo "1) F1"
  echo "2) Remote-SSH: Kill VS Code Server on Host..."
  echo "3) Подключиться заново"
}


install_npm_codex_proxy() {
  local user mode
  user="$(get_target_user)"

  mode="$(prompt_install_mode)" || return

  if ! ensure_privoxy_ready_for_local_bridge; then
    return
  fi

  ensure_shell_source_lines "$user"
  write_shell_proxy_env "$user" "npm+cli" "$mode"

  echo
  echo "Прокси для npm + Codex CLI установлен (${mode})."
  echo "Пользователь: ${user}"
  if [[ "$mode" == "temporary" ]]; then
    echo "Режим временный: после перезагрузки сбросится автоматически."
  fi
  echo "Чтобы применилось в текущей сессии пользователя: source ~/.bashrc"
  echo "После этого можно запускать: npm i -g @openai/codex и codex"
  check_bridge || true
}

remove_npm_codex_proxy() {
  local user
  user="$(get_target_user)"

  echo
  read -r -p "Удалить прокси для npm + Codex CLI? [y/N] : " ans
  if [[ ! "${ans:-}" =~ ^[Yy]$ ]]; then
    echo "Отмена."
    return
  fi

  if remove_shell_proxy_profile "$user" "npm+cli"; then
    echo "Прокси для npm + Codex CLI удалён."
  else
    echo "Прокси-профиль npm+cli не найден."
  fi
}

show_current_proxy() {
  local user
  user="$(get_target_user)"

  echo
  echo "Пользователь: $user"
  echo "Сервис privoxy: $(systemctl is-active privoxy 2>/dev/null || echo inactive)"

  local raw=""
  if raw="$(current_proxy_raw)"; then
    echo "Privoxy upstream proxy: $(mask_proxy_raw "$raw")"
  else
    echo "Privoxy upstream proxy: не установлен"
  fi

  local settings_file
  settings_file="$(get_vscode_settings_file "$user")"

  local vscode_proxy=""
  local vscode_enabled="no"
  if [[ -f "$settings_file" ]]; then
    vscode_proxy="$(python3 - <<PY
import json
p = "${settings_file}"
try:
    with open(p, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}
print(data.get("http.proxy") or "")
PY
)"
    if [[ "$vscode_proxy" == "$LOCAL_HTTP_PROXY" ]]; then
      vscode_enabled="yes"
    fi
    echo "VS Code settings file: $settings_file"
    echo "VS Code http.proxy: ${vscode_proxy:-<пусто>}"
  else
    echo "VS Code settings file: ещё не создан"
  fi

  local shell_profile=""
  local shell_mode=""
  local shell_source=""
  local entry=""
  if entry="$(detect_shell_proxy_profile "$user" 2>/dev/null || true)" && [[ -n "$entry" ]]; then
    shell_profile="${entry%%|*}"
    local rest="${entry#*|}"
    shell_mode="${rest%%|*}"
    shell_source="${entry##*|}"
  fi

  local npmrc_proxy=""
  local npmrc_https_proxy=""
  local npmrc_enabled="no"
  if need_cmd npm; then
    npmrc_proxy="$(run_as_user "$user" npm config get proxy 2>/dev/null || true)"
    npmrc_https_proxy="$(run_as_user "$user" npm config get https-proxy 2>/dev/null || true)"
    [[ "$npmrc_proxy" == "null" ]] && npmrc_proxy=""
    [[ "$npmrc_https_proxy" == "null" ]] && npmrc_https_proxy=""
    if [[ "$npmrc_proxy" == "$LOCAL_HTTP_PROXY" || "$npmrc_https_proxy" == "$LOCAL_HTTP_PROXY" ]]; then
      npmrc_enabled="yes"
    fi
  fi

  local npm_state="не установлен"
  local npm_cli_state="не установлен"
  local vscode_state="не установлен"

  if [[ "$vscode_enabled" == "yes" ]]; then
    vscode_state="установлен (permanent)"
  fi

  if [[ "$shell_profile" == "npm" ]]; then
    npm_state="установлен (${shell_mode})"
  elif [[ "$npmrc_enabled" == "yes" ]]; then
    npm_state="установлен (permanent, npm config)"
  fi

  if [[ "$shell_profile" == "npm+cli" ]]; then
    npm_cli_state="установлен (${shell_mode})"
  fi

  echo
  echo "Типы прокси:"
  echo "- VS Code   : ${vscode_state}"
  echo "- npm       : ${npm_state}"
  echo "- npm+cli   : ${npm_cli_state}"

  if [[ -n "$shell_profile" ]]; then
    echo "Файл shell-профиля: ${shell_source}"
  fi

  if [[ "$npmrc_enabled" == "yes" ]]; then
    echo "npm config proxy: ${npmrc_proxy:-<пусто>}"
    echo "npm config https-proxy: ${npmrc_https_proxy:-<пусто>}"
  fi

  if current_proxy_raw >/dev/null 2>&1; then
    echo
    check_bridge || true
  else
    echo
    echo "Прокси bridge не настроен в Privoxy."
  fi
}

pause() {
  echo
  read -r -p "Нажми Enter, чтобы вернуться в меню..." _
}


menu() {
  clear || true
  echo "${CLR_BOLD}${CLR_CYAN}=========================================================${CLR_RESET}"
  echo "${CLR_BOLD}${CLR_CYAN}              Proxy Manager: Privoxy + CLI${CLR_RESET}"
  echo "${CLR_BOLD}${CLR_CYAN}=========================================================${CLR_RESET}"
  echo
  echo "${CLR_BOLD}${CLR_YELLOW}[ Privoxy / VS Code ]${CLR_RESET}"
  echo "  ${CLR_GREEN}1)${CLR_RESET} Установить прокси"
  echo "  ${CLR_GREEN}2)${CLR_RESET} Удалить прокси"
  echo
  echo "${CLR_BOLD}${CLR_YELLOW}[ npm + Codex CLI ]${CLR_RESET}"
  echo "  ${CLR_GREEN}3)${CLR_RESET} Установить прокси"
  echo "  ${CLR_GREEN}4)${CLR_RESET} Удалить прокси"
  echo
  echo "${CLR_BOLD}${CLR_YELLOW}[ Сервис ]${CLR_RESET}"
  echo "  ${CLR_GREEN}5)${CLR_RESET} Проверить текущие настройки"
  echo "  ${CLR_GREEN}6)${CLR_RESET} Выход"
  echo
  read -r -p "${CLR_CYAN}Выбор [1-6]: ${CLR_RESET}" choice

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
      install_npm_codex_proxy
      pause
      ;;
    4)
      remove_npm_codex_proxy
      pause
      ;;
    5)
      show_current_proxy
      pause
      ;;
    6)
      exit 0
      ;;
    *)
      echo "${CLR_RED}Неверный пункт.${CLR_RESET}"
      pause
      ;;
  esac
}

while true; do
  menu
done
