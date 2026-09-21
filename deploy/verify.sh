#!/usr/bin/env bash
# QQ Agent —— 部署后自检：应用、反向代理、证书、SSE、协议端
# 用法：sudo deploy/verify.sh
set -uo pipefail

CONF=${QQ_AGENT_DEPLOY_CONF:-/etc/qq-agent/deploy.conf}
if [[ -f $CONF ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi
: "${DOMAIN:=未配置}"
: "${PORT:=3210}"
: "${AUTH_USER:=未配置}"
: "${AUTH_PASS:=未配置}"
: "${DATA_DIR:=/var/lib/qq-agent}"
: "${ONEBOT_WS:=ws://127.0.0.1:3001}"

pass() { printf '  [OK]   %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }

echo "== 1. 应用进程 =="
if systemctl is-active --quiet qq-agent; then
  pass "qq-agent 服务运行中（内存 $(systemctl show qq-agent -p MemoryCurrent --value | awk '{printf "%.0fMB", $1/1048576}')）"
else
  fail "qq-agent 未运行；journalctl -u qq-agent -n 50 --no-pager"
fi
if ss -lntp 2>/dev/null | grep -q "127.0.0.1:$PORT"; then
  pass "监听 127.0.0.1:$PORT"
else
  fail "未监听 $PORT"
fi
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$PORT/api/status" || echo 000)
[[ $code == 200 ]] && pass "本机 /api/status -> 200" || fail "本机 /api/status -> $code"

echo "== 2. 反向代理（同源 + Basic Auth）=="
if systemctl is-active --quiet nginx; then pass "nginx 运行中（$(nginx -v 2>&1 | cut -d/ -f2)）"; else fail "nginx 未运行"; fi
if [[ -f /etc/nginx/conf.d/qq-agent.conf ]]; then pass "站点配置 /etc/nginx/conf.d/qq-agent.conf 存在"; else fail "站点配置缺失，先跑 install-nginx.sh"; fi
nginx -t >/dev/null 2>&1 && pass "nginx -t 通过" || fail "nginx -t 失败"
code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 -H "Host: $DOMAIN" https://127.0.0.1/ || echo 000)
[[ $code == 401 ]] && pass "无认证访问 -> 401（鉴权生效）" || warn "无认证访问 -> $code（期望 401，检查 auth_basic）"
code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 -u "$AUTH_USER:$AUTH_PASS" -H "Host: $DOMAIN" https://127.0.0.1/api/status || echo 000)
[[ $code == 200 ]] && pass "带认证访问 -> 200" || fail "带认证访问 -> $code（检查 deploy.conf 里的账号密码）"

echo "== 3. 证书 =="
CERT_PEM=${CERT_PEM:-/etc/nginx/certs/$DOMAIN.pem}
if [[ -f $CERT_PEM ]]; then
  end=$(openssl x509 -enddate -noout -in "$CERT_PEM" | cut -d= -f2)
  cn=$(openssl x509 -noout -subject -in "$CERT_PEM" | sed 's/.*CN *= *//')
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  pass "证书 CN=$cn，到期 $end（剩 $days 天）"
  [[ $days -lt 15 ]] && warn "证书快到期了，去阿里云续期并重跑 install-nginx.sh"
  [[ $cn == "$DOMAIN" ]] && pass "证书域名与 server_name 一致" || fail "证书域名($cn)与 DOMAIN($DOMAIN) 不一致"
else
  fail "找不到证书 $CERT_PEM"
fi

echo "== 4. SSE（控制台实时刷新）=="
first=$(curl -skN -u "$AUTH_USER:$AUTH_PASS" --max-time 3 -H "Host: $DOMAIN" https://127.0.0.1/api/events 2>/dev/null | head -1)
[[ $first == event:* ]] && pass "SSE 首帧 $first（未被缓冲）" || fail "SSE 无输出（检查 proxy_buffering off 与代理链路）"

echo "== 5. 协议端（OneBot v11）=="
ws_hostport=${ONEBOT_WS#ws://}
ws_hostport=${ws_hostport%%/*}
ws_host=${ws_hostport%%:*}
ws_port=${ws_hostport##*:}
if timeout 3 bash -c "exec 3<>/dev/tcp/$ws_host/$ws_port" 2>/dev/null; then
  pass "协议端端口可达 $ONEBOT_WS"
else
  fail "协议端不可达 $ONEBOT_WS —— 机器人收不到任何消息（协议端未启动，或选了不存在的方案）"
fi
if command -v docker >/dev/null 2>&1; then
  docker ps --format '  [容器] {{.Names}} {{.Image}} {{.Status}}' 2>/dev/null | head -5
fi

echo "== 6. 资源 =="
free -m | head -2
df -h / | tail -1
avail_mb=$(free -m | awk 'NR==2{print $7}')
if [[ ${avail_mb:-0} -lt 900 ]]; then
  warn "可用内存仅 ${avail_mb}MB，协议端（QQ 客户端系）通常需要 900MB 以上"
else
  pass "可用内存 ${avail_mb}MB"
fi

echo "== 7. 结论 =="
echo "  控制台地址：https://$DOMAIN/"
echo "  数据目录：$DATA_DIR"
echo "  日志：journalctl -u qq-agent -f"
