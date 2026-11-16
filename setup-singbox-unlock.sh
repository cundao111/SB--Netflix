#!/usr/bin/env bash
# Interactive installer for a sing-box Shadowsocks 2022 unlock server.

set -u
set -o pipefail

readonly PORT=18443
readonly METHOD="2022-blake3-aes-128-gcm"
readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"

TMP_DIR=""
TMP_CONFIG=""
BACKUP_FILE=""
CONFIG_REPLACED=0
HAD_ORIGINAL_CONFIG=0

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

interrupted() {
  error "操作被中断。"
  restore_previous_config || true
  exit 130
}
trap interrupted INT TERM

info() { printf '[信息] %s\n' "$*"; }
error() { printf '[失败] %s\n' "$*" >&2; }

run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_sing_box() {
  run_root sing-box "$@"
}

pause_to_menu() {
  printf '\n按回车键返回主菜单...'
  read -r _ || true
}

port_listener_output() {
  local listeners
  listeners="$(run_root ss -lntup 2>/dev/null || true)"
  if [[ -z "${listeners}" ]]; then
    return 1
  fi
  printf '%s\n' "${listeners}"
}

port_in_use() {
  local listeners
  listeners="$(port_listener_output || true)"
  if [[ -z "${listeners}" ]]; then
    return 1
  fi

  if printf '%s\n' "${listeners}" | grep -Eq ":${PORT}([[:space:]]|$)"; then
    printf '%s\n' "${listeners}" | grep -E ":${PORT}([[:space:]]|$)" || true
    return 0
  fi
  return 1
}

tcp_udp_listening() {
  local listeners tcp_listeners udp_listeners
  listeners="$(port_listener_output || true)"
  tcp_listeners="$(printf '%s\n' "${listeners}" | grep -E "^tcp.*:${PORT}([[:space:]]|$)" || true)"
  udp_listeners="$(printf '%s\n' "${listeners}" | grep -E "^udp.*:${PORT}([[:space:]]|$)" || true)"

  if [[ -z "${tcp_listeners}" || -z "${udp_listeners}" ]]; then
    return 1
  fi
  printf '%s\n%s\n' "${tcp_listeners}" "${udp_listeners}"
}

restore_previous_config() {
  [[ "${CONFIG_REPLACED}" -eq 1 ]] || return 0

  info "正在恢复执行前的配置..."
  if [[ "${HAD_ORIGINAL_CONFIG}" -eq 1 ]]; then
    if ! run_root cp -p "${BACKUP_FILE}" "${CONFIG_FILE}"; then
      error "恢复原配置失败。备份文件仍在：${BACKUP_FILE}"
      return 1
    fi
  else
    if ! run_root rm -f "${CONFIG_FILE}"; then
      error "删除本次新建的配置失败：${CONFIG_FILE}"
      return 1
    fi
    if run_root systemctl stop sing-box; then
      info "已移除本次新建的配置并停止 sing-box 服务。"
    else
      error "已移除本次新建的配置，但停止服务失败。请检查：sudo journalctl -u sing-box -n 50 --no-pager"
      return 1
    fi
    return 0
  fi

  if run_root systemctl restart sing-box; then
    info "已尝试恢复原服务。"
  else
    error "原配置已恢复，但原服务重启失败。请检查：sudo journalctl -u sing-box -n 50 --no-pager"
    return 1
  fi
}

show_service_logs_hint() {
  printf '请查看日志：sudo journalctl -u sing-box -n 50 --no-pager\n'
}

