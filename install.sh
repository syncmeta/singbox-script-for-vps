#!/usr/bin/env bash
set -euo pipefail

MANAGER_BIN="/usr/local/bin/singbox-vps"

usage() {
  cat <<'EOF'
Usage:
  bash install.sh [options]

Install Xray + Hysteria2 on a fresh Debian/Ubuntu VPS, generate sing-box
client profiles, publish import URLs, and install the singbox-vps manager.

Options:
  --publish-port PORT       HTTP port for remote profile import. Default: 8080
  --out-dir DIR             Private output dir. Default: /root/singbox-vps
  --server-ip IP            Override public IPv4 detection
  --xray-sni DOMAIN         Reality SNI. Default: www.cloudflare.com
  --xray-dest HOST:PORT     Reality dest. Default: www.cloudflare.com:443
  --no-publish              Do not expose profile URLs over HTTP
  -h, --help                Show this help

After install:
  singbox-vps links
  singbox-vps status
  singbox-vps edit proxy-split
  singbox-vps regen

Maintenance:
  bash install.sh uninstall [--purge-binaries]
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(id -u)" != "0" ]]; then
  echo "Run this installer as root on the VPS." >&2
  exit 1
fi

write_manager() {
  install -d -m 755 "$(dirname "$MANAGER_BIN")"
  cat > "$MANAGER_BIN" <<'MANAGER_EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="singbox-vps"
CONFIG_DIR="/etc/singbox-vps"
CONFIG_FILE="$CONFIG_DIR/config.env"
STATE_FILE="$CONFIG_DIR/state.env"
PRIVATE_DIR="/root/singbox-vps"
PROFILE_DIR="/var/lib/singbox-vps/profiles"
PROFILE_WEB_ROOT="/var/www/singbox-vps"
PROFILE_SERVICE="/etc/systemd/system/singbox-vps-profile-server.service"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
HY2_CONFIG="/etc/hysteria/config.yaml"

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "Run as root."
}

quote_value() {
  printf '%q' "$1"
}

write_env_var() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "$key" "$(quote_value "$value")"
}

usage() {
  cat <<'EOF'
Usage:
  singbox-vps <command> [options]

Commands:
  install [options]         Install or repair the VPS deployment
  uninstall [options]       Stop services and remove generated deployment files
  links                     Show remote sing-box profile import URLs
  status                    Show service and listener status
  config                    Show config files and current settings
  profiles                  List generated local profile files
  edit <profile>            Edit a generated profile, then republish it
  regen                     Regenerate server/client configs from saved state
  publish                   Republish current generated profiles
  restart                   Restart Xray, Hysteria2, and profile server
  rotate-token              Replace only the remote profile URL token
  rotate-secrets            Regenerate node credentials and profiles
  logs                      Show recent service logs
  help                      Show this help

Profiles:
  tun-global
  tun-split
  proxy-global
  proxy-split

Install options:
  --publish-port PORT       HTTP port for remote profile import. Default: 8080
  --out-dir DIR             Private output dir. Default: /root/singbox-vps
  --server-ip IP            Override public IPv4 detection
  --xray-sni DOMAIN         Reality SNI. Default: www.cloudflare.com
  --xray-dest HOST:PORT     Reality dest. Default: www.cloudflare.com:443
  --no-publish              Do not expose profile URLs over HTTP

Uninstall options:
  --purge-binaries          Also remove Xray and Hysteria2 binaries/service units
EOF
}

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

detect_os() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      case " ${ID_LIKE:-} " in
        *" debian "*) ;;
        *) die "Unsupported OS: ${PRETTY_NAME:-unknown}. Use Debian or Ubuntu." ;;
      esac
      ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "systemd is required."
  command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
}

detect_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  printf '%s' "$ip"
}

init_defaults() {
  SERVER_IP="${SERVER_IP:-}"
  PUBLISH_PORT="${PUBLISH_PORT:-8080}"
  PUBLISH_ENABLED="${PUBLISH_ENABLED:-1}"
  XRAY_SNI="${XRAY_SNI:-www.cloudflare.com}"
  XRAY_DEST="${XRAY_DEST:-www.cloudflare.com:443}"
  PRIVATE_DIR="${PRIVATE_DIR:-/root/singbox-vps}"
  PROFILE_DIR="${PROFILE_DIR:-/var/lib/singbox-vps/profiles}"
  PROFILE_WEB_ROOT="${PROFILE_WEB_ROOT:-/var/www/singbox-vps}"
  XRAY_PORT="${XRAY_PORT:-443}"
  HY2_PORT="${HY2_PORT:-443}"
  HY2_OBFS_TYPE="${HY2_OBFS_TYPE:-salamander}"
}

