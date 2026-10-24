# VPSProbe · 第一版 VPS 部署包

一个可运行的自托管 VPS 探针原型：Python 标准库面板、Linux Agent、终端数字菜单，以及 Docker Compose + Caddy HTTPS 部署。当前适合少量自有 VPS 试用，尚未完成公开互联网生产环境加固。

## 与参考工具箱的区别

[KEJILION.SH](https://github.com/kejilion/sh) 是综合 Linux 管理工具箱，涵盖系统、Docker、建站、网络等操作。VPSProbe 借鉴“在终端用菜单完成安装和维护”的交互思路，但产品只围绕**多 VPS 集中监控**：Agent 接入、网络探测、按套餐账期记录流量、到期提醒和通知送达。菜单的状态页还会直接诊断面板连接与 TCP 探测目标。项目没有使用参考仓库的脚本源码、菜单文案或品牌资源。

本地 ZIP 仍需先上传 VPS。将来在 GitHub 发布正式版本后，可以托管一个下载器，提供类似“一行启动”的命令；那只是下载入口，完整代码仍在仓库中。发布前要固定版本、校验下载文件并提供可审阅的安装脚本，不应把当前未发布的示例地址当成可用命令。

## 在 VPS 部署面板

准备一台 Linux VPS、指向这台 VPS 的域名，以及已安装的 Docker Engine、Docker Compose 插件、`unzip` 和 `openssl`。开放入站 TCP 80/443。域名解析和端口是 Caddy 自动申请证书的条件。安装 Docker 请遵循[官方文档](https://docs.docker.com/engine/install/)；不要运行来源不明的安装命令。

**第一步：在存放 ZIP 的本机终端执行**（不要在 `root@vps...` 的 VPS 终端执行）。把 `YOUR_PUBLIC_IP` 换成 VPS 的真实公网 IP：

```bash
scp ./vpsprobe-vps-deploy.zip root@YOUR_PUBLIC_IP:/root/
```

**第二步：回到已登录的 VPS 终端执行**。Debian/Ubuntu 缺少 `unzip` 时先安装；若已安装，该命令也安全：

```bash
apt update && apt install -y unzip openssl
cd /root
unzip vpsprobe-vps-deploy.zip
cd vpsprobe
bash deploy-hub.sh
```

不要在 VPS 上使用本机文件路径。如果尚未登录 VPS，可以在本机终端运行 `ssh root@YOUR_PUBLIC_IP`。`YOUR_PUBLIC_IP` 是说明用占位符，不能原样输入。

脚本要求输入面板域名，生成并显示一次管理员密码，写入权限为 600 的 `.env`，然后执行 `docker compose up -d --build`。打开 `https://你的域名` 登录。请妥善保存初始密码；不要把 `.env` 提交到 GitHub。修改 Telegram 或企业微信配置后，执行 `docker compose up -d` 让容器读取新值。

常用命令：

```bash
docker compose ps
docker compose logs -f --tail=100
docker compose restart
docker compose down
```

数据保存在 Docker 命名卷 `hub_data` 中。`docker compose down` 不会删除数据；不要执行 `docker compose down -v`，除非明确要删除数据库和证书卷。升级前请备份数据卷及 `.env`。

### 将其他 VPS 接入面板

在面板点击“添加服务器”，复制一次性绑定码。将同一 ZIP 上传到每台要监控的 Linux VPS，然后：

```bash
unzip vpsprobe-vps-deploy.zip
cd vpsprobe
sudo bash vpsprobe.sh
```

选择菜单 `1`，输入 `https://你的域名`、绑定码和机器名称。安装后运行 `sudo vpsprobe` 可再次打开菜单。Agent 需要 Python 3.9+ 与 systemd。Agent 默认每 30 秒上报，并测试到 `1.1.1.1:443` 的 TCP 连接；如需修改探测目标，可在 systemd 服务环境中配置 `VPSPROBE_PROBE_HOST` 与 `VPSPROBE_PROBE_PORT`。

## 本地预览面板

要求 Python 3.9+。在项目目录运行：

```bash
export VPSPROBE_ADMIN_PASSWORD='请替换为至少12位的强密码'
export VPSPROBE_COOKIE_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(36))')"
python3 server.py
```

浏览器打开 `http://127.0.0.1:8765`。数据保存在同目录 `vpsprobe.db`，已被 `.gitignore` 排除。不要把上面的示例密码原样用于联网部署。

界面现在有“总览”“服务器”“事件记录”三个可切换页面；手机宽度下服务器显示为卡片，点“查看详情与编辑”可看网络、资源、流量和到期信息。新安装的面板默认没有机器，需绑定 Agent 后才会出现真实数据。聊天中打开的本地预览另外填入了示例数据，仅用于看界面。

本地预览的面板不带真实 VPS 数据；聊天中展示的 3 台示例机器只存在于本地演示数据库，不会出现在新部署的面板里。

## 通知

在面板 VPS 的 `.env` 中填写以下变量：

```bash
VPSPROBE_TG_TOKEN=Telegram Bot Token
VPSPROBE_TG_CHAT_ID=接收消息的 Chat ID
VPSPROBE_WECOM_WEBHOOK=企业微信群机器人 Webhook URL
```

未配置的渠道不会发送。第一版会在新机器连接、网络探测故障/恢复、流量达到 80%/95%/100%、机器离线和到期前 30/7/1/0 天产生事件。到期日与流量额度在机器详情里设置。

## 第一版范围与限制

- 当前 Agent 仅支持 Linux `/proc` 指标和 systemd；面板可在有 Python 3.9+ 的系统上运行。
- 流量按非回环网卡的收发总量计算，使用 UTC 月账期；当前不支持服务商账单同步、单网卡选择和自定义计费方向。
- 网络探测为 Agent 到单个 TCP 目标的连接测试；多目标、多地点 ICMP/HTTP 探测还未实现。
- Docker Compose 包含 Caddy HTTPS 反向代理；生产使用前仍需配置防火墙、备份、访问限制，并完成安全审查。
- 卸载 Agent 保留面板历史。更新 Agent 需要把新版项目文件复制到 VPS，并在新版目录运行 `sudo bash vpsprobe.sh update`。
- 尚未发布到 GitHub；项目代码和文档可作为后续开源仓库的基础。

## 项目文件

- `server.py`：面板、API、SQLite 和提醒逻辑。
- `index.html`：响应式监控界面。
- `agent.py`：Linux 指标采集与网络探测。
- `vpsprobe.sh`：VPS 终端数字菜单与 systemd 安装。
- `Dockerfile`、`compose.yaml`、`Caddyfile`、`deploy-hub.sh`：面板 VPS 部署。

## 开源前待办

需要补齐账号和权限、更完整的 CSRF 与速率限制、告警去重与恢复、时区和账期规则、配置化网络探测、正式安装包及自动更新、备份恢复、更多测试与安全审查，再发布 GitHub 仓库。本机没有 Docker，Compose 容器启动和真实 VPS 安装尚未实测。
