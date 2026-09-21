# QQ Agent 在 Linux 上的部署（nginx + HTTPS + systemd）

针对单台阿里云 ECS（Alibaba Cloud Linux 3 / RHEL 系）的 headless 部署。桌面版 Electron 壳不使用。

## 架构

```
浏览器 ──HTTPS(443)──> nginx ──┬─ 静态页面：/opt/qq-agent/ui/*
   (Basic Auth)                └─ /api/* 与 /api/events(SSE) ──> 127.0.0.1:3210
                                                                    ↑
                                                    systemd: qq-agent（Node，headless）
                                                                    │
                                    OneBot v11 正向 WS/HTTP ─────────┘
                                    ws://127.0.0.1:3001 / http://127.0.0.1:3000
                                                                    ↑
                                                        协议端（QQ 侧，另装）
```

三个关键约束（都来自上游代码，改造前先读 `src/app.js`）：

1. `server.listen(port, '127.0.0.1')` 是硬编码回环 —— nginx 必须和应用同机。
2. 后端没有任何 CORS 头，也没有 OPTIONS 预检处理 —— 前端必须与 API 同源，所以静态页和 `/api` 走同一个域名。
3. 后端的鉴权与内置前端是错位的：前端永远只送常量 `x-console-token: qq-agent-console`，`authorize()` 却拿它跟 `server.token` 比；而 `EventSource('/api/events')` 又不带 token。**一旦设置 `server.token`，内置控制台全部 401 变砖。** 因此保持 `server.token` 留空，访问控制交给 nginx 的 `auth_basic`。

## 前置条件

| 项 | 说明 |
| --- | --- |
| Node | >= 20（本机是宝塔装的 v24.19.0，脚本用 `readlink -f` 固定绝对路径，避免切版本失效） |
| nginx | 脚本用 `dnf install --disableexcludes=all nginx` 安装。宝塔改过 `/etc/dnf/dnf.conf`，里面 `exclude=httpd nginx php mysql ...`，不加参数会报 "filtered out by exclude filtering" |
| 内存 | **协议端（QQ 客户端系）比应用本体重得多。** 应用约 150MB；SnowLuma 容器（Linux QQ + Xvfb + VNC + supervisord）通常 900MB 起。2G 机器上同时跑 MySQL 与宝塔时余量不足，内核 OOM 有可能杀掉 MySQL |
| 阿里云安全组 | 放行 443（用 certbot 才需要 80）。`3210 / 3000 / 3001 / 5099 / 6081` 一律不要放行 |
| ICP 备案 | 中国大陆 ECS 用域名对外提供 web 服务必须先备案，否则阿里云会拦 80/443 |
| DNS | 一条 A 记录指向 ECS 公网 IP，域名必须与证书域名一致 |

## 步骤

```bash
# 0. 变量（改域名/证书路径/控制台账号密码）
mkdir -p /etc/qq-agent
cp deploy/deploy.conf.example /etc/qq-agent/deploy.conf
chmod 600 /etc/qq-agent/deploy.conf
vi /etc/qq-agent/deploy.conf

# 1. 应用本体（clone + npm install --omit=dev + systemd）
sudo deploy/install-app.sh

# 2. 阿里云证书：控制台申请签发后下载 "Nginx" 版，得到 <域名>.pem 与 <域名>.key，
#    放到 deploy.conf 里 CERT_PEM / CERT_KEY 指定的路径（默认 /etc/nginx/certs/）。
#    证书还没下来时可以用自签证书先把链路验证通：
sudo deploy/install-nginx.sh --selfsigned

# 3. 正式证书放好后重跑（会覆盖自签证书）
sudo deploy/install-nginx.sh

# 4. 自检
sudo deploy/verify.sh
```

## 协议端（必须另装，应用自己拉不起）

上游仓库不含协议端，且 `src/app.js` 的 `launchSnowluma()` 只认 Windows 的 `node.exe` / `cmd.exe /c launcher.bat`，
`/api/snowluma/open-folder`（`explorer.exe`）与 `open-webui`（`cmd.exe /c start`）在 Linux 上都会报错——
但都是可选按钮，不影响机器人本体。所以 Linux 上：

- 保持 `snowluma.autoLaunch = false`；
- 自己把协议端跑起来，让 `ws://127.0.0.1:3001` 与 `http://127.0.0.1:3000` 可达；
- 在控制台「设置 → OneBot」里核对地址与令牌。

本方案选 **SnowLuma 官方 Docker**（`deploy/snowluma-compose.yml` + `deploy/install-protocol.sh`），原因：

