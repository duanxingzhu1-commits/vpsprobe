#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

for command_name in docker openssl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少 $command_name。请先安装 Docker Engine、Docker Compose 插件和 openssl。" >&2
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  echo "缺少 docker compose 插件。" >&2
  exit 1
fi

valid_ipv4() {
  local input="$1" part
  local -a parts
  [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$input"
  [[ "${#parts[@]}" -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    [[ "${#part}" -le 3 ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
}

if [[ ! -f .env ]]; then
  echo '有自己的域名：输入已解析到本 VPS 的域名。没有域名：直接回车，再输入公网 IPv4 使用 sslip.io 临时域名。'
  read -r -p '面板域名（可留空）: ' domain
  if [[ -z "$domain" ]]; then
    read -r -p '本 VPS 的公网 IPv4: ' domain
  fi
  if valid_ipv4 "$domain"; then
    ip="$domain"
    domain="${ip//./-}.sslip.io"
    echo "将使用第三方 DNS 域名 $domain（对应 $ip）。公网 IP 变化后需要更换域名。"
    read -r -p '确认使用该域名？[y/N]: ' answer
    [[ "$answer" == y || "$answer" == Y ]] || { echo '已取消面板部署。'; exit 0; }
  fi
  if [[ ! "$domain" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]]; then
    echo '请输入有效域名，或输入公网 IPv4 自动生成 sslip.io 域名。' >&2
    exit 1
  fi
  password="$(openssl rand -hex 18)"
  cookie_key="$(openssl rand -hex 32)"
  umask 077
  cat > .env <<EOF
VPSPROBE_DOMAIN=$domain
VPSPROBE_ADMIN_PASSWORD=$password
VPSPROBE_COOKIE_KEY=$cookie_key
VPSPROBE_TG_TOKEN=
VPSPROBE_TG_CHAT_ID=
VPSPROBE_WECOM_WEBHOOK=
EOF
  echo
  echo "已创建 .env。管理员初始密码（请保存到密码管理器）：$password"
else
  echo "沿用现有 .env；不会覆盖密码和通知配置。"
  domain="$(sed -n 's/^VPSPROBE_DOMAIN=//p' .env | head -1)"
fi

echo "启动面板和 HTTPS 代理..."
docker compose up -d --build
echo
echo "容器状态："
docker compose ps
echo "首次申请 HTTPS 证书可能需要一段时间。请确认域名解析和 80/443 端口开放。"
echo "面板地址：https://$domain"
echo "查看日志：docker compose logs -f --tail=100"