load_config() {
  init_defaults
  if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  if [[ -r "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
  init_defaults
}

write_config_file() {
  install -d -m 700 "$CONFIG_DIR"
  {
    write_env_var SERVER_IP "$SERVER_IP"
    write_env_var PUBLISH_PORT "$PUBLISH_PORT"
    write_env_var PUBLISH_ENABLED "$PUBLISH_ENABLED"
    write_env_var XRAY_SNI "$XRAY_SNI"
    write_env_var XRAY_DEST "$XRAY_DEST"
    write_env_var PRIVATE_DIR "$PRIVATE_DIR"
    write_env_var PROFILE_DIR "$PROFILE_DIR"
    write_env_var PROFILE_WEB_ROOT "$PROFILE_WEB_ROOT"
    write_env_var XRAY_PORT "$XRAY_PORT"
    write_env_var HY2_PORT "$HY2_PORT"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

write_state_file() {
  install -d -m 700 "$CONFIG_DIR"
  {
    write_env_var XRAY_UUID "$XRAY_UUID"
    write_env_var XRAY_PRIVATE_KEY "$XRAY_PRIVATE_KEY"
    write_env_var XRAY_PUBLIC_KEY "$XRAY_PUBLIC_KEY"
    write_env_var XRAY_SHORT_ID "$XRAY_SHORT_ID"
    write_env_var HY2_PASSWORD "$HY2_PASSWORD"
    write_env_var HY2_OBFS_TYPE "$HY2_OBFS_TYPE"
    write_env_var HY2_OBFS_PASSWORD "$HY2_OBFS_PASSWORD"
    write_env_var HY2_TLS_PIN_SHA256 "$HY2_TLS_PIN_SHA256"
    write_env_var HY2_TLS_CERT_PUBKEY_SHA256 "$HY2_TLS_CERT_PUBKEY_SHA256"
    write_env_var PROFILE_TOKEN "$PROFILE_TOKEN"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

install_packages() {
  info "Installing base packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gawk \
    iproute2 \
    lsof \
    openssl \
    python3 \
    unzip
}

remove_path() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf -- "$path"
  fi
}

uninstall_command() {
  local purge_binaries=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge-binaries)
        purge_binaries=1
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  singbox-vps uninstall [--purge-binaries]

Stops singbox-vps services and removes generated config/profile files.
By default it keeps Xray and Hysteria2 binaries in place so reinstall is faster.
EOF
        return 0
        ;;
      *)
        die "Unknown uninstall option: $1"
        ;;
    esac
  done

  require_root
  info "Stopping services"
  systemctl disable --now "$(basename "$PROFILE_SERVICE")" >/dev/null 2>&1 || true
  systemctl disable --now xray >/dev/null 2>&1 || true
  systemctl disable --now hysteria-server >/dev/null 2>&1 || true

  info "Removing singbox-vps generated files"
  remove_path "$PROFILE_SERVICE"
  remove_path "$CONFIG_DIR"
  remove_path "$PRIVATE_DIR"
  remove_path "$PROFILE_DIR"
  remove_path "$PROFILE_WEB_ROOT"
  remove_path /etc/sysctl.d/99-singbox-vps-bbr.conf

  if (( purge_binaries == 1 )); then
    info "Removing Xray and Hysteria2 binaries/service files"
    remove_path /usr/local/bin/xray
    remove_path /usr/local/share/xray
    remove_path /usr/local/etc/xray
    remove_path /var/log/xray
    remove_path /etc/systemd/system/xray.service
    remove_path /etc/systemd/system/xray@.service
    remove_path /usr/local/bin/hysteria
    remove_path /etc/hysteria
    remove_path /etc/systemd/system/hysteria-server.service
  fi

  systemctl daemon-reload
  info "Uninstall complete"
}

enable_bbr() {
  info "Applying TCP BBR tuning"
  sysctl -w net.core.default_qdisc=fq >/dev/null || true
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || true
  cat > /etc/sysctl.d/99-singbox-vps-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
}

port_owner() {
  local proto="$1"
  local port="$2"
  if [[ "$proto" == "tcp" ]]; then
    ss -H -tlnp "sport = :$port" 2>/dev/null || true
  else
    ss -H -ulnp "sport = :$port" 2>/dev/null || true
  fi
}

check_port_conflicts() {
  local tcp443 udp443 pub
  tcp443="$(port_owner tcp "$XRAY_PORT")"
  udp443="$(port_owner udp "$HY2_PORT")"
  pub=""
  if [[ "$PUBLISH_ENABLED" == "1" ]]; then
    pub="$(port_owner tcp "$PUBLISH_PORT")"
  fi

  if [[ -n "$tcp443" && "$tcp443" != *xray* ]]; then
    printf '%s\n' "$tcp443" >&2
    die "TCP/$XRAY_PORT is already in use."
  fi
  if [[ -n "$udp443" && "$udp443" != *hysteria* ]]; then
    printf '%s\n' "$udp443" >&2
    die "UDP/$HY2_PORT is already in use."
  fi
  if [[ -n "$pub" && "$pub" != *python3* ]]; then
    printf '%s\n' "$pub" >&2
    die "TCP/$PUBLISH_PORT is already in use."
  fi
}

install_xray() {
  info "Installing Xray"
  curl -L --fail --show-error --retry 3 --connect-timeout 10 \
    -o /tmp/xray-install-release.sh \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh
  bash /tmp/xray-install-release.sh install

  if ! id xray >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin xray
  fi
  install -d -o xray -g xray -m 750 /var/log/xray

  local stamp
  stamp="$(date +%Y%m%d%H%M%S)"
  local unit
  for unit in /etc/systemd/system/xray.service /etc/systemd/system/xray@.service; do
    if [[ -f "$unit" ]]; then
      cp -a "$unit" "$unit.bak.$stamp"
      awk '
        /^User=/ { print "User=xray"; if (!group_printed) { print "Group=xray"; group_printed=1 }; next }
        /^Group=/ { next }
        { print }
      ' "$unit" > "$unit.tmp"
      mv "$unit.tmp" "$unit"
    fi
  done
}

install_hysteria2() {
  info "Installing Hysteria2"
  curl -fsSL --show-error --retry 3 --connect-timeout 10 \
    -o /tmp/hysteria-install.sh \
    https://get.hy2.sh/
  bash /tmp/hysteria-install.sh

  if ! id hysteria >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin hysteria
  fi
  install -d -m 750 -o hysteria -g hysteria /etc/hysteria
}

generate_xray_secrets() {
  command -v /usr/local/bin/xray >/dev/null 2>&1 || die "Xray binary not found."

  XRAY_UUID="$(/usr/local/bin/xray uuid)"
  local keys
  keys="$(/usr/local/bin/xray x25519)"
  XRAY_PRIVATE_KEY="$(printf '%s\n' "$keys" | awk -F': ' '/^PrivateKey:/ {print $2}')"
  XRAY_PUBLIC_KEY="$(printf '%s\n' "$keys" | awk -F': ' '/^Password \(PublicKey\):/ {print $2}')"
  XRAY_SHORT_ID="$(openssl rand -hex 8)"

  if [[ -z "$XRAY_PRIVATE_KEY" || -z "$XRAY_PUBLIC_KEY" ]]; then
    printf '%s\n' "$keys" >&2
    die "Failed to parse Xray x25519 output."
  fi
}

generate_hy2_secrets() {
  HY2_PASSWORD="$(openssl rand -hex 24)"
  HY2_OBFS_TYPE="salamander"
  HY2_OBFS_PASSWORD="$(openssl rand -hex 16)"
}

generate_profile_token() {
  PROFILE_TOKEN="$(openssl rand -hex 18)"
}

ensure_hy2_cert() {
  install -d -m 750 -o hysteria -g hysteria /etc/hysteria
  if [[ ! -s /etc/hysteria/server.key || ! -s /etc/hysteria/server.crt ]]; then
    info "Generating Hysteria2 self-signed certificate"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -keyout /etc/hysteria/server.key \
      -out /etc/hysteria/server.crt \
      -subj "/CN=$SERVER_IP" \
      -addext "subjectAltName=IP:$SERVER_IP" >/tmp/hysteria-cert.log 2>&1
    chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt
    chmod 600 /etc/hysteria/server.key
    chmod 644 /etc/hysteria/server.crt
  fi

  HY2_TLS_PIN_SHA256="$(openssl x509 -noout -fingerprint -sha256 -in /etc/hysteria/server.crt | sed 's/^.*=//')"
  HY2_TLS_CERT_PUBKEY_SHA256="$(
    openssl x509 -in /etc/hysteria/server.crt -pubkey -noout |
      openssl pkey -pubin -outform der |
      openssl dgst -sha256 -binary |
      openssl enc -base64
  )"
}

ensure_state() {
  load_config
  if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP="$(detect_public_ip)"
  fi
  [[ -n "$SERVER_IP" ]] || die "Could not detect public IPv4. Use --server-ip IP."
  valid_port "$PUBLISH_PORT" || die "Invalid publish port: $PUBLISH_PORT"
  valid_port "$XRAY_PORT" || die "Invalid Xray port: $XRAY_PORT"
  valid_port "$HY2_PORT" || die "Invalid Hysteria2 port: $HY2_PORT"

  if [[ -z "${XRAY_UUID:-}" || -z "${XRAY_PRIVATE_KEY:-}" || -z "${XRAY_PUBLIC_KEY:-}" || -z "${XRAY_SHORT_ID:-}" ]]; then
    generate_xray_secrets
  fi
  if [[ -z "${HY2_PASSWORD:-}" || -z "${HY2_OBFS_PASSWORD:-}" ]]; then
    generate_hy2_secrets
  fi
  if [[ -z "${PROFILE_TOKEN:-}" ]]; then
    generate_profile_token
  fi

  ensure_hy2_cert
  write_config_file
  write_state_file
}

backup_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  cp -a "$path" "$path.bak.$(date +%Y%m%d%H%M%S)"
}

write_xray_config() {
  info "Writing Xray config"
  install -d -m 755 /usr/local/etc/xray
  backup_file "$XRAY_CONFIG"
  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-443",
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_UUID",
            "flow": "xtls-rprx-vision",
            "email": "primary"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$XRAY_DEST",
          "xver": 0,
          "serverNames": ["$XRAY_SNI"],
          "privateKey": "$XRAY_PRIVATE_KEY",
          "shortIds": ["$XRAY_SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "blocked", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"}
    ]
  }
}
EOF
  /usr/local/bin/xray run -test -config "$XRAY_CONFIG"
  chown root:xray "$XRAY_CONFIG"
  chmod 640 "$XRAY_CONFIG"
}