| 候选 | 结论 |
| --- | --- |
| SnowLuma Docker | 官方唯一正式支持的 Linux 路径，跑的是真实 Linux QQ（协议行为最接近正常客户端，风控风险最低），OneBot v11 支持完整。代价是内存：Linux QQ + Xvfb + VNC + supervisord 常驻约 900MB–1.5GB |
| Lagrange.OneBot | 纯协议重实现，只要 ~200–300MB，终端出二维码，本可完美适配小内存机器。**但 V1 已 sunset**（Lagrange.Core 主分支已切到 V2，V2 提供的是 Milky 协议而非 OneBot v11），nightly 构建停留在 2025-08，登录成功率无保证，故未采用 |
| NapCat / LLOneBot | NapCat 的 Linux 形态同样需要 QQ 客户端（内存与 SnowLuma 同级），LLOneBot 仅 Windows |

因此这台 99 计划的 2G 机器用 `mem_limit: 1300m` + `memswap_limit: 1900m` 硬扛：内存打满时优先牺牲容器，不拖垮 nginx 与 qq-agent。
若实测不稳，唯一干净的解法是升配内存（2G→4G），或在别处跑协议端再把地址指过来（需公网 TLS + 令牌，风险更高，不推荐）。

扫码登录（noVNC 只在回环，公网不开，走 SSH 隧道）：

```bash
ssh -L 6081:127.0.0.1:6081 root@<服务器IP>
# 浏览器打开 http://127.0.0.1:6081/vnc.html，输入 deploy.conf 里的 VNC_PASSWD
# 远程桌面里 QQ 已自动启动，手机 QQ 扫码即可
```

不想开隧道也可以直接把二维码抓成图片（容器里有 xwd + ffmpeg，本脚本已封装）：

```bash
sudo deploy/qr.sh --refresh             # 先点「刷新」出新码，再截到 /tmp/snowluma-login.png
scp root@<服务器IP>:/tmp/snowluma-login.png .   # 拉到本机扫
```

`--refresh` 靠容器内的 xdotool 点 QQ 窗口的「刷新」按钮（坐标按 1280x800 标定，可用
`QR_REFRESH_X/QR_REFRESH_Y` 覆盖）；没有 xdotool 时只能 `docker restart snowluma` 让它
重出一次码。二维码约两分钟过期，过期就再跑一次。登录成功后登录态落在 `qq-client-data`
卷里，之后重启容器不必重新扫码。

**登录后还要让 qq-agent 拿到令牌**：SnowLuma 给每个登录过的账号生成独立的随机 accessToken，
存在容器数据卷的 `config/onebot_<uin>.json` 里。qq-agent 的自动同步逻辑是去读
`snowluma.dir` 下的 `config/onebot_*.json`，所以这个配置必须指向容器数据卷：

```
snowluma.dir = /var/lib/docker/volumes/qq-gateway-data/_data
```

`install-app.sh` 写初始配置时已经带上这个值，控制台「设置 → SnowLuma 目录」里也能改。
留空的话 qq-agent 读不到令牌，OneBot 会一直报 `401 unauthorized`——协议端跑在 Docker 里，
它的 `config/` 不在项目目录，靠"项目内 ./snowluma 自动探测"是探测不到的（实测踩过）。

## 排障

| 现象 | 原因与处理 |
| --- | --- |
| 控制台能打开但一直转圈 | `/api/events` 被 nginx 缓冲：确认 `proxy_buffering off` 与 `proxy_read_timeout` 已生效 |
| 所有接口 401 | 你设了 `server.token`。内置前端只送常量 `qq-agent-console`，请把它清空，用 nginx 鉴权 |
| `dnf install nginx` 报 filtered out | 宝塔写的 `exclude=`，加 `--disableexcludes=all` |
| 页面能开、机器人不回消息 | 协议端没起来。`ss -lntp \| grep -E '3000\|3001'`，看 `journalctl -u qq-agent` 里的 `ECONNREFUSED 127.0.0.1:3001` |
| OneBot 报 `401 unauthorized` | 令牌没同步：把 `snowluma.dir` 指向容器数据卷 `/var/lib/docker/volumes/qq-gateway-data/_data`（详见上一节）。注意宿主机端口被 docker-proxy 占着，端口"可达"并不代表能用 |
| 群里 @ 机器人没反应 | 白名单为空。控制台「设置 → 白名单」里勾群，或打开 `allowAllWhenEmpty` |
| 服务器突然变卡/MySQL 挂掉 | 内存打满触发 OOM。给容器或协议端设 `MemoryMax=`，或升级 ECS 内存 |
| 宝塔面板要装它自己的 nginx | 会与系统 nginx 抢 80/443。二选一：一直用系统 nginx（本方案），或改用宝塔的 nginx 并自行维护这份站点配置 |

## 回滚

```bash
systemctl disable --now qq-agent
rm -f /etc/systemd/system/qq-agent.service && systemctl daemon-reload
rm -f /etc/nginx/conf.d/qq-agent.conf
mv /etc/nginx/conf.d/default.conf.disabled /etc/nginx/conf.d/default.conf 2>/dev/null || true
nginx -t && systemctl reload nginx
# 数据与代码保留在 /var/lib/qq-agent 与 /opt/qq-agent，确认无误后再删
```
