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
`export all` 里的 `/api/snowluma/open-folder`（`explorer.exe`）与 `open-webui`（`cmd.exe /c start`）在 Linux 上都会报错——
但都是可选按钮，不影响机器人本体。所以 Linux 上：

- 保持 `snowluma.autoLaunch = false`；
- 自己把协议端跑起来，让 `ws://127.0.0.1:3001` 与 `http://127.0.0.1:3000` 可达；
- 在控制台「设置 → OneBot」里核对地址与令牌。

两种可选方案（内存是决定性因素）：

| 方案 | 内存 | 扫码登录 | 说明 |
| --- | --- | --- | --- |
| SnowLuma 官方 Docker（官方推荐路径） | 900MB ~ 1.5GB | 需要图形通道：容器内 noVNC（6081）走 SSH 隧道，或浏览器访问 | 必须 `--cap-add=SYS_PTRACE --security-opt seccomp=unconfined`，`--shm-size=1g`；镜像来自 Docker Hub，直连不通时用镜像站 |
| Lagrange（协议重实现，自包含二进制） | 约 200 ~ 300MB | 终端/日志输出二维码图片路径，纯命令行 | 不需要 QQ 客户端、不需要 Xvfb/VNC，适合 2G 机器；但属于协议重实现，风控/封号风险相对更高，OneBot v11 兼容性需实测 |

## 排障

| 现象 | 原因与处理 |
| --- | --- |
| 控制台能打开但一直转圈 | `/api/events` 被 nginx 缓冲：确认 `proxy_buffering off` 与 `proxy_read_timeout` 已生效 |
| 所有接口 401 | 你设了 `server.token`。内置前端只送常量 `qq-agent-console`，请把它清空，用 nginx 鉴权 |
| `dnf install nginx` 报 filtered out | 宝塔写的 `exclude=`，加 `--disableexcludes=all` |
| 页面能开、机器人不回消息 | 协议端没起来。`ss -lntp \| grep -E '3000\|3001'`，看 `journalctl -u qq-agent` 里的 `ECONNREFUSED 127.0.0.1:3001` |
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
