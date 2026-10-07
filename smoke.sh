#!/usr/bin/env bash
# Smoke test every route of a RUNNING adapter.
#   ADAPTER=http://127.0.0.1:8010 ./smoke.sh
set -uo pipefail
ADAPTER="${ADAPTER:-http://127.0.0.1:8010}"
Q="${1:-example.com}"
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got $2 want $3)"; fail=1; fi; }

code=$(curl -s -o /dev/null -w '%{http_code}' "$ADAPTER/health")
chk "GET /health" "$code" "200"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ADAPTER/external" \
  -H 'Content-Type: application/json' -d "{\"query\":\"$Q\",\"count\":2}")
chk "POST /external" "$code" "200"
curl -s -X POST "$ADAPTER/external" -H 'Content-Type: application/json' \
  -d "{\"query\":\"$Q\",\"count\":2}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert isinstance(d,list) and d, 'expected non-empty array'
assert {'link','title','snippet'} <= set(d[0]), d[0].keys()
print('ok   /external shape [{link,title,snippet}]')
" || fail=1

code=$(curl -s -o /dev/null -w '%{http_code}' "$ADAPTER/search?q=$Q&format=json")
chk "GET /search" "$code" "200"
curl -s "$ADAPTER/search?q=$Q&format=json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert {'results','query','answers'} <= set(d), d.keys()
assert d['results'] and {'url','title','content'} <= set(d['results'][0])
print('ok   /search shape {results:[{url,title,content}]}')
" || fail=1

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ADAPTER/v2/search" \
  -H 'Content-Type: application/json' -d "{\"query\":\"$Q\"}")
chk "POST /v2/search" "$code" "200"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ADAPTER/external" \
  -H 'Content-Type: application/json' -d '{}')
chk "POST /external (bad input -> 400)" "$code" "400"

exit $fail
