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

initial_password=''
if [[ ! -f .env ]]; then
  echo '选择面板访问方式：'
  echo '1. 公网 IP + 端口（HTTP，方便测试）'
  echo '2. 域名 + HTTPS（推荐长期使用）'
  read -r -p '请选择 [1/2]: ' mode_choice
  case "$mode_choice" in
    1)
      mode=http
      read -r -p '本 VPS 的公网 IPv4: ' ip
      valid_ipv4 "$ip" || { echo '公网 IPv4 格式不正确。' >&2; exit 1; }
      while true; do
        read -r -p '面板对外端口 [8080]: ' port
        port="${port:-8080}"
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
          echo '端口必须在 1 到 65535 之间。' >&2
          continue
        fi
        if command -v ss >/dev/null && [[ -n "$(ss -H -ltn "sport = :$port" 2>/dev/null)" ]]; then
          echo "端口 $port 已被占用，请换一个（例如 8081）。" >&2
          continue
        fi
        break
      done
      echo "将使用 http://$ip:$port。HTTP 会明文传输登录密码与探针令牌，仅建议临时测试。"
      read -r -p '确认使用 IP + HTTP？输入 YES: ' answer
      [[ "$answer" == YES ]] || { echo '已取消面板部署。'; exit 0; }
      domain=localhost
      http_bind=0.0.0.0
      public_https=0
      ;;
    2)
      mode=https
      echo '输入已解析到本 VPS 的域名；无自有域名可留空后输入公网 IPv4 使用 sslip.io。'
      read -r -p '面板域名（可留空）: ' domain
      if [[ -z "$domain" ]]; then read -r -p '本 VPS 的公网 IPv4: ' domain; fi
      if valid_ipv4 "$domain"; then
        ip="$domain"
        domain="${ip//./-}.sslip.io"
        echo "将使用第三方 DNS 域名 $domain（对应 $ip）。公网 IP 变化后需要更换域名。"
        read -r -p '确认使用该域名？[y/N]: ' answer
        [[ "$answer" == y || "$answer" == Y ]] || { echo '已取消面板部署。'; exit 0; }
      fi
      [[ "$domain" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]] || {
        echo '请输入有效域名，或输入公网 IPv4 自动生成 sslip.io 域名。' >&2; exit 1;
      }
      http_bind=127.0.0.1
      port=8765
      public_https=1
      ;;
    *) echo '无效选项。' >&2; exit 1 ;;
  esac
  password="$(openssl rand -hex 18)"
  initial_password="$password"
  cookie_key="$(openssl rand -hex 32)"
  umask 077
  cat > .env <<EOF
VPSPROBE_DOMAIN=$domain
VPSPROBE_MODE=$mode
VPSPROBE_PUBLIC_IP=${ip:-}
VPSPROBE_HTTP_BIND=$http_bind
VPSPROBE_HTTP_PORT=$port
VPSPROBE_PUBLIC_HTTPS=$public_https
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
  mode="$(sed -n 's/^VPSPROBE_MODE=//p' .env | head -1)"
  mode="${mode:-https}"
  ip="$(sed -n 's/^VPSPROBE_PUBLIC_IP=//p' .env | head -1)"
  port="$(sed -n 's/^VPSPROBE_HTTP_PORT=//p' .env | head -1)"
fi

if [[ "$mode" == http ]]; then
  echo '启动面板（IP + HTTP）...'
  docker compose up -d --build hub
else
  echo '启动面板和 HTTPS 代理...'
  docker compose up -d --build
fi
echo
echo "容器状态："
docker compose ps
healthy=0
for _ in {1..20}; do
  if docker compose exec -T hub python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8765/health', timeout=2)" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
if [[ "$healthy" != 1 ]]; then
  echo '面板容器尚未通过健康检查，请查看日志：docker compose logs --tail=100 hub' >&2
  exit 1
fi
echo
echo '━━━━━━━━ VPSProbe 面板已启动 ━━━━━━━━'
if [[ "$mode" == http ]]; then
  echo "访问地址：http://$ip:$port"
  echo "请放行 TCP $port；HTTP 模式会明文传输密码和令牌。"
else
  echo '首次申请 HTTPS 证书可能需要一段时间。请确认域名解析和 80/443 端口开放。'
  echo "访问地址：https://$domain"
fi
if [[ -n "$initial_password" ]]; then
  echo "管理员初始密码：$initial_password"
  echo '请立即保存密码；再次运行安装脚本不会重复显示。'
  echo '请勿公开包含密码的安装截图。'
else
  echo '沿用原管理员密码；本次不显示密码。'
fi
echo '登录后在面板点击“添加服务器”获取探针绑定码。'
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo "查看日志：docker compose logs -f --tail=100"
