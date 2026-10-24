#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=/opt/vpsprobe
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
    echo "Agent 已安装，请使用更新或重新绑定菜单。"
    return
  fi
  read -r -p "面板地址 (https://...): " hub
  if [[ "$hub" != https://* && "$hub" != http://127.0.0.1:* && "$hub" != http://localhost:* ]]; then
    echo "远程面板必须使用 HTTPS。" >&2
    return 1
  fi
  read -r -p "面板生成的一次性绑定码: " code
  read -r -p "机器名称 [$(hostname)]: " name
  name="${name:-$(hostname)}"
  install -d -m 700 "$INSTALL_DIR" /etc/vpsprobe
  [[ -f "$AGENT_SOURCE" ]] || { echo "找不到 agent.py，请从项目目录运行脚本。" >&2; return 1; }
  if [[ "$AGENT_SOURCE" != "$INSTALL_DIR/agent.py" ]]; then
    install -m 755 "$AGENT_SOURCE" "$INSTALL_DIR/agent.py"
  fi
  if [[ "$SOURCE_DIR/vpsprobe.sh" != /usr/local/bin/vpsprobe ]]; then
    install -m 755 "$SOURCE_DIR/vpsprobe.sh" /usr/local/bin/vpsprobe
  fi
  python3 "$INSTALL_DIR/agent.py" register --hub "$hub" --code "$code" --name "$name"
  cat > "$SERVICE" <<'EOF'
[Unit]
Description=VPSProbe Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 /opt/vpsprobe/agent.py run
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
  systemctl enable --now vpsprobe-agent
  echo "安装完成。"
  systemctl --no-pager --full status vpsprobe-agent | head -18 || true
}

status_agent() {
  if [[ -f "$CONFIG" ]]; then
    python3 "$INSTALL_DIR/agent.py" diagnose || true
    echo
  fi
  systemctl --no-pager --full status vpsprobe-agent || true
}

diagnose_agent() {
  if [[ ! -f "$CONFIG" ]]; then
    echo "尚未安装 Agent。请先选择 1。"
    return
  fi
  python3 "$INSTALL_DIR/agent.py" diagnose
}

update_agent() {
  need_root
  [[ -f "$CONFIG" ]] || { echo "尚未安装 Agent。"; return; }
  if [[ "$AGENT_SOURCE" == "$INSTALL_DIR/agent.py" ]]; then
    echo "请下载新版项目文件，并在其目录运行 sudo bash vpsprobe.sh update。"
    return 1
  fi
  cp "$INSTALL_DIR/agent.py" "$INSTALL_DIR/agent.py.bak"
  install -m 755 "$AGENT_SOURCE" "$INSTALL_DIR/agent.py"
  install -m 755 "$SOURCE_DIR/vpsprobe.sh" /usr/local/bin/vpsprobe
  if ! python3 -m py_compile "$INSTALL_DIR/agent.py"; then
    mv "$INSTALL_DIR/agent.py.bak" "$INSTALL_DIR/agent.py"
    echo "更新失败，已恢复旧版本。" >&2
    return 1
  fi
  systemctl restart vpsprobe-agent
  echo "Agent 已更新。"
}

rebind_agent() {
  need_root
  [[ -f "$CONFIG" ]] || { echo "尚未安装 Agent。"; return 1; }
  read -r -p "新面板地址 (https://...): " hub
  if [[ "$hub" != https://* && "$hub" != http://127.0.0.1:* && "$hub" != http://localhost:* ]]; then
    echo "远程面板必须使用 HTTPS。" >&2
    return 1
  fi
  read -r -p "新面板的一次性绑定码: " code
  read -r -p "机器名称 [$(hostname)]: " name
  name="${name:-$(hostname)}"
  local staged="${CONFIG}.new"
  if VPSPROBE_AGENT_CONFIG="$staged" python3 "$INSTALL_DIR/agent.py" register --hub "$hub" --code "$code" --name "$name"; then
    cp "$CONFIG" "${CONFIG}.bak.$(date +%s)"
    mv "$staged" "$CONFIG"
    chmod 600 "$CONFIG"
    systemctl restart vpsprobe-agent
    echo "已重新绑定。旧配置保存在 /etc/vpsprobe。"
  else
    rm -f "$staged"
    echo "绑定失败，原配置保持不变。" >&2
    return 1
  fi
}

uninstall_agent() {
  need_root
  read -r -p "确认卸载 Agent？面板历史数据会保留。输入 YES: " answer
  [[ "$answer" == YES ]] || return
  systemctl disable --now vpsprobe-agent 2>/dev/null || true
  rm -f "$SERVICE" "$CONFIG"
  rm -f /usr/local/bin/vpsprobe
  rm -rf "$INSTALL_DIR"
  systemctl daemon-reload
  echo "Agent 已卸载；面板历史数据仍保留。"
}

menu() {
  while true; do
    cat <<'EOF'

VPSProbe 探针管理
──────────────────────────
1. 安装并连接本机 Agent
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
