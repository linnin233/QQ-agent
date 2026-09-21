#!/usr/bin/env bash
# 抓取 SnowLuma 容器里 QQ 登录界面的截图（含二维码），落到宿主机文件
#
# 用法：sudo deploy/qr.sh [输出路径] [--refresh]
#   --refresh  先点一次 QQ 窗口里的「刷新」再截图（二维码过期后必须是新码才能扫）
#
# 为什么需要它：noVNC 只在回环（6081），公网不开。要么 SSH 隧道进 noVNC 现场扫码，
# 要么用这个脚本把二维码抓成 PNG 拉到本地扫。注意 QQ 的登录二维码约两分钟过期，
# 所以扫之前一定要么加 --refresh，要么确认这张是刚抓的。
set -euo pipefail

OUT=/tmp/snowluma-login.png
REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --refresh) REFRESH=1 ;;
    *) OUT=$arg ;;
  esac
done
DISPLAY_ID=${SNOWLUMA_DISPLAY:-:1}
# 「刷新」按钮的坐标按 1280x800 屏幕标定（见 snowluma-compose.yml 的 SNOWLUMA_SCREEN）
REFRESH_X=${QR_REFRESH_X:-647}
REFRESH_Y=${QR_REFRESH_Y:-442}

if [[ $REFRESH == 1 ]]; then
  if docker exec -u snowluma -e DISPLAY="$DISPLAY_ID" snowluma sh -lc 'command -v xdotool >/dev/null 2>&1'; then
    echo "-- 点击「刷新」重新出码"
    docker exec -u snowluma -e DISPLAY="$DISPLAY_ID" snowluma sh -lc \
      "xdotool mousemove $REFRESH_X $REFRESH_Y click 1"
    sleep 5
  else
    echo "-- 容器内没有 xdotool，跳过刷新（先跑 install-protocol.sh 装上）"
  fi
fi

docker exec -u snowluma -e DISPLAY="$DISPLAY_ID" snowluma sh -lc \
  'xwd -root -silent > /tmp/shot.xwd && ffmpeg -y -loglevel error -i /tmp/shot.xwd -pix_fmt rgb24 /tmp/shot.png'
docker cp snowluma:/tmp/shot.png "$OUT"
ls -lh "$OUT"
echo "已保存：$OUT（服务器时间 $(date '+%H:%M:%S')）"
echo "拉到本机： scp root@<服务器IP>:$OUT ."
echo "二维码约两分钟过期，扫之前确认是刚抓的。"

