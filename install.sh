#!/usr/bin/env bash
set -euo pipefail

MANAGER_BIN="/usr/local/bin/singb"
OLD_MANAGER_BIN="/usr/local/bin/singbox-vps"

usage() {
  cat <<'EOF'
用法:
  bash install.sh [选项]

在 Debian/Ubuntu VPS 上安装 Xray + Hysteria2，生成 sing-box 客户端配置包，
并安装 `singb` 管理命令。

选项:
  --out-dir DIR             私有输出目录，默认 /root/singb
  --server-ip IP            手动指定服务器公网 IPv4
  --xray-sni DOMAIN         Reality SNI，默认 www.cloudflare.com
  --xray-dest HOST:PORT     Reality 回落目标，默认 www.cloudflare.com:443
  -h, --help                显示帮助

安装后常用命令:
  singb links
  singb status
  singb edit proxy-split
  singb regen

维护:
  bash install.sh update [--url URL]
  bash install.sh uninstall [--purge-binaries]
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(id -u)" != "0" ]]; then
  echo "请在 VPS 上用 root 运行安装脚本。" >&2
  exit 1
fi

write_manager() {
  install -d -m 755 "$(dirname "$MANAGER_BIN")"
  cat > "$MANAGER_BIN" <<'MANAGER_EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="singb"
INSTALL_URL="https://raw.githubusercontent.com/syncmeta/singbox-script-for-vps/main/install.sh"
CONFIG_DIR="/etc/singb"
CONFIG_FILE="$CONFIG_DIR/config.env"
STATE_FILE="$CONFIG_DIR/state.env"
PRIVATE_DIR="/root/singb"
PROFILE_DIR="/var/lib/singb/profiles"
PROFILE_ARCHIVE_NAME="singb-profiles.zip"
PROFILE_WEB_ROOT="/var/www/singb"
PROFILE_SERVICE="/etc/systemd/system/singb-profile-server.service"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
HY2_CONFIG="/etc/hysteria/config.yaml"
OLD_CONFIG_DIR="/etc/singbox-vps"
OLD_CONFIG_FILE="$OLD_CONFIG_DIR/config.env"
OLD_STATE_FILE="$OLD_CONFIG_DIR/state.env"
OLD_PRIVATE_DIR="/root/singbox-vps"
OLD_PROFILE_DIR="/var/lib/singbox-vps/profiles"
OLD_PROFILE_WEB_ROOT="/var/www/singbox-vps"
OLD_PROFILE_SERVICE="/etc/systemd/system/singbox-vps-profile-server.service"

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf '警告: %s\n' "$*" >&2
}

die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "请使用 root 运行。"
}

quote_value() {
  printf '%q' "$1"
}

write_env_var() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "$key" "$(quote_value "$value")"
}

profile_ids() {
  printf '%s\n' \
    tun-global \
    tun-split \
    proxy-global \
    proxy-split \
    proxy-hy2-global \
    proxy-hy2-split
}

profile_filename() {
  local profile="$1"
  printf '%s-%s.json' "$SERVER_IP" "$profile"
}

profile_path() {
  local profile="$1"
  printf '%s/%s' "$PROFILE_DIR" "$(profile_filename "$profile")"
}