write_hysteria_config() {
  info "Writing Hysteria2 config"
  install -d -m 750 -o hysteria -g hysteria /etc/hysteria
  backup_file "$HY2_CONFIG"
  cat > "$HY2_CONFIG" <<EOF
listen: :$HY2_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
  sniGuard: disable

obfs:
  type: $HY2_OBFS_TYPE
  salamander:
    password: $HY2_OBFS_PASSWORD

auth:
  type: password
  password: $HY2_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com/
    rewriteHost: true
EOF
  chown root:hysteria "$HY2_CONFIG"
  chmod 640 "$HY2_CONFIG"
}

write_tun_profile() {
  local path="$1"
  local split="${2:-global}"
  local route_rule_set=""
  local cn_rules=""

  if [[ "$split" == "split" ]]; then
    route_rule_set='
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "reality-tcp",
        "update_interval": "1d"
      },
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "reality-tcp",
        "update_interval": "1d"
      }
    ],'
    cn_rules='
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "route", "outbound": "direct"},
      {"rule_set": ["geosite-cn", "geoip-cn"], "action": "route", "outbound": "direct"},'
  fi

  cat > "$path" <<EOF
{
  "log": {"level": "info"},
  "experimental": {"cache_file": {"enabled": true}},
  "dns": {
    "servers": [
      {
        "tag": "cloudflare-doh",
        "address": "https://1.1.1.1/dns-query",
        "detour": "reality-tcp",
        "strategy": "prefer_ipv4"
      },
      {"tag": "local", "address": "local"}
    ],
    "final": "cloudflare-doh",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30"],
      "mtu": 1500,
      "auto_route": true,
      "stack": "system"
    },
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7890}
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "reality-tcp",
      "server": "$SERVER_IP",
      "server_port": $XRAY_PORT,
      "uuid": "$XRAY_UUID",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "$XRAY_SNI",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {
          "enabled": true,
          "public_key": "$XRAY_PUBLIC_KEY",
          "short_id": "$XRAY_SHORT_ID"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2",
      "server": "$SERVER_IP",
      "server_port": $HY2_PORT,
      "password": "$HY2_PASSWORD",
      "obfs": {"type": "$HY2_OBFS_TYPE", "password": "$HY2_OBFS_PASSWORD"},
      "tls": {
        "enabled": true,
        "server_name": "$SERVER_IP",
        "insecure": true,
        "certificate_public_key_sha256": ["$HY2_TLS_CERT_PUBKEY_SHA256"]
      }
    },
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "auto_detect_interface": true,$route_rule_set
    "rules": [
      {"network": ["tcp", "udp"], "port": 53, "action": "hijack-dns"},
      {"protocol": ["dns"], "action": "hijack-dns"},
      {"ip_cidr": ["$SERVER_IP/32"], "action": "route", "outbound": "direct"},
      {"ip_is_private": true, "action": "route", "outbound": "direct"},$cn_rules
      {"network": ["udp"], "port": 443, "action": "route", "outbound": "block"},
      {"network": ["tcp"], "action": "route", "outbound": "reality-tcp"},
      {"network": ["udp"], "action": "route", "outbound": "hy2"}
    ],
    "final": "reality-tcp"
  }
}
EOF
}

