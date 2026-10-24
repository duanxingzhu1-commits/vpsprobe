#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=/opt/vpsprobe/agent
CONFIG=/etc/vpsprobe/agent.json
SERVICE=/etc/systemd/system/vpsprobe-agent.service
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SOURCE="$SOURCE_DIR/agent.py"
[[ -f "$AGENT_SOURCE" ]] || AGENT_SOURCE="$INSTALL_DIR/agent.py"

need_root() {
  if [[ "$(id -u)" != 0 ]]; then
    echo "请使用 sudo 运行。" >&2
    exit 1
  fi
}

install_agent() {
  need_root
  if [[ "$(uname -s)" != Linux ]] || ! command -v systemctl >/dev/null; then
    echo "第一版仅支持使用 systemd 的 Linux VPS。" >&2
    return 1
  fi
  command -v python3 >/dev/null || { echo "请先安装 Python 3.9+" >&2; return 1; }
  if [[ -f "$CONFIG" ]]; then
    echo "探针已安装并绑定。可在探针管理菜单查看状态或重新绑定。"
    return
  fi
  install -d -m 700 "$INSTALL_DIR" /etc/vpsprobe
  [[ -f "$AGENT_SOURCE" ]] || { echo "找不到 agent.py，请从项目目录运行脚本。" >&2; return 1; }
  if [[ "$AGENT_SOURCE" != "$INSTALL_DIR/agent.py" ]]; then
    install -m 755 "$AGENT_SOURCE" "$INSTALL_DIR/agent.py"
  fi
  install -m 755 "$SOURCE_DIR/vpsprobe.sh" /usr/local/bin/vpsprobe-agent
  cat > "$SERVICE" <<'EOF'
[Unit]
Description=VPSProbe Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 /opt/vpsprobe/agent/agent.py run
Restart=always
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/vpsprobe

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  echo "探针程序已安装到 $INSTALL_DIR。"
  echo '如果面板尚未部署，可直接回车；之后运行 sudo vpsprobe-agent rebind 完成连接。'
  bind_agent
}

status_agent() {
  if [[ ! -f "$INSTALL_DIR/agent.py" ]]; then
    echo '探针尚未安装。'
    return
  fi
  if [[ ! -f "$CONFIG" ]]; then
    echo '探针已安装，等待绑定面板。运行 sudo vpsprobe-agent rebind。'
    return
  fi
  if [[ -f "$CONFIG" ]]; then
    python3 "$INSTALL_DIR/agent.py" diagnose || true
    echo
  fi
  systemctl --no-pager --full status vpsprobe-agent || true
}

diagnose_agent() {
  if [[ ! -f "$CONFIG" ]]; then
    echo '探针尚未绑定面板。请在探针管理菜单选择 4。'
    return
  fi
  python3 "$INSTALL_DIR/agent.py" diagnose
}

update_agent() {
  need_root
  [[ -f "$INSTALL_DIR/agent.py" ]] || { echo "尚未安装探针。"; return; }
  if [[ "$AGENT_SOURCE" == "$INSTALL_DIR/agent.py" ]]; then
    echo "请下载新版项目文件，并在其目录运行 sudo bash vpsprobe.sh update。"
    return 1
  fi
  cp "$INSTALL_DIR/agent.py" "$INSTALL_DIR/agent.py.bak"
  install -m 755 "$AGENT_SOURCE" "$INSTALL_DIR/agent.py"
  install -m 755 "$SOURCE_DIR/vpsprobe.sh" /usr/local/bin/vpsprobe-agent
  if ! python3 -m py_compile "$INSTALL_DIR/agent.py"; then
    mv "$INSTALL_DIR/agent.py.bak" "$INSTALL_DIR/agent.py"
    echo "更新失败，已恢复旧版本。" >&2
    return 1
  fi
  if [[ -f "$CONFIG" ]]; then systemctl restart vpsprobe-agent; fi
  echo "Agent 已更新。"
}

bind_agent() {
  need_root
  [[ -f "$INSTALL_DIR/agent.py" ]] || { echo '请先安装探针。'; return 1; }
  local hub code name staged
  read -r -p "面板地址 (https://...，暂无面板可直接回车): " hub
  if [[ -z "$hub" ]]; then
    if [[ -f "$CONFIG" ]]; then
      echo '已取消重新绑定，现有连接保持不变。'
    else
      echo '探针已安装，等待绑定面板；服务暂不启动。'
    fi
    return 0
  fi
  if [[ "$hub" != https://* && "$hub" != http://127.0.0.1:* && "$hub" != http://localhost:* ]]; then
    echo '远程面板必须使用 HTTPS。探针已安装，可稍后重新绑定。' >&2
    return 1
  fi
  read -r -p "面板生成的一次性绑定码: " code
  if [[ -z "$code" ]]; then
    echo '绑定码为空；探针已安装，可稍后重新绑定。'
    return 0
  fi
  read -r -p "机器名称 [$(hostname)]: " name
  name="${name:-$(hostname)}"
  staged="${CONFIG}.new"
  if VPSPROBE_AGENT_CONFIG="$staged" python3 "$INSTALL_DIR/agent.py" register --hub "$hub" --code "$code" --name "$name"; then
    if [[ -f "$CONFIG" ]]; then cp "$CONFIG" "${CONFIG}.bak.$(date +%s)"; fi
    mv "$staged" "$CONFIG"
    chmod 600 "$CONFIG"
    systemctl enable --now vpsprobe-agent
    systemctl restart vpsprobe-agent
    echo '探针已绑定并启动。'
  else
    rm -f "$staged"
    echo '绑定失败。探针程序保留，原配置保持不变，可稍后重试。' >&2
    return 1
  fi
}

rebind_agent() { bind_agent; }

uninstall_agent() {
  need_root
  read -r -p "确认卸载 Agent？面板历史数据会保留。输入 YES: " answer
  [[ "$answer" == YES ]] || return
  systemctl disable --now vpsprobe-agent 2>/dev/null || true
  rm -f "$SERVICE" "$CONFIG"
  rm -f /usr/local/bin/vpsprobe-agent
  rm -rf "$INSTALL_DIR"
  systemctl daemon-reload
  echo "Agent 已卸载；面板历史数据仍保留。"
}

menu() {
  while true; do
    cat <<'EOF'

VPSProbe 探针管理
──────────────────────────
1. 安装本机探针（可稍后绑定面板）
2. 查看运行状态
3. 更新 Agent
4. 修改面板地址 / 重新绑定
5. 查看日志
6. 面板与网络诊断
7. 重启 Agent
8. 卸载 Agent
0. 退出
──────────────────────────
EOF
    read -r -p "请选择: " choice
    case "$choice" in
      1) install_agent;;
      2) status_agent;;
      3) update_agent;;
      4) rebind_agent;;
      5) journalctl -u vpsprobe-agent -n 50 --no-pager || true;;
      6) diagnose_agent;;
      7) need_root; systemctl restart vpsprobe-agent;;
      8) uninstall_agent;;
      0) return;;
      *) echo "无效选项";;
    esac
  done
}

case "${1:-menu}" in
  menu) menu;;
  install) install_agent;;
  status) status_agent;;
  update) update_agent;;
  rebind) rebind_agent;;
  logs) journalctl -u vpsprobe-agent -n 50 --no-pager;;
  diagnose) diagnose_agent;;
  restart) need_root; systemctl restart vpsprobe-agent;;
  uninstall) uninstall_agent;;
  *) echo "用法: $0 [menu|install|status|update|rebind|logs|diagnose|restart|uninstall]" >&2; exit 2;;
esac
