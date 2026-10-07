#!/usr/bin/env bash
# Proves each app is wired to Synthetic, not just "search works".
# Usage: bash verify.sh [query]
Q="${1:-saleor 3.23.28 release}"
echo "Query: $Q"
echo

echo "1) ADAPTER (what all apps actually call) -- direct Synthetic, authoritative:"
curl -s -X POST http://127.0.0.1:8010/v2/search -H 'Content-Type: application/json' \
  -d "{\"query\":\"$Q\"}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['results'][:3]: print('   ', r['url'])
" 2>/dev/null || echo "    ADAPTER DOWN"
echo

echo "2) OPEN WEBUI -- engine setting + what its last real searches returned:"
echo -n "    configured engine: "
sqlite3 /home/exedev/open-webui/data/webui.db "SELECT value FROM config WHERE key='web.search.engine'"
echo -n "    external URL:      "
sqlite3 /home/exedev/open-webui/data/webui.db "SELECT value FROM config WHERE key='web.search.external_web_search_url'"
echo "    last searches it logged (only the external engine logs this line):"
sudo journalctl -u open-webui --since "24 hours ago" --no-pager 2>/dev/null \
  | grep -o "External search results: \[SearchResult(link='[^']*'" | tail -3 \
  | sed "s/.*link='/      -> /"
echo "    ^ compare these URLs to section 1; DuckDuckGo links would contain duckduckgo.com/l/"
echo

echo "3) CPTR -- provider config + live handler output:"
sqlite3 /home/exedev/.cptr/app.db "SELECT '    '||key||' = '||value FROM config WHERE key LIKE 'web%'"
/home/exedev/cptr/venv/bin/python -c "
import asyncio,sys
sys.path.insert(0,'/home/exedev/cptr/venv/lib/python3.12/site-packages')
from cptr.utils.web.search import web_search_handler
r=asyncio.run(web_search_handler('$Q'))
print('    handler returned', len(r), 'chars; first URL:', r.split(chr(10))[1] if chr(10) in r else r[:60])
" 2>/dev/null || echo "    CPTR handler failed"
echo

echo "4) OMP -- resolved web-search provider (should say Synthetic):"
timeout 60 omp search "$Q" --compact 2>&1 | grep -o "Web Search.*" | head -1 \
  | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/    /'
echo

echo "5) BB -- plugin status + live command:"
bb plugin list 2>/dev/null | grep -A1 "^synthetic-search" | head -2 | sed 's/^/    /'
timeout 60 bb synthetic-search "$Q" --limit 1 2>/dev/null | head -2 | sed 's/^/    /'
