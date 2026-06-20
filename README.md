# VPS sing-box 部署脚本

```bash
curl -fsSL https://raw.githubusercontent.com/syncmeta/singbox-script-for-vps/main/install.sh -o /tmp/singb-install.sh
bash /tmp/singb-install.sh
```

- TCP 流量走 Xray VLESS Reality Vision，默认端口 TCP/443
- 其他流量走 Hysteria2，默认端口 UDP/443

装完在 VPS 本地生成一个配置包：

```text
/root/singb/singb-profiles.zip
```

用 SSH 下载到本机：

```bash
scp root@VPS_IP:/root/singb/singb-profiles.zip .
```

压缩包里有 8 个配置：

文件名会加 VPS IP 前缀，例如 `VPS_IP-tun-split.json`：

- `VPS_IP-tun-global.json`：TUN 全局代理
- `VPS_IP-tun-split.json`：TUN 分流，国内域名/IP 白名单直连；TCP 走 Reality，UDP 走 Hysteria2
- `VPS_IP-tun-hy2-global.json`：TUN 全局代理，全部代理流量走 Hysteria2
- `VPS_IP-tun-hy2-split.json`：TUN 分流，国内域名/IP 白名单直连，其他流量走 Hysteria2
- `VPS_IP-proxy-global.json`：本地 mixed 代理，全局走 VLESS Reality
- `VPS_IP-proxy-split.json`：本地 mixed 代理，国内域名/IP 白名单直连
- `VPS_IP-proxy-hy2-global.json`：本地 mixed 代理，全局走 Hysteria2
- `VPS_IP-proxy-hy2-split.json`：本地 mixed 代理，国内域名/IP 白名单直连

iOS/SFM 优先导入 TUN 配置。通常先试 `VPS_IP-tun-hy2-global.json`；如果国内 App 明显绕远，再试 `VPS_IP-tun-hy2-split.json` 或原来的 `VPS_IP-tun-split.json`。

分流配置采用 direct whitelist、默认代理的模型：`.cn` / `.中国` / `.中國` 和 `cn-domain-whitelist` 命中的国内域名先用本地 DNS 解析，并直接走 `direct`；`cn-ip-whitelist` 继续作为 IP 兜底直连规则，避免没有域名信息或只能按 IP 判断的国内流量误走代理；其他流量默认走代理。`tun-split` 里 TCP 走 Reality、UDP 走 Hysteria2；`tun-hy2-split` 里非直连流量都走 Hysteria2。TUN 配置不再单独拦截 UDP/443。

为了兼容当前常见的 sing-box 1.13.x 客户端，规则集下载仍使用 `download_detour` 字段。它在新版本里已标记废弃，但 1.13.x 不认识 1.14+ 的 `http_client` 字段。

## 安装参数

如果脚本无法自动识别公网 IPv4：

```bash
bash /tmp/singb-install.sh --server-ip 你的服务器IP
```

## 需要开放的端口

- TCP/443：VLESS Reality
- UDP/443：Hysteria2

## 安装后的路径

```text
/usr/local/bin/singb
/etc/singb/config.env
/etc/singb/state.env
/root/singb/
/var/lib/singb/profiles/
/root/singb/singb-profiles.zip
```

`config.env` 保存可调整参数，比如服务器 IP 和 Reality SNI。

`state.env` 保存自动生成的密钥、UUID 和 Hysteria2 密码。

## 常用命令

查看配置包路径和 `scp` 下载命令：

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

编辑某个客户端配置并重新打包：

```bash
singb edit proxy-split
```

管理命令可以继续用短配置名；实际 JSON 文件名会自动带 VPS IP 前缀。

根据已保存密钥重新生成服务端和客户端配置：

```bash
singb regen
```

从 GitHub 更新 `singb` 管理脚本，并用现有密钥重新生成配置：

```bash
singb update
```

重新打包当前客户端配置。手动改过 `/var/lib/singb/profiles/*.json` 后，用这个命令刷新 zip：

```bash
singb bundle
```

重启服务：

```bash
singb restart
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

手动改 `/var/lib/singb/profiles/*.json` 后重新打包：

```bash
singb bundle
```

注意：`singb regen` 会按保存的状态重新生成所有客户端配置，所以手动改 JSON 后不要马上跑 `regen`，否则手动修改会被覆盖。

## 排错

macOS 或其他桌面客户端提示：

```text
route.rule_set[0].http_client: json: unknown field "http_client"
```

说明导入到客户端的 JSON 还是旧内容，里面含有 sing-box 1.14+ 才支持的 `http_client` 字段。用最新脚本在 VPS 上重新生成并打包：

```bash
singb regen
singb links
```

然后在客户端删除旧配置，重新导入 `VPS_IP-tun-split.json`。

如果客户端能导入但无法连接，先看 VPS：

```bash
singb status
singb logs
```

再确认服务商防火墙放行了 TCP/443 和 UDP/443。全设备代理优先试 `VPS_IP-tun-hy2-global.json` 或 `VPS_IP-tun-hy2-split.json`；`VPS_IP-proxy-split.json` 只是在本机暴露 `127.0.0.1:7890` mixed 代理。

## 安全

配置包里的 JSON 包含可用客户端凭据，只通过 SSH/SCP 等可信通道下载。

如果配置包可能已经被别人拿到，轮换节点密钥：

```bash
singb rotate-secrets
```