setup_unlock_server() {
  local password staged_config listeners public_ip
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-unlock.XXXXXX")" || {
    error "无法创建临时目录。"
    return 1
  }
  TMP_CONFIG="${TMP_DIR}/config.json"
  CONFIG_REPLACED=0
  HAD_ORIGINAL_CONFIG=0
  BACKUP_FILE=""

  info "开始配置解锁机（端口：${PORT}，加密：${METHOD}）。"

  if ! command -v sing-box >/dev/null 2>&1; then
    info "未检测到 sing-box，正在安装..."
    if ! command -v curl >/dev/null 2>&1; then
      error "未找到 curl，无法下载安装脚本。"
      return 1
    fi
    local install_script="${TMP_DIR}/install-sing-box.sh"
    if ! curl -fsSL https://sing-box.app/install.sh -o "${install_script}"; then
      error "下载安装脚本失败，请检查服务器网络。"
      return 1
    fi
    if ! run_root sh "${install_script}"; then
      error "sing-box 安装失败，请检查网络、软件源及 sudo 权限。"
      return 1
    fi
  fi

  if ! run_sing_box version >/dev/null 2>&1; then
    error "sing-box 命令不可用；安装可能未完成。"
    return 1
  fi

  if ! command -v ss >/dev/null 2>&1; then
    error "未找到 ss，无法安全检查端口 ${PORT} 是否被占用。"
    return 1
  fi
  if listeners="$(port_in_use)"; then
    error "端口 ${PORT} 已被占用，配置未修改。"
    printf '占用记录：\n%s\n' "${listeners}"
    return 1
  fi

  password="$(run_sing_box generate rand --base64 16 2>/dev/null)" || {
    error "生成 AES-128 密码失败。"
    return 1
  }
  if [[ ! "${password}" =~ ^[A-Za-z0-9+/]{22}==$ ]]; then
    error "生成的密码格式异常，配置未修改。"
    return 1
  fi

  cat >"${TMP_CONFIG}" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "unlock-us-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "method": "${METHOD}",
      "password": "${password}"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  chmod 600 "${TMP_CONFIG}"

  info "正在校验新配置..."
  if ! run_sing_box check -c "${TMP_CONFIG}"; then
    error "新配置未通过 sing-box 校验，原配置保持不变。"
    return 1
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    error "未找到 systemctl，无法管理 sing-box 服务。"
    return 1
  fi
  if ! run_root install -d -m 755 "${CONFIG_DIR}"; then
    error "无法创建配置目录：${CONFIG_DIR}"
    return 1
  fi

  if run_root test -f "${CONFIG_FILE}"; then
    HAD_ORIGINAL_CONFIG=1
    BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S).$$"
    if ! run_root cp -p "${CONFIG_FILE}" "${BACKUP_FILE}"; then
      error "无法备份原配置，配置未修改。"
      return 1
    fi
    info "原配置已备份至：${BACKUP_FILE}"
  fi

  staged_config="${CONFIG_DIR}/.config.json.new.$$"
  if ! run_root install -m 600 "${TMP_CONFIG}" "${staged_config}" || ! run_root mv -f "${staged_config}" "${CONFIG_FILE}"; then
    run_root rm -f "${staged_config}" || true
    error "无法写入新配置。"
    restore_previous_config || true
    return 1
  fi
  CONFIG_REPLACED=1

  if ! run_root systemctl enable sing-box; then
    error "无法启用 sing-box 开机自启动。"
    restore_previous_config || true
    return 1
  fi
  if ! run_root systemctl restart sing-box; then
    error "sing-box 启动失败。"
    restore_previous_config || true
    show_service_logs_hint
    return 1
  fi

  if ! listeners="$(tcp_udp_listening)"; then
    error "sing-box 未同时监听 ${PORT} 的 TCP 和 UDP 端口。"
    restore_previous_config || true
    show_service_logs_hint
    return 1
  fi

  public_ip=""
  if command -v curl >/dev/null 2>&1; then
    public_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi

  printf '\n========== 配置成功 ==========\n'
  if [[ -n "${public_ip}" ]]; then
    printf '服务器地址：%s\n' "${public_ip}"
  else
    printf '服务器地址：未能自动获取，请填写该服务器的公网 IPv4。\n'
  fi
  printf '端口：%s\n' "${PORT}"
  printf '加密方式：%s\n' "${METHOD}"
  printf 'AES-128 密码：%s\n' "${password}"
  printf 'TCP/UDP 监听：正常\n'
  printf 'V2Board 中的端口、加密方式和密码必须与以上内容完全一致。\n'
  return 0
}

main() {
  local choice
  while true; do
    printf '\n========== 解锁机 sing-box 配置 ==========\n'
    printf '1. 一键执行解锁机配置（生成并输出 AES-128 密码）\n'
    printf '2. 退出脚本\n\n'
    printf '请输入选项 [1-2]: '
    read -r choice || {
      printf '\n'
      exit 0
    }

    case "${choice}" in
      1)
        setup_unlock_server || true
        pause_to_menu
        ;;
      2)
        info "已退出脚本。"
        exit 0
        ;;
      *)
        error "无效选项，请输入 1 或 2。"
        ;;
    esac
  done
}

main "$@"
