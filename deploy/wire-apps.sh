#!/usr/bin/env bash
# Point local apps at the synthetic-search-adapter. Idempotent; only touches
# apps it finds. See ../STACK.md.
#
#   ADAPTER=http://127.0.0.1:8010 ./wire-apps.sh
#
# Open WebUI is restarted (it reads this config at startup); cptr and omp are not.
set -uo pipefail

ADAPTER="${ADAPTER:-http://127.0.0.1:8010}"
WEBUI_DB="${WEBUI_DB:-$HOME/open-webui/data/webui.db}"
WEBUI_UNIT="${WEBUI_UNIT:-open-webui}"
CPTR_DB="${CPTR_DB:-$HOME/.cptr/app.db}"

did=0; skipped=0
say(){ printf '  %s\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

echo "adapter: $ADAPTER"
curl -fsS "$ADAPTER/health" >/dev/null 2>&1 \
  || { echo "ERROR: adapter not healthy at $ADAPTER/health — install/start it first." >&2; exit 1; }

# --- Open WebUI -----------------------------------------------------------
echo
echo "Open WebUI:"
if [ -f "$WEBUI_DB" ] && have sqlite3; then
  restart=0
  systemctl is-active --quiet "$WEBUI_UNIT" 2>/dev/null && { sudo systemctl stop "$WEBUI_UNIT"; restart=1; }
  sqlite3 "$WEBUI_DB" "INSERT OR REPLACE INTO config (key,value,updated_at) VALUES
   ('web.search.engine','\"external\"',strftime('%s','now')),
   ('web.search.external_web_search_url','\"$ADAPTER/external\"',strftime('%s','now')),
   ('web.search.external_web_search_api_key','\"local-adapter\"',strftime('%s','now'));"
  say "set engine=external -> $ADAPTER/external"
  if [ "$restart" = 1 ]; then
    sudo systemctl start "$WEBUI_UNIT"; say "restarted $WEBUI_UNIT"; sleep 5
    curl -fsS -o /dev/null "http://127.0.0.1:8080/health" && say "healthy" || say "WARN: health check failed"
  else
    say "NOTE: $WEBUI_UNIT not running; start it to apply"
  fi
  did=$((did+1))
else
  say "not found (looked for $WEBUI_DB) — skipped"; skipped=$((skipped+1))
fi

# --- cptr -----------------------------------------------------------------
echo
echo "cptr:"
if [ -f "$CPTR_DB" ] && have sqlite3; then
  sqlite3 "$CPTR_DB" "INSERT OR REPLACE INTO config (key,value,updated_at) VALUES
   ('web.search_provider','\"searxng\"',strftime('%s','now')),
   ('web.searxng_base_url','\"$ADAPTER\"',strftime('%s','now'));"
  say "set web.search_provider=searxng -> $ADAPTER  (read live; no restart)"
  did=$((did+1))
else
  say "not found (looked for $CPTR_DB) — skipped"; skipped=$((skipped+1))
fi

# --- omp ------------------------------------------------------------------
echo
echo "omp:"
if have omp; then
  CUR="$(omp config get modelRoles 2>/dev/null | head -1)"
  case "$CUR" in
    *'"web":"synthetic"'*) say "already set (web=synthetic)";;
    *)
      omp config set modelRoles '{"default":"synthetic/hf:zai-org/GLM-5.3-Flash","web":"synthetic"}' >/dev/null 2>&1 \
        && say "set modelRoles.web=synthetic (native provider; no adapter)" \
        || say "WARN: could not set modelRoles — set it by hand (see STACK.md)"
      ;;
  esac
  did=$((did+1))
else
  say "omp not installed — skipped"; skipped=$((skipped+1))
fi

echo
echo "wired: $did app(s); skipped: $skipped"
echo "verify with: bash $(dirname "$0")/verify.sh \"a test query\""
