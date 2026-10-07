#!/usr/bin/env bash
# Installer for synthetic-search-adapter.
#
#   curl -fsSL https://raw.githubusercontent.com/dmytri/synthetic-search-adapter/main/install.sh | sudo bash
#   sudo ./install.sh --key sk-... --addr 127.0.0.1:8010
#
# Installs the binary to /usr/local/bin, the systemd unit, and a key file at
# /etc/synthetic-search-adapter/adapter.env (mode 600), then starts the service.
set -euo pipefail

REPO="dmytri/synthetic-search-adapter"
BINARY="synthetic-search-adapter"
PREFIX="${PREFIX:-/usr/local}"
CONFDIR="${CONFDIR:-/etc/synthetic-search-adapter}"
UNITDIR="${UNITDIR:-/etc/systemd/system}"

API_KEY="${SYNTHETIC_API_KEY:-}"
LISTEN_ADDR="${ADAPTER_LISTEN_ADDR:-127.0.0.1:8010}"
VERSION="${VERSION:-latest}"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --key)    API_KEY="$2"; shift 2 ;;
    --addr)   LISTEN_ADDR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "error: must run as root (use sudo)" >&2; exit 1; }

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) GOARCH=amd64 ;;
  aarch64|arm64) GOARCH=arm64 ;;
  *) echo "error: unsupported arch $ARCH" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SRCDIR=""

# 1) local checkout?
if [ -f "$(dirname "$0")/main.go" ]; then
  SRCDIR="$(cd "$(dirname "$0")" && pwd)"
  echo "==> using local source at $SRCDIR"
# 2) released binary?
elif [ "$VERSION" != "latest" ] || curl -fsSL -o "$TMP/$BINARY.tar.gz" \
     "https://github.com/$REPO/releases/latest/download/${BINARY}_${GOARCH}.tar.gz" 2>/dev/null; then
  if [ -f "$TMP/$BINARY.tar.gz" ]; then
    echo "==> unpacking release binary"
    tar -xzf "$TMP/$BINARY.tar.gz" -C "$TMP"
    install -Dm755 "$TMP/$BINARY" "$PREFIX/bin/$BINARY"
  fi
fi

# 3) fall back to building from source
if [ ! -x "$PREFIX/bin/$BINARY" ] && [ -z "$SRCDIR" ]; then
  command -v go >/dev/null || {
    echo "error: no release binary for $GOARCH and 'go' is not installed." >&2
    echo "       install Go (https://go.dev/dl) and re-run." >&2; exit 1; }
  echo "==> fetching source and building"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" \
    | tar -xz -C "$TMP"
  SRCDIR="$TMP/$BINARY-main"
fi

if [ -n "$SRCDIR" ]; then
  echo "==> building"
  ( cd "$SRCDIR" && go build -trimpath -o "$TMP/$BINARY" . )
  install -Dm755 "$TMP/$BINARY" "$PREFIX/bin/$BINARY"
fi

# --- config ---------------------------------------------------------------
install -d -m755 "$CONFDIR"
if [ -f "$CONFDIR/adapter.env" ]; then
  echo "==> keeping existing $CONFDIR/adapter.env"
else
  if [ -z "$API_KEY" ]; then
    printf 'Synthetic API key (from https://synthetic.new): '
    read -r API_KEY </dev/tty || true
  fi
  [ -n "$API_KEY" ] || { echo "error: no API key given" >&2; exit 1; }
  umask 077
  printf 'SYNTHETIC_API_KEY=%s\nADAPTER_LISTEN_ADDR=%s\n' "$API_KEY" "$LISTEN_ADDR" \
    > "$CONFDIR/adapter.env"
  chmod 600 "$CONFDIR/adapter.env"
  echo "==> wrote $CONFDIR/adapter.env"
fi

# --- unit -----------------------------------------------------------------
if [ -f "$(dirname "$0")/$BINARY.service" ]; then
  install -Dm644 "$(dirname "$0")/$BINARY.service" "$UNITDIR/$BINARY.service"
else
  cat > "$UNITDIR/$BINARY.service" <<UNIT
[Unit]
Description=Synthetic Search adapter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$CONFDIR/adapter.env
ExecStart=$PREFIX/bin/$BINARY
Restart=on-failure
RestartSec=5
DynamicUser=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
UNIT
fi

systemctl daemon-reload
systemctl enable --now "$BINARY.service"
sleep 1

# --- verify ---------------------------------------------------------------
if systemctl is-active --quiet "$BINARY.service"; then
  ADDR="$LISTEN_ADDR"
  if command -v curl >/dev/null; then
    if curl -fsS "http://$ADDR/health" >/dev/null 2>&1; then
      echo "==> OK: $BINARY is running and healthy on $ADDR"
    else
      echo "==> service active but /health did not answer on $ADDR (check logs)"
    fi
  fi
  echo
  echo "Point your app at it, e.g. for Open WebUI:"
  echo "  Admin Settings -> Web Search -> engine: external"
  echo "  URL: http://$ADDR/external"
else
  echo "error: service failed to start; check: journalctl -u $BINARY -n 50" >&2
  exit 1
fi
