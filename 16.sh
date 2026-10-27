```bash
#!/bin/bash
set -Eeuo pipefail

# ==========================================
# 1. 自定义配置区
# ==========================================
TG_TOKEN="8526087156:AAHR5forb44MA061r0zgcPMiGtkkxHD5K6o"
TG_CHAT_ID="6303873752"

TROJAN_PORT=52254
TROJAN_PASSWORD="MyTrojanPass321"
SNI_DOMAIN="otheve.beacon.163.com"
DOH_URL="https://223.5.5.5/dns-query"

WORK_DIR="$HOME/trojan_isolated"

# ==========================================
# 2. 基础工具
# ==========================================
info() {
    echo "[信息] $*"
}

error() {
    echo "[错误] $*" >&2
}

# 出错时显示行号
trap 'error "脚本在第 ${LINENO} 行执行失败，退出码：$?"' ERR

# ==========================================
# 3. 安装基础环境
# ==========================================
info "正在安装基础环境..."

sudo apt-get update
sudo apt-get install -y \
    ca-certificates curl jq openssl docker.io docker-compose

sudo systemctl enable --now docker

# 保留原脚本的 IPv4 转发设置
sudo sysctl -w net.ipv4.ip_forward=1

if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf >/dev/null
fi

# ==========================================
# 4. 准备工作目录
# ==========================================
mkdir -p "$WORK_DIR/cert"
cd "$WORK_DIR"

# ==========================================
# 5. 证书检查
# ==========================================
if [[ ! -s ./cert/server.crt || ! -s ./cert/server.key ]]; then
    info "证书文件缺失，生成自签名证书..."

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout ./cert/server.key \
        -out ./cert/server.crt \
        -subj "/CN=$SNI_DOMAIN" \
        -addext "subjectAltName=DNS:$SNI_DOMAIN"

    chmod 600 ./cert/server.key
else
    info "证书文件已存在，保留现有证书。"
fi

openssl x509 -in ./cert/server.crt -noout >/dev/null
openssl pkey -in ./cert/server.key -noout >/dev/null

# ==========================================
# 6. 生成 sing-box 配置
# ==========================================
info "正在生成配置文件..."

cat > config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "$DOH_URL",
        "detour": "direct"
      }
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": $TROJAN_PORT,
      "users": [
        {
          "name": "user1",
          "password": "$TROJAN_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI_DOMAIN",
        "certificate_path": "/etc/sing-box/cert/server.crt",
        "key_path": "/etc/sing-box/cert/server.key"
      }
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

# ==========================================
# 7. Docker Compose 配置
# ==========================================
cat > docker-compose.yml <<EOF
version: '3'
services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: trojan-isolated
    restart: always
    ports:
      - "$TROJAN_PORT:$TROJAN_PORT/tcp"
      - "$TROJAN_PORT:$TROJAN_PORT/udp"
    volumes:
      - ./config.json:/etc/sing-box/config.json:ro
      - ./cert:/etc/sing-box/cert:ro
    command: -D /var/lib/sing-box -c /etc/sing-box/config.json run
EOF

# ==========================================
# 8. 检查 Docker Compose
# ==========================================
if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    error "找不到 Docker Compose。"
    exit 1
fi

# 检查 Compose 文件格式
$COMPOSE config -q

# ==========================================
# 9. 启动服务
# ==========================================
info "正在启动服务..."

# down 失败不再阻止后续启动
$COMPOSE down || info "旧容器未运行或停止时返回非零状态，继续启动。"

$COMPOSE up -d

# ==========================================
# 10. 检查容器状态
# ==========================================
sleep 3

if ! sudo docker container inspect trojan-isolated >/dev/null 2>&1; then
    error "容器不存在，部署失败。"
    sudo docker ps -a
    exit 1
fi

STATUS=$(sudo docker inspect -f '{{.State.Status}}' trojan-isolated)

if [[ "$STATUS" != "running" ]]; then
    error "容器未正常运行，当前状态：$STATUS"
    sudo docker logs --tail 100 trojan-isolated
    exit 1
fi

info "容器正在运行。"

# ==========================================
# 11. 获取公网 IP
# ==========================================
IP=$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)

if [[ -z "$IP" ]]; then
    error "无法获取公网 IPv4 地址。"
    exit 1
fi

# ==========================================
# 12. 检查端口映射
# ==========================================
info "Docker 端口映射："
sudo docker port trojan-isolated || true

info "宿主机 TCP 监听状态："
sudo ss -lntp | grep -E ":${TROJAN_PORT}[[:space:]]" \
    || info "未从 ss 输出中发现对应监听；请继续检查 Docker 端口映射。"

# ==========================================
# 13. 输出部署状态
# ==========================================
echo "-------------------------------------------------------"
echo "容器状态：$STATUS"
echo "服务器公网 IPv4：$IP"
echo "服务端口：$TROJAN_PORT"
echo "-------------------------------------------------------"

info "正在显示最近的服务日志..."
sudo docker logs --tail 50 trojan-isolated

echo
info "基础部署检查完成。"
info "请确认 sing-box 日志无错误，并从客户端进行连接测试。"

# ==========================================
# 14. Telegram 通知
# ==========================================
if [[ "$TG_TOKEN" != "请填写重新生成的Telegram_Bot_Token" \
      && -n "$TG_TOKEN" && -n "$TG_CHAT_ID" ]]; then

    info "正在发送部署状态通知..."

    RESPONSE=$(curl -fsS --max-time 10 \
        -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=sing-box 容器已启动。公网 IPv4：${IP}，端口：${TROJAN_PORT}。请检查日志并进行客户端连接测试。" \
        || true)

    if echo "$RESPONSE" | grep -q '"ok":true'; then
        info "Telegram 通知发送成功。"
    else
        error "Telegram 通知发送失败：$RESPONSE"
    fi
else
    info "未填写有效的 Telegram 配置，跳过通知。"
fi
```