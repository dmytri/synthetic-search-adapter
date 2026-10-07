#!/usr/bin/env bash
set -euo pipefail
BINARY="synthetic-search-adapter"
CONFDIR="${CONFDIR:-/etc/synthetic-search-adapter}"
[ "$(id -u)" = 0 ] || { echo "error: must run as root" >&2; exit 1; }
systemctl disable --now "$BINARY.service" 2>/dev/null || true
rm -f "/etc/systemd/system/$BINARY.service" "/usr/local/bin/$BINARY"
systemctl daemon-reload
echo "removed $BINARY. Config kept at $CONFDIR/adapter.env"
echo "delete it manually if you no longer need the key:  sudo rm -rf $CONFDIR"
