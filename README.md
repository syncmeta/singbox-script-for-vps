# singbox-script-for-vps

One-command VPS setup for:

- Xray VLESS Reality Vision on TCP/443
- Hysteria2 on UDP/443
- sing-box client profiles for remote import
- A persistent `singbox-vps` command to view links, regenerate profiles, edit profiles, and rotate the publish token

## Quick Start

Run as root on a fresh Debian/Ubuntu VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/install.sh -o /tmp/singbox-vps-install.sh
bash /tmp/singbox-vps-install.sh
```

If your provider firewall uses a different HTTP import port:

```bash
bash /tmp/singbox-vps-install.sh --publish-port 18080
```

If public IPv4 detection fails:

```bash
bash /tmp/singbox-vps-install.sh --server-ip YOUR_SERVER_IP
```

## Requirements

- Debian/Ubuntu-like Linux with systemd
- Root access
- TCP/443 open for VLESS Reality
- UDP/443 open for Hysteria2
- TCP/8080 open for remote sing-box profile import, unless changed with `--publish-port`

## What Gets Installed

The installer creates:

```text
/usr/local/bin/singbox-vps
/etc/singbox-vps/config.env
/etc/singbox-vps/state.env
/root/singbox-vps/
/var/lib/singbox-vps/profiles/
/var/www/singbox-vps/<random-token>/
/etc/systemd/system/singbox-vps-profile-server.service
```

`config.env` stores editable settings such as the server IP, Reality SNI, and publish port.

`state.env` stores generated secrets such as UUIDs, Reality keys, Hysteria2 passwords, and the publish token.

## Import Links

After installation, the script prints four import URLs:

```text
http://VPS_IP:8080/RANDOM_TOKEN/tun-global.json
http://VPS_IP:8080/RANDOM_TOKEN/tun-split.json
http://VPS_IP:8080/RANDOM_TOKEN/proxy-global.json
http://VPS_IP:8080/RANDOM_TOKEN/proxy-split.json
```

Use those URLs in SFM or any sing-box client that supports remote profile import.

To view the links again later:

```bash
singbox-vps links
```

Recommended first profile:

```text
proxy-split.json
```

## Management

Show current links:

```bash
singbox-vps links
```

Show service status and listeners:

```bash
singbox-vps status
```

Show config file locations and current settings:

```bash
singbox-vps config
```

Edit a generated client profile and republish it:

```bash
singbox-vps edit proxy-split
```

Regenerate server and client configs from saved state:

```bash
singbox-vps regen
```

Restart services:

```bash
singbox-vps restart
```

Rotate only the remote import URL token:

```bash
singbox-vps rotate-token
```

Regenerate node credentials and profiles:

```bash
singbox-vps rotate-secrets
```

Show recent logs:

```bash
singbox-vps logs
```

## Editing Settings

For normal settings, edit:

```bash
nano /etc/singbox-vps/config.env
singbox-vps regen
```

For direct client profile edits, use:

```bash
singbox-vps edit proxy-split
```

Manual edits in `/var/lib/singbox-vps/profiles/*.json` are republished by:

```bash
singbox-vps publish
```

`singbox-vps regen` rewrites generated profiles from the saved state, so use `edit` or `publish` for manual profile tweaks.

## Profile Types

- `tun-global.json`: TUN mode, full proxy
- `tun-split.json`: TUN mode, CN direct
- `proxy-global.json`: local mixed proxy, full proxy
- `proxy-split.json`: local mixed proxy, CN direct

## Security Notes

Remote profile URLs contain usable client credentials inside the JSON. Keep the random token private.

If a URL was exposed and you only need to disable the old URL, rotate the URL token:

```bash
singbox-vps rotate-token
```

If the exposed URL may already have been opened or imported, rotate node secrets too:

```bash
singbox-vps rotate-secrets
```

The JSON files in this repository are reference examples only. Real profiles are generated on the VPS during installation.