remove_generated_profile_files() {
  local dir="$1"
  local profile
  for profile in $(profile_ids); do
    rm -f "$dir/$profile.json" "$dir"/*-"$profile.json"
  done
  rm -f "$dir"/tun-legacy-global.json "$dir"/tun-legacy-split.json
}

usage() {
  cat <<'EOF'
用法:
  singb <命令> [选项]

命令:
  install [选项]             安装或修复 VPS 部署
  uninstall [选项]           停止服务并删除生成的配置
  links                     显示配置包路径和 scp 下载命令
  status                    查看服务和端口监听状态
  config                    查看配置文件路径和当前参数
  profiles                  列出本地生成的客户端配置
  edit <配置名>             编辑指定客户端配置并重新打包
  regen                     根据已保存状态重新生成服务端和客户端配置
  update                    从 GitHub 更新 singb 并重新生成配置
  bundle                    重新打包当前客户端配置
  restart                   重启 Xray 和 Hysteria2
  rotate-secrets            重新生成节点密钥和客户端配置
  logs                      查看最近服务日志
  help                      显示帮助

配置名:
  tun-global
  tun-split
  proxy-global
  proxy-split
  proxy-hy2-global
  proxy-hy2-split
  实际生成的 JSON 文件名会加服务器 IP 前缀，例如 SERVER_IP-proxy-split.json

安装选项:
  --out-dir DIR             私有输出目录，默认 /root/singb
  --server-ip IP            手动指定服务器公网 IPv4
  --xray-sni DOMAIN         Reality SNI，默认 www.cloudflare.com
  --xray-dest HOST:PORT     Reality 回落目标，默认 www.cloudflare.com:443

卸载选项:
  --purge-binaries          同时删除 Xray 和 Hysteria2 程序及服务文件
EOF
}

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      case " ${ID_LIKE:-} " in
        *" debian "*) ;;
        *) die "不支持的系统：${PRETTY_NAME:-unknown}。请使用 Debian 或 Ubuntu。" ;;
      esac
      ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "缺少 systemd。"
  command -v apt-get >/dev/null 2>&1 || die "缺少 apt-get。"
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
  XRAY_SNI="${XRAY_SNI:-www.cloudflare.com}"
  XRAY_DEST="${XRAY_DEST:-www.cloudflare.com:443}"
  PRIVATE_DIR="${PRIVATE_DIR:-/root/singb}"
  PROFILE_DIR="${PROFILE_DIR:-/var/lib/singb/profiles}"
  PROFILE_WEB_ROOT="${PROFILE_WEB_ROOT:-/var/www/singb}"
  XRAY_PORT="${XRAY_PORT:-443}"
  HY2_PORT="${HY2_PORT:-443}"
  HY2_OBFS_TYPE="${HY2_OBFS_TYPE:-salamander}"
}

migrate_old_layout() {
  [[ -r "$CONFIG_FILE" || ! -r "$OLD_CONFIG_FILE" ]] && return 0
  info "检测到旧版配置，正在迁移到 singb"

  # shellcheck disable=SC1090
  . "$OLD_CONFIG_FILE"
  SERVER_IP="${SERVER_IP:-}"
  XRAY_SNI="${XRAY_SNI:-www.cloudflare.com}"
  XRAY_DEST="${XRAY_DEST:-www.cloudflare.com:443}"
  XRAY_PORT="${XRAY_PORT:-443}"
  HY2_PORT="${HY2_PORT:-443}"
  PRIVATE_DIR="/root/singb"
  PROFILE_DIR="/var/lib/singb/profiles"
  PROFILE_WEB_ROOT="/var/www/singb"
  write_config_file

  if [[ -r "$OLD_STATE_FILE" ]]; then
    cp -a "$OLD_STATE_FILE" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
  fi
}

load_config() {
  init_defaults
  if [[ "$(id -u)" == "0" ]]; then
    migrate_old_layout
  fi
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
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

install_packages() {
  info "正在安装基础软件包"
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

disable_old_profile_service() {
  systemctl disable --now "$(basename "$OLD_PROFILE_SERVICE")" >/dev/null 2>&1 || true
  remove_path "$OLD_PROFILE_SERVICE"
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
用法:
  singb uninstall [--purge-binaries]

停止 singb 服务并删除生成的配置文件。
默认保留 Xray 和 Hysteria2 程序，方便之后快速重装。
EOF
        return 0
        ;;
      *)
        die "未知卸载选项: $1"
        ;;
    esac
  done

  require_root
  info "正在停止服务"
  systemctl disable --now "$(basename "$PROFILE_SERVICE")" >/dev/null 2>&1 || true
  disable_old_profile_service
  systemctl disable --now xray >/dev/null 2>&1 || true
  systemctl disable --now hysteria-server >/dev/null 2>&1 || true

  info "正在删除 singb 生成的文件"
  remove_path "$PROFILE_SERVICE"
  remove_path "$CONFIG_DIR"
  remove_path "$PRIVATE_DIR"
  remove_path "$PROFILE_DIR"
  remove_path "$PROFILE_WEB_ROOT"
  remove_path "$OLD_CONFIG_DIR"
  remove_path "$OLD_PRIVATE_DIR"
  remove_path "$OLD_PROFILE_DIR"
  remove_path "$OLD_PROFILE_WEB_ROOT"
  remove_path /usr/local/bin/singbox-vps
  remove_path /etc/sysctl.d/99-singb-bbr.conf
  remove_path /etc/sysctl.d/99-singbox-vps-bbr.conf

  if (( purge_binaries == 1 )); then
    info "正在删除 Xray 和 Hysteria2 程序及服务文件"
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
  info "卸载完成"
}

enable_bbr() {
  info "正在启用 TCP BBR 优化"
  sysctl -w net.core.default_qdisc=fq >/dev/null || true
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || true
  cat > /etc/sysctl.d/99-singb-bbr.conf <<'EOF'
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
  local tcp443 udp443
  tcp443="$(port_owner tcp "$XRAY_PORT")"
  udp443="$(port_owner udp "$HY2_PORT")"

  if [[ -n "$tcp443" && "$tcp443" != *xray* ]]; then
    printf '%s\n' "$tcp443" >&2
    die "TCP/$XRAY_PORT 已被占用。"
  fi
  if [[ -n "$udp443" && "$udp443" != *hysteria* ]]; then
    printf '%s\n' "$udp443" >&2
    die "UDP/$HY2_PORT 已被占用。"
  fi
}

install_xray() {
  info "正在安装 Xray"
  curl -L --fail --show-error --retry 3 --connect-timeout 10 \
    -o /tmp/xray-install-release.sh \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh
  bash /tmp/xray-install-release.sh install

  if ! id xray >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin xray
  fi
  install -d -o xray -g xray -m 750 /var/log/xray
  chown -R xray:xray /var/log/xray
  chmod 750 /var/log/xray

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
  info "正在安装 Hysteria2"
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
  command -v /usr/local/bin/xray >/dev/null 2>&1 || die "找不到 Xray 程序。"

  XRAY_UUID="$(/usr/local/bin/xray uuid)"
  local keys
  keys="$(/usr/local/bin/xray x25519)"
  XRAY_PRIVATE_KEY="$(printf '%s\n' "$keys" | awk -F': ' '/^PrivateKey:/ {print $2}')"
  XRAY_PUBLIC_KEY="$(printf '%s\n' "$keys" | awk -F': ' '/^Password \(PublicKey\):/ {print $2}')"
  XRAY_SHORT_ID="$(openssl rand -hex 8)"

  if [[ -z "$XRAY_PRIVATE_KEY" || -z "$XRAY_PUBLIC_KEY" ]]; then
    printf '%s\n' "$keys" >&2
    die "解析 Xray x25519 输出失败。"
  fi
}

generate_hy2_secrets() {
  HY2_PASSWORD="$(openssl rand -hex 24)"
  HY2_OBFS_TYPE="salamander"
  HY2_OBFS_PASSWORD="$(openssl rand -hex 16)"
}

ensure_hy2_cert() {
  install -d -m 750 -o hysteria -g hysteria /etc/hysteria
  if [[ ! -s /etc/hysteria/server.key || ! -s /etc/hysteria/server.crt ]]; then
    info "正在生成 Hysteria2 自签证书"
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
  [[ -n "$SERVER_IP" ]] || die "无法检测公网 IPv4，请使用 --server-ip IP 指定。"
  valid_port "$XRAY_PORT" || die "无效 Xray 端口：$XRAY_PORT"
  valid_port "$HY2_PORT" || die "无效 Hysteria2 端口：$HY2_PORT"

  if [[ -z "${XRAY_UUID:-}" || -z "${XRAY_PRIVATE_KEY:-}" || -z "${XRAY_PUBLIC_KEY:-}" || -z "${XRAY_SHORT_ID:-}" ]]; then
    generate_xray_secrets
  fi
  if [[ -z "${HY2_PASSWORD:-}" || -z "${HY2_OBFS_PASSWORD:-}" ]]; then
    generate_hy2_secrets
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
  info "正在写入 Xray 配置"
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
  info "正在写入 Hysteria2 配置"
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
  local cn_dns_rules=""
  local cn_resolve_rules=""
  local dns_block=""
  local route_resolver=""
  local resolve_rule=""
  local rule_set_download_client='"download_detour": "reality-tcp",'

  if [[ "$split" == "split" ]]; then
    route_rule_set='
    "rule_set": [
      {
        "type": "remote",
        "tag": "cn-domain-whitelist",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        '"$rule_set_download_client"'
        "update_interval": "1d"
      },
      {
        "type": "remote",
        "tag": "cn-ip-whitelist",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        '"$rule_set_download_client"'
        "update_interval": "1d"
      }
    ],'
    cn_rules='
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "route", "outbound": "direct"},
      {"rule_set": ["cn-domain-whitelist"], "action": "route", "outbound": "direct"},
      {"rule_set": ["cn-ip-whitelist"], "action": "route", "outbound": "direct"},'
    cn_dns_rules='
    "rules": [
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "route", "server": "local"},
      {"rule_set": ["cn-domain-whitelist"], "action": "route", "server": "local"}
    ],'
    cn_resolve_rules='
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "resolve", "server": "local", "strategy": "prefer_ipv4"},
      {"rule_set": ["cn-domain-whitelist"], "action": "resolve", "server": "local", "strategy": "prefer_ipv4"},'
    resolve_rule='
      {"action": "resolve", "strategy": "prefer_ipv4"},'
  fi

  dns_block='  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "cloudflare-doh",
        "server": "1.1.1.1",
        "path": "/dns-query",
        "detour": "reality-tcp"
      },
      {"type": "local", "tag": "local"}
    ],
'"$cn_dns_rules"'
    "final": "cloudflare-doh",
    "strategy": "prefer_ipv4"
  },'
  route_resolver='
    "default_domain_resolver": {"server": "cloudflare-doh", "strategy": "prefer_ipv4"},'

  cat > "$path" <<EOF
{
  "log": {"level": "info"},
  "experimental": {"cache_file": {"enabled": true}},
$dns_block
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
    "auto_detect_interface": true,$route_resolver$route_rule_set
    "rules": [
      {"action": "sniff"},$cn_resolve_rules$resolve_rule
      {"network": ["tcp", "udp"], "port": 53, "action": "hijack-dns"},
      {"protocol": ["dns"], "action": "hijack-dns"},
      {"ip_cidr": ["$SERVER_IP/32"], "action": "route", "outbound": "direct"},
      {"ip_is_private": true, "action": "route", "outbound": "direct"},$cn_rules
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
  local dns_block=""
  local route_resolver=""
  local route_rule_set=""
  local cn_rules=""
  local cn_resolve_rules=""
  local resolve_rule=""

  if [[ "$split" == "split" ]]; then
    dns_block='  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "cloudflare-doh",
        "server": "1.1.1.1",
        "path": "/dns-query",
        "detour": "reality-tcp"
      },
      {"type": "local", "tag": "local"}
    ],
    "rules": [
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "route", "server": "local"},
      {"rule_set": ["cn-domain-whitelist"], "action": "route", "server": "local"}
    ],
    "final": "cloudflare-doh",
    "strategy": "prefer_ipv4"
  },'
    route_resolver='
    "default_domain_resolver": {"server": "cloudflare-doh", "strategy": "prefer_ipv4"},'
    route_rule_set='
    "rule_set": [
      {
        "type": "remote",
        "tag": "cn-domain-whitelist",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "reality-tcp",
        "update_interval": "1d"
      },
      {
        "type": "remote",
        "tag": "cn-ip-whitelist",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "reality-tcp",
        "update_interval": "1d"
      }
    ],'
    cn_rules='
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "route", "outbound": "direct"},
      {"rule_set": ["cn-domain-whitelist"], "action": "route", "outbound": "direct"},
      {"rule_set": ["cn-ip-whitelist"], "action": "route", "outbound": "direct"},'
    cn_resolve_rules='
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "resolve", "server": "local", "strategy": "prefer_ipv4"},
      {"rule_set": ["cn-domain-whitelist"], "action": "resolve", "server": "local", "strategy": "prefer_ipv4"},'
    resolve_rule='
      {"action": "resolve", "strategy": "prefer_ipv4"},'
  fi

  cat > "$path" <<EOF
{
  "log": {"level": "info"},
  "experimental": {"cache_file": {"enabled": true}},
$dns_block
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
  "route": {$route_resolver$route_rule_set
    "rules": [
      {"action": "sniff"},$cn_resolve_rules$resolve_rule
      {"ip_cidr": ["$SERVER_IP/32"], "action": "route", "outbound": "direct"},
      {"ip_is_private": true, "action": "route", "outbound": "direct"},$cn_rules
      {"protocol": ["bittorrent"], "action": "route", "outbound": "block"}
    ],
    "final": "reality-tcp"
  }
}
EOF
}

write_hy2_proxy_profile() {
  local path="$1"
  local split="${2:-global}"
  local dns_block=""
  local route_resolver=""
  local route_rule_set=""
  local cn_rules=""
  local cn_resolve_rules=""
  local resolve_rule=""

  if [[ "$split" == "split" ]]; then
    dns_block='  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "cloudflare-doh",
        "server": "1.1.1.1",
        "path": "/dns-query",
        "detour": "hy2"
      },
      {"type": "local", "tag": "local"}
    ],
    "rules": [
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "route", "server": "local"},
      {"rule_set": ["cn-domain-whitelist"], "action": "route", "server": "local"}
    ],
    "final": "cloudflare-doh",
    "strategy": "prefer_ipv4"
  },'
    route_resolver='
    "default_domain_resolver": {"server": "cloudflare-doh", "strategy": "prefer_ipv4"},'
    route_rule_set='
    "rule_set": [
      {
        "type": "remote",
        "tag": "cn-domain-whitelist",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "hy2",
        "update_interval": "1d"
      },
      {
        "type": "remote",
        "tag": "cn-ip-whitelist",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "hy2",
        "update_interval": "1d"
      }
    ],'
    cn_rules='
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "route", "outbound": "direct"},
      {"rule_set": ["cn-domain-whitelist"], "action": "route", "outbound": "direct"},
      {"rule_set": ["cn-ip-whitelist"], "action": "route", "outbound": "direct"},'
    cn_resolve_rules='
      {"domain_suffix": [".cn", ".中国", ".中國"], "action": "resolve", "server": "local", "strategy": "prefer_ipv4"},
      {"rule_set": ["cn-domain-whitelist"], "action": "resolve", "server": "local", "strategy": "prefer_ipv4"},'
    resolve_rule='
      {"action": "resolve", "strategy": "prefer_ipv4"},'
  fi

  cat > "$path" <<EOF
{
  "log": {"level": "info"},
  "experimental": {"cache_file": {"enabled": true}},
$dns_block
  "inbounds": [
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7890}
  ],
  "outbounds": [
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
  "route": {$route_resolver$route_rule_set
    "rules": [
      {"action": "sniff"},$cn_resolve_rules$resolve_rule
      {"ip_cidr": ["$SERVER_IP/32"], "action": "route", "outbound": "direct"},
      {"ip_is_private": true, "action": "route", "outbound": "direct"},$cn_rules
      {"protocol": ["bittorrent"], "action": "route", "outbound": "block"}
    ],
    "final": "hy2"
  }
}
EOF
}

write_profiles() {
  info "正在生成 sing-box 客户端配置"
  install -d -m 700 "$PRIVATE_DIR"
  install -d -m 700 "$PROFILE_DIR"
  remove_generated_profile_files "$PROFILE_DIR"
  remove_generated_profile_files "$PRIVATE_DIR"

  write_tun_profile "$(profile_path tun-global)" global
  write_tun_profile "$(profile_path tun-split)" split
  write_proxy_profile "$(profile_path proxy-global)" global
  write_proxy_profile "$(profile_path proxy-split)" split
  write_hy2_proxy_profile "$(profile_path proxy-hy2-global)" global
  write_hy2_proxy_profile "$(profile_path proxy-hy2-split)" split
  chmod 600 "$PROFILE_DIR"/*.json

  cp "$PROFILE_DIR"/*.json "$PRIVATE_DIR"/
  chmod 600 "$PRIVATE_DIR"/*.json

  write_client_env
  write_import_uris
  write_private_readme

  if command -v sing-box >/dev/null 2>&1; then
    check_client_profile "$(profile_path tun-global)"
    check_client_profile "$(profile_path tun-split)"
    check_client_profile "$(profile_path proxy-global)"
    check_client_profile "$(profile_path proxy-split)"
    check_client_profile "$(profile_path proxy-hy2-global)"
    check_client_profile "$(profile_path proxy-hy2-split)"
  else
    warn "VPS 上未安装 sing-box CLI，已跳过本地客户端配置校验。"
  fi
}

check_client_profile() {
  local profile="$1"
  if ! sing-box check -c "$profile"; then
    warn "sing-box CLI 未通过 $profile 校验；继续执行，因为客户端兼容性取决于导入端版本。"
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
  local archive_path="$PRIVATE_DIR/$PROFILE_ARCHIVE_NAME"
  local tun_global_name tun_split_name proxy_global_name proxy_split_name proxy_hy2_global_name proxy_hy2_split_name
  tun_global_name="$(profile_filename tun-global)"
  tun_split_name="$(profile_filename tun-split)"
  proxy_global_name="$(profile_filename proxy-global)"
  proxy_split_name="$(profile_filename proxy-split)"
  proxy_hy2_global_name="$(profile_filename proxy-hy2-global)"
  proxy_hy2_split_name="$(profile_filename proxy-hy2-split)"
  cat > "$PRIVATE_DIR/README.txt" <<EOF
代理部署信息：$SERVER_IP

本地客户端配置文件：
$PROFILE_DIR/$tun_global_name
$PROFILE_DIR/$tun_split_name
$PROFILE_DIR/$proxy_global_name
$PROFILE_DIR/$proxy_split_name
$PROFILE_DIR/$proxy_hy2_global_name
$PROFILE_DIR/$proxy_hy2_split_name

推荐导入：
iOS/SFM 全局或分流：
  $tun_split_name

桌面/浏览器仅代理：
  $proxy_split_name

Hysteria2 仅代理：
  $proxy_hy2_split_name

端口说明：
代理流量使用 TCP/$XRAY_PORT 的 VLESS Reality 和 UDP/$HY2_PORT 的 Hysteria2。

配置包：
$archive_path

下载到本机：
scp root@$SERVER_IP:$archive_path .

原始节点 URI：
$PRIVATE_DIR/import-uris.txt

配置文件：
$CONFIG_FILE
$STATE_FILE

常用命令：
singb links
singb edit proxy-split
singb regen
singb bundle

安全说明：
配置包里包含可用客户端凭据，请只通过 SSH/SCP 等可信通道下载。
EOF
  chmod 600 "$PRIVATE_DIR/README.txt"
}

profile_bundle_text() {
  load_config
  local archive_path="$PRIVATE_DIR/$PROFILE_ARCHIVE_NAME"
  local tun_split_name proxy_split_name
  tun_split_name="$(profile_filename tun-split)"
  proxy_split_name="$(profile_filename proxy-split)"
  cat <<EOF
配置包：
  $archive_path

下载到本机：
  scp root@$SERVER_IP:$archive_path .

解压后导入需要的 JSON，例如：
  $tun_split_name
  $proxy_split_name
EOF
}

bundle_profiles() {
  load_config
  disable_old_profile_service
  if [[ -f "$PROFILE_SERVICE" ]]; then
    systemctl disable --now "$(basename "$PROFILE_SERVICE")" >/dev/null 2>&1 || true
    remove_path "$PROFILE_SERVICE"
  fi
  remove_path "$PROFILE_WEB_ROOT"
  remove_path "$OLD_PROFILE_WEB_ROOT"

  install -d -m 700 "$PRIVATE_DIR"
  local archive_path="$PRIVATE_DIR/$PROFILE_ARCHIVE_NAME"
  rm -f "$archive_path"
  (
    cd "$PROFILE_DIR"
    python3 -m zipfile -c "$archive_path" \
      "$(profile_filename tun-global)" \
      "$(profile_filename tun-split)" \
      "$(profile_filename proxy-global)" \
      "$(profile_filename proxy-split)" \
      "$(profile_filename proxy-hy2-global)" \
      "$(profile_filename proxy-hy2-split)"
  )
  chmod 600 "$archive_path"

  info "已生成配置包：$archive_path"
}

restart_services() {
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray
  systemctl enable --now hysteria-server
  systemctl restart hysteria-server
}

regen_all() {
  require_root
  load_config
  ensure_state
  write_xray_config
  write_hysteria_config
  write_profiles
  bundle_profiles
  restart_services
}

parse_install_args() {
  init_defaults
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out-dir)
        [[ $# -ge 2 ]] || die "--out-dir 需要一个目录。"
        PRIVATE_DIR="$2"
        shift 2
        ;;
      --server-ip)
        [[ $# -ge 2 ]] || die "--server-ip 需要一个 IP。"
        SERVER_IP="$2"
        shift 2
        ;;
      --xray-sni)
        [[ $# -ge 2 ]] || die "--xray-sni 需要一个域名。"
        XRAY_SNI="$2"
        shift 2
        ;;
      --xray-dest)
        [[ $# -ge 2 ]] || die "--xray-dest 需要 HOST:PORT。"
        XRAY_DEST="$2"
        shift 2
        ;;
      --publish-port|--no-publish)
        warn "$1 已废弃；配置文件现在只打包到 VPS 本地，通过 scp 下载。"
        [[ "$1" == "--publish-port" && $# -ge 2 ]] && shift 2 || shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知安装选项：$1"
        ;;
    esac
  done
}

install_command() {
  require_root
  migrate_old_layout
  load_config
  parse_install_args "$@"
  detect_os
  install_packages

  if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP="$(detect_public_ip)"
  fi
  [[ -n "$SERVER_IP" ]] || die "无法检测公网 IPv4，请使用 --server-ip IP 指定。"

  write_config_file
  disable_old_profile_service
  check_port_conflicts
  enable_bbr
  install_xray
  install_hysteria2
  regen_all
  print_done
}

print_done() {
  local tun_split_name proxy_split_name proxy_hy2_split_name
  tun_split_name="$(profile_filename tun-split)"
  proxy_split_name="$(profile_filename proxy-split)"
  proxy_hy2_split_name="$(profile_filename proxy-hy2-split)"
  cat <<EOF

==> 安装完成

推荐导入：
  iOS/SFM：$tun_split_name
  桌面/浏览器仅代理：$proxy_split_name
  Hysteria2 仅代理：$proxy_hy2_split_name

端口说明：
  代理流量使用 TCP/$XRAY_PORT 的 VLESS Reality 和 UDP/$HY2_PORT 的 Hysteria2。

配置包下载：
$(profile_bundle_text)

后续管理：
  singb links
  singb status
  singb edit proxy-split
  singb regen

私有文件：
  $PRIVATE_DIR
EOF
}

links_command() {
  load_config
  local tun_split_name proxy_split_name proxy_hy2_split_name
  tun_split_name="$(profile_filename tun-split)"
  proxy_split_name="$(profile_filename proxy-split)"
  proxy_hy2_split_name="$(profile_filename proxy-hy2-split)"
  cat <<EOF
sing-box 客户端配置包：

$(profile_bundle_text)

推荐优先导入：
  $proxy_split_name

全设备 TUN 导入：
  $tun_split_name

Hysteria2 仅代理：
  $proxy_hy2_split_name

本地配置目录：
  $PROFILE_DIR
EOF
}

status_command() {
  load_config
  echo "服务："
  systemctl is-active xray 2>/dev/null | sed 's/^/  xray: /' || true
  systemctl is-active hysteria-server 2>/dev/null | sed 's/^/  hysteria-server: /' || true
  echo "  profile-server: 已关闭（配置只打包，不公网发布）"
  echo
  echo "端口监听："
  ss -H -tlnp "sport = :$XRAY_PORT" || true
  ss -H -ulnp "sport = :$HY2_PORT" || true
}

config_command() {
  load_config
  cat <<EOF
配置文件：
  $CONFIG_FILE

状态文件：
  $STATE_FILE

私有输出目录：
  $PRIVATE_DIR

客户端配置目录：
  $PROFILE_DIR

客户端配置包：
  $PRIVATE_DIR/$PROFILE_ARCHIVE_NAME

当前参数：
  SERVER_IP=$SERVER_IP
  XRAY_SNI=$XRAY_SNI
  XRAY_DEST=$XRAY_DEST
  XRAY_PORT=$XRAY_PORT
  HY2_PORT=$HY2_PORT
EOF
}

profiles_command() {
  load_config
  find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.json' -print | sort
}

profile_path_for_name() {
  local name="$1"
  local base="${name##*/}"
  base="${base%.json}"
  if [[ "$base" == "$SERVER_IP"-* ]]; then
    base="${base#"$SERVER_IP"-}"
  fi
  case "$base" in
    tun-global) profile_path tun-global ;;
    tun-split) profile_path tun-split ;;
    proxy-global) profile_path proxy-global ;;
    proxy-split) profile_path proxy-split ;;
    proxy-hy2-global) profile_path proxy-hy2-global ;;
    proxy-hy2-split) profile_path proxy-hy2-split ;;
    *) return 1 ;;
  esac
}