write_proxy_profile() {
  local path="$1"
  local split="${2:-global}"
  local route_rule_set=""
  local cn_rules=""

  if [[ "$split" == "split" ]]; then
    route_rule_set='
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "reality-tcp",
        "update_interval": "1d"
      },
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "reality-tcp",
        "update_interval": "1d"
      }
    ],'
    cn_rules='
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "route", "outbound": "direct"},
      {"rule_set": ["geosite-cn", "geoip-cn"], "action": "route", "outbound": "direct"},'
  fi

  cat > "$path" <<EOF
{
  "log": {"level": "info"},
  "experimental": {"cache_file": {"enabled": true}},
  "inbounds": [
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7890}
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "reality-tcp",
      "server": "$SERVER_IP",
      "server_port": $XRAY_PORT,
      "uuid": "$XRAY_UUID",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "$XRAY_SNI",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {
          "enabled": true,
          "public_key": "$XRAY_PUBLIC_KEY",
          "short_id": "$XRAY_SHORT_ID"
        }
      }
    },
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {$route_rule_set
    "rules": [
      {"ip_cidr": ["$SERVER_IP/32"], "action": "route", "outbound": "direct"},
      {"ip_is_private": true, "action": "route", "outbound": "direct"},$cn_rules
      {"protocol": ["bittorrent"], "action": "route", "outbound": "block"}
    ],
    "final": "reality-tcp"
  }
}
EOF
}

