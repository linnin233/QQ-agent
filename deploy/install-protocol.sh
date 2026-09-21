#!/usr/bin/env bash
# 启动协议端（SnowLuma，OneBot v11）
# 用法：sudo deploy/install-protocol.sh
set -euo pipefail

CONF=${QQ_AGENT_DEPLOY_CONF:-/etc/qq-agent/deploy.conf}
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f $CONF ]] || { echo "缺少配置文件 $CONF"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"
: "${VNC_PASSWD:?deploy.conf 里必须设置 VNC_PASSWD（noVNC 远程桌面密码）}"

# 官方镜像来自 Docker Hub；这台机器直连 registry-1.docker.io 不通，
# 用一个可用的镜像站中转（拉过一次后本地就有 tag 了）。
if ! docker image inspect motricseven7/snowluma:latest >/dev/null 2>&1; then
  for m in docker.m.daocloud.io docker.1ms.run docker.1panel.live dockerproxy.net; do
    echo "-- 尝试从 $m 拉取"
    if docker pull "$m/motricseven7/snowluma:latest"; then
      docker tag "$m/motricseven7/snowluma:latest" motricseven7/snowluma:latest
      break
    fi
  done
fi
docker image inspect motricseven7/snowluma:latest >/dev/null 2>&1 || { echo "镜像拉取失败"; exit 1; }

export VNC_PASSWD
docker compose -f "$SELF_DIR/snowluma-compose.yml" up -d

sleep 12
echo "== 容器状态 =="
docker ps --format '{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}'
echo "== 内存 =="
docker stats --no-stream --format '{{.Name}} 内存 {{.MemUsage}} ({{.MemPerc}})' snowluma || true
free -m | head -2
echo "== 监听（应全部是 127.0.0.1）=="
ss -lntp | grep -E ':(6081|5099|3000|3001)\b' || true
echo "== OneBot 端口自检 =="
curl -s -o /dev/null -w '  http 3000 -> %{http_code}\n' -m 5 http://127.0.0.1:3000/ || true
echo "== noVNC 密码（deploy.conf 里的 VNC_PASSWD）=="
grep -E '^VNC_PASSWD=' "$CONF" | sed 's/VNC_PASSWD=/  VNC_PASSWD=/'
echo
echo "登录步骤："
echo "  1) 你本机执行： ssh -L 6081:127.0.0.1:6081 root@<服务器IP>"
echo "  2) 浏览器打开： http://127.0.0.1:6081/vnc.html   输入上面的 VNC 密码"
echo "  3) 在远程桌面里看到 QQ 已自动启动 -> 手机 QQ 扫码登录"
echo "  4) 登录后 qq-agent 会自动从 SnowLuma 配置里同步 OneBot 令牌并连接"
echo "  5) 回控制台「设置」填 Base URL / Key / 模型 / 白名单"
