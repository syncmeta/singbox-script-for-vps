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

After installation, the script prints eight import URLs:

```text
http://VPS_IP:8080/RANDOM_TOKEN/tun-global.json
http://VPS_IP:8080/RANDOM_TOKEN/tun-split.json
http://VPS_IP:8080/RANDOM_TOKEN/tun-legacy-global.json
http://VPS_IP:8080/RANDOM_TOKEN/tun-legacy-split.json
http://VPS_IP:8080/RANDOM_TOKEN/proxy-global.json
http://VPS_IP:8080/RANDOM_TOKEN/proxy-split.json
http://VPS_IP:8080/RANDOM_TOKEN/proxy-hy2-global.json
http://VPS_IP:8080/RANDOM_TOKEN/proxy-hy2-split.json
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

Modern TUN profile:

```text
tun-split.json
```

Legacy iOS fallback:

```text
tun-legacy-split.json
```

Hysteria2 proxy-only profile:

```text
proxy-hy2-split.json
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

Uninstall generated deployment files:

```bash
singbox-vps uninstall
```

Uninstall and remove Xray/Hysteria2 binaries too:

```bash
singbox-vps uninstall --purge-binaries
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
- `tun-legacy-global.json`: TUN mode, full proxy, legacy DNS format and no Hysteria2 certificate pin for old iOS clients
- `tun-legacy-split.json`: TUN mode, CN direct, legacy DNS format and no Hysteria2 certificate pin for old iOS clients
- `proxy-global.json`: local mixed proxy, VLESS Reality, full proxy
- `proxy-split.json`: local mixed proxy, VLESS Reality, CN direct
- `proxy-hy2-global.json`: local mixed proxy, Hysteria2, full proxy
- `proxy-hy2-split.json`: local mixed proxy, Hysteria2, CN direct

For iOS, start with:

```text
tun-split.json
```

If an older iOS client reports `dns.servers[0].type: unknown field "type"`, use `tun-legacy-split.json` instead.

The legacy TUN profiles also omit the Hysteria2 `certificate_public_key_sha256` pin because some older iOS builds do not recognize that field.

## Troubleshooting

If iOS reports:

```text
decode config:dns.servers[0].type:json:unknown field "type"
```

Use the legacy TUN fallback link:

```text
tun-legacy-split.json
```

If the legacy link is not available yet, regenerate profiles with the latest installer:

```bash
curl -fsSL https://raw.githubusercontent.com/syncmeta/singbox-script-for-vps/main/install.sh -o /tmp/singbox-vps-install.sh
bash /tmp/singbox-vps-install.sh
singbox-vps links
```

Then delete the old profile on iOS and import the new `tun-legacy-split.json` URL.

If iOS shows deprecation warnings about `legacy DNS servers` or missing `route.default_domain_resolver`, import `tun-split.json` instead of `tun-legacy-split.json`.

If iOS reports `outbounds[1].tls.certificate_public_key_sha256: unknown field`, regenerate profiles and import `tun-legacy-split.json`.

If a desktop client can import a profile but cannot connect, check the VPS first:

```bash
singbox-vps status
singbox-vps logs
```

Confirm that the provider firewall allows TCP/443 and UDP/443. For desktop full-device routing, use `tun-split.json` first; `proxy-split.json` only exposes a local mixed proxy on `127.0.0.1:7890`.

If you want to test Hysteria2 without TUN, import `proxy-hy2-split.json`; it also exposes a local mixed proxy on `127.0.0.1:7890`.

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