write_profiles() {
  info "Writing sing-box client profiles"
  install -d -m 700 "$PRIVATE_DIR"
  install -d -m 700 "$PROFILE_DIR"

  write_tun_profile "$PROFILE_DIR/tun-global.json" global
  write_tun_profile "$PROFILE_DIR/tun-split.json" split
  write_proxy_profile "$PROFILE_DIR/proxy-global.json" global
  write_proxy_profile "$PROFILE_DIR/proxy-split.json" split
  chmod 600 "$PROFILE_DIR"/*.json

  cp "$PROFILE_DIR"/*.json "$PRIVATE_DIR"/
  chmod 600 "$PRIVATE_DIR"/*.json

  write_client_env
  write_import_uris
  write_private_readme

  if command -v sing-box >/dev/null 2>&1; then
    sing-box check -c "$PROFILE_DIR/tun-global.json"
    sing-box check -c "$PROFILE_DIR/tun-split.json"
    sing-box check -c "$PROFILE_DIR/proxy-global.json"
    sing-box check -c "$PROFILE_DIR/proxy-split.json"
  else
    warn "sing-box CLI not installed on this VPS; skipped local client-config checks."
  fi
}

write_client_env() {
  {
    write_env_var SERVER_IP "$SERVER_IP"
    write_env_var XRAY_UUID "$XRAY_UUID"
    write_env_var XRAY_PUBLIC_KEY "$XRAY_PUBLIC_KEY"
    write_env_var XRAY_SHORT_ID "$XRAY_SHORT_ID"
    write_env_var XRAY_SNI "$XRAY_SNI"
    write_env_var XRAY_PORT "$XRAY_PORT"
    write_env_var HY2_PORT "$HY2_PORT"
    write_env_var HY2_PASSWORD "$HY2_PASSWORD"
    write_env_var HY2_OBFS_TYPE "$HY2_OBFS_TYPE"
    write_env_var HY2_OBFS_PASSWORD "$HY2_OBFS_PASSWORD"
    write_env_var HY2_TLS_INSECURE "true"
    write_env_var HY2_TLS_PIN_SHA256 "$HY2_TLS_PIN_SHA256"
    write_env_var HY2_TLS_CERT_PUBKEY_SHA256 "$HY2_TLS_CERT_PUBKEY_SHA256"
  } > "$PRIVATE_DIR/client.env"
  chmod 600 "$PRIVATE_DIR/client.env"
}

write_import_uris() {
  local vless_uri
  local hy2_pin_escaped
  local hy2_uri
  vless_uri="vless://$XRAY_UUID@$SERVER_IP:$XRAY_PORT?encryption=none&security=reality&sni=$XRAY_SNI&fp=chrome&pbk=$XRAY_PUBLIC_KEY&sid=$XRAY_SHORT_ID&type=tcp&flow=xtls-rprx-vision&spx=%2F#vless-reality-$SERVER_IP"
  hy2_pin_escaped="$(printf '%s' "$HY2_TLS_PIN_SHA256" | sed 's/:/%3A/g')"
  hy2_uri="hysteria2://$HY2_PASSWORD@$SERVER_IP:$HY2_PORT/?insecure=1&pinSHA256=$hy2_pin_escaped&obfs=$HY2_OBFS_TYPE&obfs-password=$HY2_OBFS_PASSWORD&sni=$SERVER_IP#hy2-$SERVER_IP"

  cat > "$PRIVATE_DIR/import-uris.txt" <<EOF
VLESS Reality:
$vless_uri

Hysteria2:
$hy2_uri
EOF
  chmod 600 "$PRIVATE_DIR/import-uris.txt"
}

write_private_readme() {
  cat > "$PRIVATE_DIR/README.txt" <<EOF
Proxy setup for $SERVER_IP

Local profile files:
$PROFILE_DIR/tun-global.json
$PROFILE_DIR/tun-split.json
$PROFILE_DIR/proxy-global.json
$PROFILE_DIR/proxy-split.json

Recommended first import:
proxy-split.json

Remote profile URLs:
$(profile_links_text)

Raw node URIs are in:
$PRIVATE_DIR/import-uris.txt

Config files:
$CONFIG_FILE
$STATE_FILE

Common commands:
singbox-vps links
singbox-vps edit proxy-split
singbox-vps regen
singbox-vps rotate-token

Security note:
Remote profile URLs contain usable client credentials inside the JSON.
Keep the random token private.
EOF
  chmod 600 "$PRIVATE_DIR/README.txt"
}

profile_links_text() {
  if [[ "${PUBLISH_ENABLED:-1}" != "1" ]]; then
    printf 'Publishing disabled.\n'
    return 0
  fi
  if [[ -z "${PROFILE_TOKEN:-}" ]]; then
    printf 'Profile token is missing. Run: singbox-vps regen\n'
    return 0
  fi
  cat <<EOF
http://$SERVER_IP:$PUBLISH_PORT/$PROFILE_TOKEN/tun-global.json
http://$SERVER_IP:$PUBLISH_PORT/$PROFILE_TOKEN/tun-split.json
http://$SERVER_IP:$PUBLISH_PORT/$PROFILE_TOKEN/proxy-global.json
http://$SERVER_IP:$PUBLISH_PORT/$PROFILE_TOKEN/proxy-split.json
EOF
}

write_profile_service() {
  cat > "$PROFILE_SERVICE" <<EOF
[Unit]
Description=singbox-vps remote profile HTTP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=$PROFILE_WEB_ROOT
ExecStart=/usr/bin/python3 -m http.server $PUBLISH_PORT --bind 0.0.0.0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

publish_profiles() {
  load_config
  if [[ "${PUBLISH_ENABLED:-1}" != "1" ]]; then
    if [[ -f "$PROFILE_SERVICE" ]]; then
      systemctl disable --now "$(basename "$PROFILE_SERVICE")" >/dev/null 2>&1 || true
    fi
    info "Profile publishing is disabled."
    return 0
  fi

  [[ -n "${PROFILE_TOKEN:-}" ]] || die "PROFILE_TOKEN is missing. Run singbox-vps regen."
  install -d -m 755 "$PROFILE_WEB_ROOT"
  local public_dir="$PROFILE_WEB_ROOT/$PROFILE_TOKEN"
  install -d -m 755 "$public_dir"
  cp "$PROFILE_DIR"/tun-global.json "$public_dir/"
  cp "$PROFILE_DIR"/tun-split.json "$public_dir/"
  cp "$PROFILE_DIR"/proxy-global.json "$public_dir/"
  cp "$PROFILE_DIR"/proxy-split.json "$public_dir/"
  chmod 644 "$public_dir"/*.json

  cat > "$public_dir/index.txt" <<EOF
sing-box remote profile URLs:

$(profile_links_text)
EOF
  chmod 644 "$public_dir/index.txt"

  write_profile_service
  systemctl daemon-reload
  systemctl enable --now "$(basename "$PROFILE_SERVICE")"
  systemctl restart "$(basename "$PROFILE_SERVICE")"
  allow_ufw_publish_port
}

allow_ufw_publish_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "$PUBLISH_PORT/tcp" >/dev/null || true
  fi
}

restart_services() {
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray
  systemctl enable --now hysteria-server
  systemctl restart hysteria-server
  if [[ "${PUBLISH_ENABLED:-1}" == "1" ]]; then
    systemctl enable --now "$(basename "$PROFILE_SERVICE")"
    systemctl restart "$(basename "$PROFILE_SERVICE")"
  fi
}

regen_all() {
  require_root
  load_config
  ensure_state
  write_xray_config
  write_hysteria_config
  write_profiles
  publish_profiles
  restart_services
}

parse_install_args() {
  init_defaults
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --publish-port)
        [[ $# -ge 2 ]] || die "--publish-port requires a value."
        PUBLISH_PORT="$2"
        shift 2
        ;;
      --out-dir)
        [[ $# -ge 2 ]] || die "--out-dir requires a value."
        PRIVATE_DIR="$2"
        shift 2
        ;;
      --server-ip)
        [[ $# -ge 2 ]] || die "--server-ip requires a value."
        SERVER_IP="$2"
        shift 2
        ;;
      --xray-sni)
        [[ $# -ge 2 ]] || die "--xray-sni requires a value."
        XRAY_SNI="$2"
        shift 2
        ;;
      --xray-dest)
        [[ $# -ge 2 ]] || die "--xray-dest requires a value."
        XRAY_DEST="$2"
        shift 2
        ;;
      --no-publish)
        PUBLISH_ENABLED=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown install option: $1"
        ;;
    esac
  done
}

install_command() {
  require_root
  parse_install_args "$@"
  detect_os
  install_packages

  if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP="$(detect_public_ip)"
  fi
  [[ -n "$SERVER_IP" ]] || die "Could not detect public IPv4. Use --server-ip IP."
  valid_port "$PUBLISH_PORT" || die "Invalid --publish-port: $PUBLISH_PORT"

  write_config_file
  check_port_conflicts
  enable_bbr
  install_xray
  install_hysteria2
  regen_all
  print_done
}

print_done() {
  cat <<EOF

==> Install complete

Recommended profile:
  proxy-split

Remote import URLs:
$(profile_links_text)

Manage later:
  singbox-vps links
  singbox-vps status
  singbox-vps edit proxy-split
  singbox-vps regen

Private files:
  $PRIVATE_DIR
EOF
}

links_command() {
  load_config
  cat <<EOF
Remote sing-box profile URLs:

$(profile_links_text)

Recommended first import:
  proxy-split.json

Local profile directory:
  $PROFILE_DIR
EOF
}

status_command() {
  load_config
  echo "Services:"
  systemctl is-active xray 2>/dev/null | sed 's/^/  xray: /' || true
  systemctl is-active hysteria-server 2>/dev/null | sed 's/^/  hysteria-server: /' || true
  if [[ "${PUBLISH_ENABLED:-1}" == "1" ]]; then
    systemctl is-active "$(basename "$PROFILE_SERVICE")" 2>/dev/null | sed 's/^/  profile-server: /' || true
  else
    echo "  profile-server: disabled"
  fi
  echo
  echo "Listeners:"
  ss -H -tlnp "sport = :$XRAY_PORT" || true
  ss -H -ulnp "sport = :$HY2_PORT" || true
  if [[ "${PUBLISH_ENABLED:-1}" == "1" ]]; then
    ss -H -tlnp "sport = :$PUBLISH_PORT" || true
  fi
}

config_command() {
  load_config
  cat <<EOF
Config:
  $CONFIG_FILE

State:
  $STATE_FILE

Private output:
  $PRIVATE_DIR

Profiles:
  $PROFILE_DIR

Profile web root:
  $PROFILE_WEB_ROOT

Current settings:
  SERVER_IP=$SERVER_IP
  XRAY_SNI=$XRAY_SNI
  XRAY_DEST=$XRAY_DEST
  XRAY_PORT=$XRAY_PORT
  HY2_PORT=$HY2_PORT
  PUBLISH_ENABLED=$PUBLISH_ENABLED
  PUBLISH_PORT=$PUBLISH_PORT
EOF
}

profiles_command() {
  load_config
  find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.json' -print | sort
}

profile_path_for_name() {
  local name="$1"
  case "$name" in
    tun-global|tun-global.json) printf '%s/tun-global.json' "$PROFILE_DIR" ;;
    tun-split|tun-split.json) printf '%s/tun-split.json' "$PROFILE_DIR" ;;
    proxy-global|proxy-global.json) printf '%s/proxy-global.json' "$PROFILE_DIR" ;;
    proxy-split|proxy-split.json) printf '%s/proxy-split.json' "$PROFILE_DIR" ;;
    *) return 1 ;;
  esac
}

edit_command() {
  require_root
  load_config
  [[ $# -ge 1 ]] || die "Usage: singbox-vps edit <profile>"
  local path
  path="$(profile_path_for_name "$1")" || die "Unknown profile: $1"
  [[ -f "$path" ]] || die "Profile does not exist: $path"

  local editor="${EDITOR:-}"
  if [[ -z "$editor" ]]; then
    if command -v nano >/dev/null 2>&1; then
      editor="nano"
    else
      editor="vi"
    fi
  fi

  "$editor" "$path"
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$path" >/dev/null
  fi
  chmod 600 "$path"
  cp "$path" "$PRIVATE_DIR/$(basename "$path")"
  chmod 600 "$PRIVATE_DIR/$(basename "$path")"
  publish_profiles
  info "Published updated profile: $(basename "$path")"
}

rotate_token_command() {
  require_root
  load_config
  local old_token="${PROFILE_TOKEN:-}"
  generate_profile_token
  write_state_file
  if [[ "$old_token" =~ ^[a-f0-9]{36}$ && -n "${PROFILE_WEB_ROOT:-}" ]]; then
    rm -rf -- "$PROFILE_WEB_ROOT/$old_token"
  fi
  publish_profiles
  links_command
}

rotate_secrets_command() {
  require_root
  load_config
  generate_xray_secrets
  generate_hy2_secrets
  ensure_hy2_cert
  write_state_file
  regen_all
  links_command
}

logs_command() {
  journalctl \
    -u xray \
    -u hysteria-server \
    -u "$(basename "$PROFILE_SERVICE")" \
    -n 120 \
    --no-pager || true
}

main() {
  local command="${1:-help}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$command" in
    install) install_command "$@" ;;
    uninstall) uninstall_command "$@" ;;
    links) links_command "$@" ;;
    status) status_command "$@" ;;
    config) config_command "$@" ;;
    profiles) profiles_command "$@" ;;
    edit) edit_command "$@" ;;
    regen) regen_all "$@" ;;
    publish) require_root; publish_profiles "$@" ;;
    restart) require_root; load_config; restart_services "$@" ;;
    rotate-token) rotate_token_command "$@" ;;
    rotate-secrets) rotate_secrets_command "$@" ;;
    logs) logs_command "$@" ;;
    help|-h|--help) usage ;;
    *)
      usage >&2
      die "Unknown command: $command"
      ;;
  esac
}

main "$@"
MANAGER_EOF
  chmod 755 "$MANAGER_BIN"
}

write_manager
case "${1:-}" in
  install|uninstall|links|status|config|profiles|edit|regen|publish|restart|rotate-token|rotate-secrets|logs|help|-h|--help)
    exec "$MANAGER_BIN" "$@"
    ;;
  *)
    exec "$MANAGER_BIN" install "$@"
    ;;
esac
