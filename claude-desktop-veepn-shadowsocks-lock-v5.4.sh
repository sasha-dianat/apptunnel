#!/bin/bash
# Compatibility entry point for the former Claude launcher v5.4.
# The implementation is intentionally centralized in tunnel-lock.sh v2.1 so a
# direct launch cannot reintroduce the legacy machine-wide DNS/PF rules.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
LOCK="$HERE/tunnel/bin/tunnel-lock.sh"
APP="/Applications/Claude.app"
FORWARD=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) [ "$#" -ge 2 ] || { echo "--app requires a path" >&2; exit 2; }
           APP="$2"; shift 2 ;;
    --physical-if|--guard-if)
           [ "$#" -ge 2 ] || { echo "$1 requires an interface" >&2; exit 2; }
           FORWARD+=(--guard-if "$2"); shift 2 ;;
    --socks-host|--socks-port)
           [ "$#" -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }
           FORWARD+=("$1" "$2"); shift 2 ;;
    --check-url)
           [ "$#" -ge 2 ] || { echo "--check-url requires a URL" >&2; exit 2; }
           echo "Note: --check-url is retired; v2.1 uses calibrated literal-IP leak probes." >&2
           shift 2 ;;
    --yes) FORWARD+=(--yes); shift ;;
    -h|--help)
           cat <<'EOF'
Claude protected launcher compatibility entry point

This command now delegates to the audited shared tunnel-lock.sh v2.1 engine.
Supported options: --app, --physical-if/--guard-if, --socks-host,
--socks-port, --yes.
EOF
           exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -x "$LOCK" ] || { echo "Tunnel engine not found: $LOCK" >&2; exit 1; }
exec "$LOCK" --app "$APP" ${FORWARD[@]+"${FORWARD[@]}"}
