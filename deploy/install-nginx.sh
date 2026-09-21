#!/usr/bin/env bash
# QQ Agent —— nginx 反向代理 + HTTPS 证书 + Basic Auth 安装脚本（幂等，可重复执行）
#
# 用法：
#   sudo deploy/install-nginx.sh                # 用 /etc/qq-agent/deploy.conf，证书必须已放好
#   sudo deploy/install-nginx.sh --selfsigned   # 证书还没到：先用自签证书把链路验证通
#
# 依赖：nginx（脚本会自己装，并绕过 dnf exclude）、openssl
set -euo pipefail

CONF=${QQ_AGENT_DEPLOY_CONF:-/etc/qq-agent/deploy.conf}
SELFSIGNED=0
for arg in "$@"; do
  case "$arg" in
    --selfsigned) SELFSIGNED=1 ;;
    *) echo "未知参数：$arg"; exit 2 ;;
  esac
done

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f $CONF ]] || { echo "缺少配置文件 $CONF（可从 deploy.conf.example 复制并修改）"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"
: "${DOMAIN:?deploy.conf 里必须设置 DOMAIN}"
: "${PORT:=3210}"
: "${AUTH_USER:?deploy.conf 里必须设置 AUTH_USER}"
: "${AUTH_PASS:?deploy.conf 里必须设置 AUTH_PASS}"

echo "== 域名 $DOMAIN / 后端端口 $PORT =="

# ── 1) nginx ──
# 注意：阿里云镜像的 /etc/dnf/dnf.conf 与 /etc/yum.conf 里写了
# exclude=httpd nginx php mysql ...（宝塔面板干的），不加 --disableexcludes=all 会报
# "All matches were filtered out by exclude filtering"。
if ! command -v nginx >/dev/null 2>&1; then
  echo "-- 安装 nginx（绕过 dnf exclude）"
  dnf install -y --disableexcludes=all nginx
fi
nginx -v

# ── 2) 证书 ──
mkdir -p /etc/nginx/certs
if [[ $SELFSIGNED == 1 && ( ! -f $CERT_PEM || ! -f $CERT_KEY ) ]]; then
  echo "-- 生成自签证书（只用于验证链路；正式证书到位后重跑本脚本即可替换）"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=$DOMAIN" \
    -keyout "$CERT_KEY" -out "$CERT_PEM" >/dev/null 2>&1
fi
if [[ ! -f $CERT_PEM || ! -f $CERT_KEY ]]; then
  echo "证书缺失：$CERT_PEM / $CERT_KEY"
  echo "把阿里云证书服务下载的 Nginx 版（<域名>.pem + <域名>.key）放到上面两个路径，"
  echo "或者先加 --selfsigned 验证链路。"
  exit 1
fi
chmod 644 "$CERT_PEM"; chmod 600 "$CERT_KEY"
echo "-- 证书到期时间：$(openssl x509 -enddate -noout -in "$CERT_PEM" | cut -d= -f2)"

# ── 3) Basic Auth ──
# 不依赖 httpd-tools（这台机器的 dnf exclude 也拦 httpd），用 openssl 生成 apr1 哈希
HTPASSWD=/etc/nginx/qq-agent.htpasswd
printf '%s:%s\n' "$AUTH_USER" "$(openssl passwd -apr1 "$AUTH_PASS")" > "$HTPASSWD"
chmod 640 "$HTPASSWD"
chown root:nginx "$HTPASSWD" 2>/dev/null || true
echo "-- Basic Auth 账号：$AUTH_USER（哈希写入 $HTPASSWD）"

# ── 4) 渲染站点配置 ──
sed -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__CERT_PEM__|$CERT_PEM|g" \
    -e "s|__CERT_KEY__|$CERT_KEY|g" \
    -e "s|__HTPASSWD__|$HTPASSWD|g" \
    -e "s|__PORT__|$PORT|g" \
    "$SELF_DIR/nginx/qq-agent.conf.tmpl" > /etc/nginx/conf.d/qq-agent.conf

# 默认站点会以 default_server 抢走 80/443 的请求，让位（保留备份）
if [[ -f /etc/nginx/conf.d/default.conf ]]; then
  mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
fi

# ── 5) 校验并生效 ──
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx 2>/dev/null || systemctl restart nginx
sleep 1
echo "-- 监听情况"; ss -lntp | grep -E ':(80|443)\b' || true

echo "-- 自检"
curl -sk -o /dev/null -w '   无认证 -> %{http_code}（期望 401）\n' -H "Host: $DOMAIN" https://127.0.0.1/ || true
curl -sk -u "$AUTH_USER:$AUTH_PASS" -o /dev/null -w '   带认证 -> %{http_code}（期望 200）\n' -H "Host: $DOMAIN" https://127.0.0.1/api/status || true
# SSE 长连接不会自己结束，curl 必然以超时退出；这里只取首帧做验证，不能让 set -e 误判失败
curl -skN -u "$AUTH_USER:$AUTH_PASS" --max-time 3 -H "Host: $DOMAIN" https://127.0.0.1/api/events 2>/dev/null | head -1 | sed 's/^/   SSE 首帧: /' || true

echo "== 完成：https://$DOMAIN/ =="
