# singb

一键在 VPS 上部署：

- Xray VLESS Reality Vision，默认 TCP/443
- Hysteria2，默认 UDP/443
- sing-box 客户端 JSON 配置
- `singb` 管理命令，用来查看链接、重新生成配置、编辑配置、轮换 token

## 快速安装

在 Debian/Ubuntu VPS 上用 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/syncmeta/singbox-script-for-vps/main/install.sh -o /tmp/singb-install.sh
bash /tmp/singb-install.sh
```

如果服务商防火墙不方便开放 8080，可以换远程配置下载端口：

```bash
bash /tmp/singb-install.sh --publish-port 18080
```

如果脚本无法自动识别公网 IPv4：

```bash
bash /tmp/singb-install.sh --server-ip 你的服务器IP
```

## 需要开放的端口

- TCP/443：VLESS Reality
- UDP/443：Hysteria2
- TCP/8080：远程下载 JSON 配置，只有导入配置时用；可通过 `--publish-port` 修改

## 安装后的路径

```text
/usr/local/bin/singb
/etc/singb/config.env
/etc/singb/state.env
/root/singb/
/var/lib/singb/profiles/
/var/www/singb/<随机token>/
/etc/systemd/system/singb-profile-server.service
```

`config.env` 保存可调整参数，比如服务器 IP、Reality SNI、发布端口。

`state.env` 保存自动生成的密钥、UUID、Hysteria2 密码和远程配置 token。

## 远程导入链接

安装完成后会输出 6 个 JSON 配置链接：

```text
http://VPS_IP:8080/RANDOM_TOKEN/tun-global.json
http://VPS_IP:8080/RANDOM_TOKEN/tun-split.json
http://VPS_IP:8080/RANDOM_TOKEN/proxy-global.json
http://VPS_IP:8080/RANDOM_TOKEN/proxy-split.json
http://VPS_IP:8080/RANDOM_TOKEN/proxy-hy2-global.json
http://VPS_IP:8080/RANDOM_TOKEN/proxy-hy2-split.json
```

`8080` 只是下载 JSON 配置的 HTTP 端口，不是代理端口。真正代理流量走 TCP/443 的 VLESS Reality 或 UDP/443 的 Hysteria2。

推荐先导入：

```text
tun-split.json
```

桌面端只想开本地 mixed 代理时，用：

```text
proxy-split.json
```

## 配置说明

- `tun-global.json`：TUN 全局代理
- `tun-split.json`：TUN 分流，国内域名/IP 直连
- `proxy-global.json`：本地 mixed 代理，全局走 VLESS Reality
- `proxy-split.json`：本地 mixed 代理，国内域名/IP 直连
- `proxy-hy2-global.json`：本地 mixed 代理，全局走 Hysteria2
- `proxy-hy2-split.json`：本地 mixed 代理，国内域名/IP 直连

分流配置使用 `geosite-cn` 和 `geoip-cn` 规则集。TUN 分流还会把国内域名规则交给本地 DNS 解析，并在兜底代理规则前启用 sniff，让按 IP 建连的国内流量也尽量保持直连。

为了兼容当前常见的 sing-box 1.13.x 客户端，规则集下载仍使用 `download_detour` 字段。它在新版本里已标记废弃，但 1.13.x 不认识 1.14+ 的 `http_client` 字段。

## 常用命令

查看远程导入链接：

```bash
singb links
```

查看服务和端口状态：

```bash
singb status
```

查看配置路径和当前参数：

```bash
singb config
```

列出本地生成的客户端配置：

```bash
singb profiles
```

编辑某个客户端配置并重新发布：

```bash
singb edit proxy-split
```

根据已保存密钥重新生成服务端和客户端配置：

```bash
singb regen
```

只重新发布当前客户端配置：

```bash
singb publish
```

重启服务：

```bash
singb restart
```

只更换远程配置链接 token：

```bash
singb rotate-token
```

重新生成节点密钥和客户端配置：

```bash
singb rotate-secrets
```

查看最近日志：

```bash
singb logs
```

卸载：

```bash
singb uninstall
```

卸载并删除 Xray/Hysteria2 程序：

```bash
singb uninstall --purge-binaries
```

## 修改配置

修改 VPS 基础参数：

```bash
nano /etc/singb/config.env
singb regen
```

直接微调某个客户端 JSON：

```bash
singb edit proxy-split
```

手动改 `/var/lib/singb/profiles/*.json` 后重新发布：

```bash
singb publish
```

注意：`singb regen` 会按保存的状态重新生成所有客户端配置，所以手动改 JSON 后不要马上跑 `regen`，否则手动修改会被覆盖。

## 排错

macOS 或其他桌面客户端提示：

```text
route.rule_set[0].http_client: json: unknown field "http_client"
```

说明导入到客户端的 JSON 还是旧发布内容，里面含有 sing-box 1.14+ 才支持的 `http_client` 字段。用最新脚本在 VPS 上重新生成并发布：

```bash
singb regen
singb links
```

然后在客户端删除旧配置，重新导入 `tun-split.json`。

如果客户端能导入但无法连接，先看 VPS：

```bash
singb status
singb logs
```

再确认服务商防火墙放行了 TCP/443 和 UDP/443。全设备代理优先用 `tun-split.json`；`proxy-split.json` 只是在本机暴露 `127.0.0.1:7890` mixed 代理。

## 安全

远程配置 URL 里的 JSON 包含可用客户端凭据，随机 token 不要泄露。

如果只是 URL 泄露，轮换 token：

```bash
singb rotate-token
```

如果配置可能已经被别人导入，连节点密钥一起轮换：

```bash
singb rotate-secrets
```

`examples/` 里的 JSON 只是示例。真实配置在 VPS 安装或 `singb regen` 时生成。
