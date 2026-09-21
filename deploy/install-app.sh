#!/usr/bin/env bash
# QQ Agent —— 应用本体（headless）安装脚本：拉代码、装依赖、落 systemd
# 用法：sudo deploy/install-app.sh
set -euo pipefail

CONF=${QQ_AGENT_DEPLOY_CONF:-/etc/qq-agent/deploy.conf}
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f $CONF ]] || { echo "缺少配置文件 $CONF"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"
: "${APP_DIR:=/opt/qq-agent}"
: "${DATA_DIR:=/var/lib/qq-agent}"
: "${PORT:=3210}"
REPO=${REPO:-https://github.com/linnin233/QQ-agent.git}

# ── 1) 代码 ──
if [[ -d $APP_DIR/.git ]]; then
  echo "-- 更新代码：$APP_DIR"
  git -C "$APP_DIR" fetch -q origin
  git -C "$APP_DIR" reset -q --hard origin/main
else
  echo "-- 克隆代码到 $APP_DIR"
  git clone --depth 1 "$REPO" "$APP_DIR"
fi
git -C "$APP_DIR" log --oneline -1

# ── 2) 依赖（不装 electron，headless 用不到；npmmirror 加速）──
# 用 npm ci：按 lockfile 精确安装，且不会像 npm install 那样把 lockfile 里的
# resolved 地址改写成镜像地址（那会让工作区莫名其妙变脏）。
cd "$APP_DIR"
if [[ ! -d node_modules ]]; then
  npm ci --omit=dev --no-audit --no-fund --registry=https://registry.npmmirror.com \
    || npm install --omit=dev --no-audit --no-fund --registry=https://registry.npmmirror.com
fi
du -sh node_modules

# ── 3) 数据目录 ──
mkdir -p "$DATA_DIR"

# ── 4) 首次写入配置骨架（已存在则不覆盖；API Key 到控制台里填）──
CONFIG_FILE="$DATA_DIR/config.json"
if [[ ! -f $CONFIG_FILE ]]; then
  # snowluma.dir 指向协议端容器的数据卷：qq-agent 会去读 config/onebot_<uin>.json
  # 里的 per-account 令牌来自动连接。协议端跑在 Docker 里时这是唯一能读到令牌的路径，
  # 留空的话拿不到令牌，OneBot 会一直 401（实测踩过）。
  SNOWLUMA_DATA_DIR=${SNOWLUMA_DATA_DIR:-/var/lib/docker/volumes/qq-gateway-data/_data}
  cat > "$CONFIG_FILE" <<JSON
{
  "snowluma": {
    "dir": "${SNOWLUMA_DATA_DIR}",
    "autoLaunch": false,
    "wsUrl": "${ONEBOT_WS:-ws://127.0.0.1:3001}",
    "httpUrl": "${ONEBOT_HTTP:-http://127.0.0.1:3000}",
    "accessToken": "",
    "httpAccessToken": ""
  },
  "server": { "port": ${PORT}, "token": "" }
}
JSON
  echo "-- 已写入配置骨架 $CONFIG_FILE（snowluma.dir=$SNOWLUMA_DATA_DIR）"
else
  echo "-- 配置已存在，保留不动：$CONFIG_FILE"
fi

# ── 5) systemd ──
# 用 node 的绝对路径：这台机器的 /usr/bin/node 是宝塔的软链，切版本后会变。
NODE_BIN=$(readlink -f "$(command -v node)")
echo "-- Node: $NODE_BIN ($(node -v))"
cat > /etc/systemd/system/qq-agent.service <<UNIT
[Unit]
Description=QQ Agent headless (OneBot v11 client + web console)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
Environment=QQ_AGENT_DATA_DIR=$DATA_DIR
Environment=NODE_ENV=production
ExecStart=$NODE_BIN $APP_DIR/src/server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=qq-agent
LimitNOFILE=65536
# 内存护栏：小内存机器上先牺牲自己，别让内核 OOM 去杀 MySQL
MemoryHigh=384M
MemoryMax=640M

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now qq-agent >/dev/null 2>&1
sleep 4
systemctl --no-pager --lines=6 status qq-agent || true
curl -s -m 5 "http://127.0.0.1:$PORT/api/status" | head -c 180; echo
echo "== 完成：控制台监听 127.0.0.1:$PORT =="