edit_command() {
  require_root
  load_config
  [[ $# -ge 1 ]] || die "用法：singb edit <配置名>"
  local path
  path="$(profile_path_for_name "$1")" || die "未知配置名：$1"
  [[ -f "$path" ]] || die "配置文件不存在：$path"

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
  bundle_profiles
  info "已更新并重新打包配置：$(basename "$path")"
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

update_command() {
  local url="$INSTALL_URL"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)
        [[ $# -ge 2 ]] || die "--url 需要一个 URL。"
        url="$2"
        shift 2
        ;;
      -h|--help)
        cat <<EOF
用法:
  singb update [--url URL]

默认从 GitHub main 分支下载最新 install.sh，更新 /usr/local/bin/singb，
然后使用现有 /etc/singb/config.env 和 /etc/singb/state.env 执行 regen。
EOF
        return 0
        ;;
      *)
        die "未知更新选项：$1"
        ;;
    esac
  done

  require_root
  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法下载更新脚本。"
  local tmp
  tmp="$(mktemp /tmp/singb-install.XXXXXX.sh)" || die "无法创建临时文件。"
  trap 'rm -f "$tmp"' RETURN

  info "正在下载最新安装脚本：$url"
  curl -fsSL "$url" -o "$tmp" || die "下载更新脚本失败：$url"
  chmod 700 "$tmp"

  info "正在更新 singb 并重新生成配置"
  bash "$tmp" regen
  info "更新完成"
  "$MANAGER_BIN" links
}

logs_command() {
  journalctl \
    -u xray \
    -u hysteria-server \
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
    update) update_command "$@" ;;
    bundle) require_root; bundle_profiles "$@"; links_command ;;
    restart) require_root; load_config; restart_services "$@" ;;
    rotate-secrets) rotate_secrets_command "$@" ;;
    logs) logs_command "$@" ;;
    help|-h|--help) usage ;;
    *)
      usage >&2
      die "未知命令：$command"
      ;;
  esac
}

main "$@"
MANAGER_EOF
  chmod 755 "$MANAGER_BIN"
}

write_manager
if [[ -e "$OLD_MANAGER_BIN" || -L "$OLD_MANAGER_BIN" ]]; then
  rm -f -- "$OLD_MANAGER_BIN"
fi
case "${1:-}" in
  install|uninstall|links|status|config|profiles|edit|regen|update|bundle|restart|rotate-secrets|logs|help|-h|--help)
    exec "$MANAGER_BIN" "$@"
    ;;
  *)
    exec "$MANAGER_BIN" install "$@"
    ;;
esac
