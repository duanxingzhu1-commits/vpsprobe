#!/usr/bin/env bash
set -euo pipefail

# VPSProbe 的公开入口。先让用户确认，再下载完整源码并显示安装菜单。
REPO_URL=https://github.com/duanxingzhu1-commits/vpsprobe
ARCHIVE_URL=https://codeload.github.com/duanxingzhu1-commits/vpsprobe/tar.gz/refs/heads/main
MANAGER_DIR=/opt/vpsprobe/manager
HUB_DIR=/opt/vpsprobe/hub
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || true)"
SOURCE_DIR=""
TEMP_DIR=""

say() { printf '%s\n' "$*"; }
ask() { local answer; IFS= read -r -u 3 -p "$1" answer || return 1; REPLY="$answer"; }

cleanup() {
  if [[ -n "$TEMP_DIR" ]]; then rm -rf "$TEMP_DIR"; fi
}
trap cleanup EXIT

require_terminal() {
  if ! exec 3</dev/tty; then
    say '需要交互式终端。请通过 SSH 登录 VPS 后运行。' >&2
    exit 1
  fi
}

require_root() {
  if [[ "$(id -u)" != 0 ]]; then
    say '请使用 root 运行，例如 sudo bash install.sh。' >&2
    exit 1
  fi
}

download_source() {
  command -v curl >/dev/null || { say '缺少 curl，请先安装 curl。' >&2; return 1; }
  command -v tar >/dev/null || { say '缺少 tar，请先安装 tar。' >&2; return 1; }
  TEMP_DIR="$(mktemp -d)"
  say '正在从 GitHub 下载 VPSProbe 源码...'
  curl -fL --retry 2 --connect-timeout 10 --max-time 120 "$ARCHIVE_URL" -o "$TEMP_DIR/source.tar.gz"
  tar -xzf "$TEMP_DIR/source.tar.gz" -C "$TEMP_DIR"
  SOURCE_DIR="$TEMP_DIR/vpsprobe-main"
  [[ -f "$SOURCE_DIR/install.sh" && -f "$SOURCE_DIR/agent.py" && -f "$SOURCE_DIR/compose.yaml" ]] || {
    say '下载包不完整，已停止安装。' >&2
    return 1
  }
}

save_manager() {
  install -d -m 755 "$MANAGER_DIR"
  cp -a "$SOURCE_DIR/." "$MANAGER_DIR/"
  chmod 755 "$MANAGER_DIR/install.sh" "$MANAGER_DIR/vpsprobe.sh"
  ln -sfn "$MANAGER_DIR/install.sh" /usr/local/bin/vpsprobe
  SOURCE_DIR="$MANAGER_DIR"
}

confirm_first_run() {
  say 'VPSProbe · 多 VPS 探针管理'
  say "源码：$REPO_URL"
  say '继续会下载源码并安装本机菜单命令；面板和探针需在菜单中另行选择。'
  ask '是否继续？输入 y 确认 [y/N]: ' || return 1
  [[ "$REPLY" == y || "$REPLY" == Y ]]
}

install_hub() {
  if [[ -f "$HUB_DIR/.env" ]]; then
    say "面板已在 $HUB_DIR 配置。"
    ask '是否重新运行部署脚本（保留现有配置）？[y/N]: ' || return
    [[ "$REPLY" == y || "$REPLY" == Y ]] || return
  else
    ask '确认在本机安装 VPSProbe 面板？[y/N]: ' || return
    [[ "$REPLY" == y || "$REPLY" == Y ]] || return
  fi
  install -d -m 755 "$HUB_DIR"
  cp -a "$SOURCE_DIR/." "$HUB_DIR/"
  (cd "$HUB_DIR" && bash deploy-hub.sh < /dev/tty)
}

install_agent() {
  ask '确认在本机安装 VPSProbe 探针？可稍后绑定面板 [y/N]: ' || return
  [[ "$REPLY" == y || "$REPLY" == Y ]] || return
  bash "$SOURCE_DIR/vpsprobe.sh" install < /dev/tty
}

docker_install() {
  if [[ "$(uname -s)" != Linux ]] || ! command -v apt-get >/dev/null; then
    say '自动安装仅支持 Debian/Ubuntu 的 apt 系统。' >&2
    return 1
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "$ID" != debian && "$ID" != ubuntu ]]; then
    say "暂不支持自动安装 Docker：$ID" >&2
    return 1
  fi
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    say 'Docker Engine 和 Compose 已安装。'
    return
  fi
  say "将按照 Docker 官方 apt 仓库说明，在 $PRETTY_NAME 安装 Docker Engine 和 Compose。"
  ask '确认安装 Docker？[y/N]: ' || return
  [[ "$REPLY" == y || "$REPLY" == Y ]] || return
  apt-get update
  apt-get install -y ca-certificates curl openssl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker compose version
  say 'Docker 安装完成。现在可在主菜单选择安装面板。'
}

show_status() {
  say '面板：'
  if [[ -f "$HUB_DIR/.env" ]]; then
    (cd "$HUB_DIR" && docker compose ps) || true
  else
    say '尚未配置'
  fi
  say '探针：'
  if [[ -f /opt/vpsprobe/agent/agent.py ]]; then
    bash "$SOURCE_DIR/vpsprobe.sh" status || true
  else
    say '尚未安装'
  fi
}

update_manager() {
  ask '从 GitHub main 分支更新菜单与源码？[y/N]: ' || return
  [[ "$REPLY" == y || "$REPLY" == Y ]] || return
  download_source
  save_manager
  say '菜单源码已更新。已运行的面板或探针不会自动重启。'
}

menu() {
  while true; do
    cat <<'EOF'

━━━━━━━━━━ VPSProbe ━━━━━━━━━━
1. 安装面板（集中查看所有 VPS）
2. 安装本机探针（可稍后绑定面板）
3. 探针管理（状态、日志、更新、卸载）
4. 查看安装状态
5. 安装 Docker 和 Compose（Debian/Ubuntu）
6. 更新菜单源码
0. 退出
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
    ask '请输入选项: ' || return
    case "$REPLY" in
      1) install_hub || say '面板安装未完成，请查看上面的错误。' >&2 ;;
      2) install_agent || say '探针安装未完成，请查看上面的错误。' >&2 ;;
      3) bash "$SOURCE_DIR/vpsprobe.sh" menu < /dev/tty || true ;;
      4) show_status ;;
      5) docker_install || say 'Docker 安装未完成，请查看上面的错误。' >&2 ;;
      6) update_manager || say '更新未完成，请查看上面的错误。' >&2 ;;
      0) return ;;
      *) say '无效选项。' ;;
    esac
  done
}

require_terminal
require_root
if [[ "$SCRIPT_DIR" == "$MANAGER_DIR" && -f "$SCRIPT_DIR/agent.py" ]]; then
  SOURCE_DIR="$MANAGER_DIR"
else
  confirm_first_run || { say '已取消。'; exit 0; }
  download_source
  save_manager
fi
menu
