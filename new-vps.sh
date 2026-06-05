#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

if [[ -x "$SCRIPT_DIR/install.sh" ]]; then
  exec "$SCRIPT_DIR/install.sh" "$@"
fi

cat >&2 <<'EOF'
new-vps.sh has been replaced by install.sh.

Use:
  bash install.sh

Or from GitHub raw:
  curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/install.sh -o /tmp/singbox-vps-install.sh
  bash /tmp/singbox-vps-install.sh
EOF
exit 1
