#!/usr/bin/env bash
# 抓取 SnowLuma 容器里 QQ 登录界面的截图（含二维码），落到宿主机文件
#
# 用法：sudo deploy/qr.sh [输出路径]        # 默认 /tmp/snowluma-login.png
#
# 为什么需要它：noVNC 只在回环（6081），公网不开。要么 SSH 隧道进 noVNC 现场扫码，
# 要么用这个脚本把二维码抓成 PNG 拉到本地扫。注意 QQ 的登录二维码约两分钟过期，
# 失效就重跑一次。
set -euo pipefail

OUT=${1:-/tmp/snowluma-login.png}
DISPLAY_ID=${SNOWLUMA_DISPLAY:-:1}

docker exec -u snowluma -e DISPLAY="$DISPLAY_ID" snowluma sh -lc \
  'xwd -root -silent > /tmp/shot.xwd && ffmpeg -y -loglevel error -i /tmp/shot.xwd -pix_fmt rgb24 /tmp/shot.png'
docker cp snowluma:/tmp/shot.png "$OUT"
ls -lh "$OUT"
echo "已保存：$OUT"
echo "拉到本机： scp root@<服务器IP>:$OUT ."
echo "二维码约两分钟过期，扫之前确认是刚抓的。"
