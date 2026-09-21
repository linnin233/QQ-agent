#!/usr/bin/env bash
# 从「蓝色大肥鱼 · AI 娘表情包开放档案」导入表情包到 qq-agent 的表情库
#
# 为什么需要它
#   1. qq-agent 的表情库只有两个来源：同步 QQ 收藏表情、AI 用 collect_sticker 收藏群消息，
#      没有"手动放图"的入口。但数据层其实早就支持 source='manual'
#      —— stickers.js 的 mergeStickerLibrary 只清理 source==='qq' 的条目，
#      manual / ai 条目不会被 QQ 同步冲掉。所以直接写 stickers.json 是安全的。
#   2. OneBot 发图是 {type:'image', data:{file:<url>}}，**由协议端去下载这张图**。
#      所以图片必须放在协议端能访问到的公网地址上；本方案用 nginx 的 /stickers/
#      （见 nginx/qq-agent.conf.tmpl，注意那里必须 auth_basic off）。
#
# 依赖：curl（下载）。转格式需要 docker 里的 ffmpeg（SnowLuma 镜像自带）。
# 注意：宿主机 Python 是 3.6，urllib 对 IDN 主机名的证书校验会失败，所以下载用 curl 而不是 Python。
#
# 用法：
#   ./stickers-import.sh                 # 只下载 + 写库（保持 webp）
#   ./stickers-import.sh --convert       # 额外用容器里的 ffmpeg 转成 png 再写库
#   SITE=... WORK=... BASE=... ./stickers-import.sh
set -euo pipefail

SITE="${SITE:-https://xn--pssy23gqgbz2d718b.com}"
MANIFEST="${MANIFEST:-$SITE/data/blue-fish-classification.json}"
WORK="${WORK:-/var/lib/qq-agent/stickers}"
STORE="${STORE:-/var/lib/qq-agent/stickers.json}"
BASE="${BASE:-https://qq.linnin.cn/stickers}"
SERVICE="${SERVICE:-qq-agent}"
CONVERT=0
[ "${1:-}" = "--convert" ] && CONVERT=1

mkdir -p "$WORK" /tmp/bluefish

echo "== 1/5 拉清单 =="
curl -sS -m 60 -o /tmp/bluefish/classification.json "$MANIFEST"
python3 - <<'PY'
import json, os
SITE = os.environ.get('SITE', 'https://xn--pssy23gqgbz2d718b.com')
meta = json.load(open('/tmp/bluefish/classification.json', encoding='utf-8'))
rows, entries = [], []
for m in meta:
    p = str(m.get('previewPath') or '').strip()
    if not p or not p.lower().endswith('.webp'):
        continue
    fn = os.path.basename(p)
    rows.append((f"{SITE}/data/blue-fish/{p.lstrip('/')}", fn))
    entries.append({'file': fn, 'name': (m.get('name') or '').strip(),
                    'tags': [str(t).strip() for t in (m.get('tags') or []) if str(t).strip()]})
open('/tmp/bluefish/dl.tsv', 'w', encoding='utf-8').write(''.join(f"{u}\t{f}\n" for u, f in rows))
json.dump(entries, open('/tmp/bluefish/entries.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print(f"  清单 {len(meta)} 条 -> 待下载 {len(rows)} 张")
PY

echo "== 2/5 下载（curl 4 并发） =="
cat > /tmp/bluefish/dl1.sh <<'EOS'
#!/bin/bash
url="$1"; fn="$2"
cd "$WORK" || exit 1
[ -s "$fn" ] && exit 0
curl -sS -m 90 -o "$fn" "$url" 2>/dev/null
[ -s "$fn" ] || { echo "FAIL $fn"; rm -f "$fn"; }
EOS
chmod +x /tmp/bluefish/dl1.sh
tr '\t' '\n' < /tmp/bluefish/dl.tsv | xargs -P 4 -n 2 env WORK="$WORK" /tmp/bluefish/dl1.sh
echo "  已下载 $(ls -1 "$WORK" | wc -l) 张，占用 $(du -sh "$WORK" | cut -f1)"

EXT=webp
if [ "$CONVERT" = "1" ]; then
  echo "== 3/5 转 png（用 SnowLuma 容器里的 ffmpeg，宿主机没有转换工具） =="
  docker run --rm --entrypoint sh -v "$WORK":/w motricseven7/snowluma:latest -c \
    'cd /w && for f in *.webp; do [ -f "${f%.webp}.png" ] || ffmpeg -loglevel error -y -i "$f" "${f%.webp}.png"; done'
  EXT=png
  echo "  转换完成，png $(ls -1 "$WORK"/*.png 2>/dev/null | wc -l) 张"
else
  echo "== 3/5 跳过转换 =="
fi

echo "== 4/5 生成 stickers.json =="
python3 - "$EXT" "$BASE" <<'PY'
import json, os, sys, datetime
ext, base = sys.argv[1], sys.argv[2]
WORK = os.environ.get('WORK', '/var/lib/qq-agent/stickers')
meta = json.load(open('/tmp/bluefish/entries.json', encoding='utf-8'))
now = datetime.datetime.now().astimezone().replace(microsecond=0).isoformat()
out = []
for m in meta:
    stem = os.path.splitext(m['file'])[0]
    fn = stem + '.' + ext
    if not os.path.exists(os.path.join(WORK, fn)):
        continue
    name = (m.get('name') or '').strip()
    tags = (m.get('tags') or [])[:8]
    desc = name if name else ('AI 娘表情' + ('：' + '/'.join(tags[:3]) if tags else ''))
    out.append({'id': 'bf_' + stem[:16], 'resId': 'bf_' + stem[:16],
                'url': base + '/' + fn, 'md5': stem.upper(), 'desc': desc[:40],
                'localNote': '', 'tags': tags, 'usage': '', 'source': 'manual',
                'useCount': 0, 'lastUsedAt': 0, 'lastContext': '',
                'createdAt': now, 'updatedAt': now})
json.dump(out, open('/tmp/bluefish/stickers.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print(f"  生成 {len(out)} 条")
PY

echo "== 5/5 停服 -> 写库 -> 起服 =="
# 必须先停服：运行中的 StickerManager 内存里持有启动时的列表，
# 每次 sync 都会把内存列表 save 回磁盘，跑着的时候写文件会被它覆盖。
cp -a "$STORE" "$STORE.bak-$(date +%Y%m%d-%H%M%S)"
systemctl stop "$SERVICE"
cp /tmp/bluefish/stickers.json "$STORE"
systemctl start "$SERVICE"
sleep 6
echo "  服务状态: $(systemctl is-active "$SERVICE")"
echo "  库内条目: $(python3 -c "import json;print(len(json.load(open('$STORE'))))")"
