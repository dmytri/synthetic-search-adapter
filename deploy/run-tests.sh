#!/usr/bin/env bash
# Mutation-testable suite: proves each app actually gets its results from
# Synthetic (via the adapter), not merely that "search returns something".
# Usage: bash run-tests.sh [query]
Q="${1:-saleor 3.23.28 release}"
ADAPTER=http://127.0.0.1:8010
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# --- authoritative Synthetic results (via adapter) for URL-overlap assertions
SYN_URLS=$(curl -s -m 20 -X POST "$ADAPTER/v2/search" -H 'Content-Type: application/json' \
  -d "{\"query\":\"$Q\"}" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
print('\n'.join(r['url'] for r in d.get('results',[])))" 2>/dev/null)

overlap(){ # $1 = text/urls from app, $2 = label
  local n
  n=$(python3 - "$1" <<PY
import sys
blob=sys.argv[1]
syn="""$SYN_URLS""".split()
print(sum(1 for u in syn if u and u in blob))
PY
)
  if [ "${n:-0}" -ge 1 ]; then ok "$2 returns Synthetic URLs ($n match)"; else bad "$2 has NO Synthetic URL overlap"; fi
}

echo "=== 1. adapter -> Synthetic (authoritative) ==="
if [ -n "$SYN_URLS" ]; then ok "adapter returns $(echo "$SYN_URLS" | wc -l) Synthetic results"; else bad "adapter down or returned nothing"; fi

echo "=== 2. omp ==="
OUT=$(timeout 90 omp search "$Q" --compact 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
echo "$OUT" | grep -q "Provider: Synthetic" && ok "omp provider is Synthetic" || bad "omp provider is NOT Synthetic: $(echo "$OUT" | grep -o 'Provider:.*' | head -1)"

echo "=== 3. open-webui (real search_web path) ==="
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health)
[ "$CODE" = 200 ] && ok "open-webui health 200" || bad "open-webui health $CODE"
WEBUI_SECRET_KEY=x DATA_DIR=/home/exedev/open-webui/data timeout 120 \
  /home/exedev/open-webui/venv/bin/python -c "
import asyncio
from open_webui.routers.retrieval import get_retrieval_config, search_web
class R:
    class state: pass
    client=None
rc = asyncio.run(get_retrieval_config())
assert rc.WEB_SEARCH_ENGINE=='external', 'engine='+str(rc.WEB_SEARCH_ENGINE)
res = asyncio.run(search_web(R(), rc.WEB_SEARCH_ENGINE, '''$Q'''))
assert len(res)>0, 'no results'
print('\n'.join((r.link or '') for r in res))
" 2>/dev/null > /tmp/owui_urls.txt
if [ -s /tmp/owui_urls.txt ]; then ok "open-webui search_web returned $(wc -l < /tmp/owui_urls.txt) results"; overlap "$(cat /tmp/owui_urls.txt)" "open-webui"; else bad "open-webui search_web returned nothing (engine/URL broken?)"; fi

echo "=== 4. cptr (real handler) ==="
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/)
[ "$CODE" = 200 ] && ok "cptr health 200" || bad "cptr health $CODE"
CPTR_OUT=$(/home/exedev/cptr/venv/bin/python -c "
import asyncio,sys
sys.path.insert(0,'/home/exedev/cptr/venv/lib/python3.12/site-packages')
from cptr.utils.web.search import web_search_handler
print(asyncio.run(web_search_handler('''$Q''')))" 2>/dev/null)
if [ -n "$CPTR_OUT" ]; then ok "cptr handler returned ${#CPTR_OUT} chars"; overlap "$CPTR_OUT" "cptr"; else bad "cptr handler returned nothing"; fi

echo "=== 5. bb (plugin command) ==="
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8888/)
[ "$CODE" = 200 ] && ok "bb health 200" || bad "bb health $CODE"
if bb plugin list 2>/dev/null | grep -q "^synthetic-search.*running"; then
  BB_OUT=$(timeout 60 bb synthetic-search "$Q" --limit 3 2>/dev/null)
  if [ -n "$BB_OUT" ]; then ok "bb plugin returned output"; overlap "$BB_OUT" "bb"; else bad "bb plugin returned nothing"; fi
else bad "bb synthetic-search plugin not running"; fi

echo; echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
