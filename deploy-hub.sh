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

if [[ ! -f .env ]]; then
  read -r -p "面板域名（如 probe.example.com，DNS A/AAAA 需已指向本 VPS）: " domain
  if [[ ! "$domain" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]]; then
    echo "域名格式不正确。" >&2
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
fi

echo "启动面板和 HTTPS 代理..."
docker compose up -d --build
echo
echo "容器状态："
docker compose ps
echo "首次申请 HTTPS 证书可能需要一段时间。请确认域名解析和 80/443 端口开放。"
echo "查看日志：docker compose logs -f --tail=100"
