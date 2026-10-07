# synthetic-search-adapter

A tiny localhost HTTP service that exposes [Synthetic](https://synthetic.new)'s
zero-data-retention web search API in the request/response shapes that other
self-hosted apps already speak.

Synthetic's search API is one fixed shape:

```json
POST https://api.synthetic.new/v2/search   {"query": "..."}
->  {"results": [{"url": "...", "title": "...", "text": "...", "published": "..."}]}
```

Several apps can't consume that directly:

| App | Why not | What it wants instead |
| --- | --- | --- |
| **Open WebUI** | its `external` search engine expects a bare JSON *array* | `[{"link","title","snippet"}]` |
| **cptr** | has no generic provider; the only URL-configurable one is SearXNG | SearXNG JSON API |
| **bb** | plugin wants a simple JSON search endpoint | Synthetic native, or `/external` |

This adapter translates, and keeps the API key in one place instead of scattered
across each app's config (and instead of patching app code that upgrades would
overwrite).

## Endpoints

| Route | Method | Body / query | Response | For |
| --- | --- | --- | --- | --- |
| `/external` | POST | `{"query": "...", "count": 3}` | `[{"link","title","snippet"}]` | Open WebUI (`external` engine) |
| `/search` | GET | `?q=...&format=json` | SearXNG JSON (`{query,answers,infoboxes,results:[{url,title,content,score}],suggestions}`) | cptr (`searxng` provider) |
| `/v2/search` | POST | `{"query": "..."}` | `{"results":[...]}` (Synthetic native) | bb plugin, curl |
| `/health` | GET | — | `ok` | monitoring / installer |

Per-result text is truncated to 1200 bytes (`/v2/search` to 8000) because
Synthetic returns whole page text and the consuming apps were sized for short
search snippets.

## Install

```sh
git clone https://github.com/dmytri/synthetic-search-adapter
cd synthetic-search-adapter
make build
sudo make install          # binary -> /usr/local/bin, unit -> /etc/systemd/system
sudoedit /etc/synthetic-search-adapter/adapter.env   # set SYNTHETIC_API_KEY
sudo systemctl enable --now synthetic-search-adapter
./smoke.sh                 # verify every route
```

`make install` is idempotent and never overwrites an existing key file.
Update with `git pull && make build && sudo make install && sudo systemctl restart synthetic-search-adapter`.
Remove with `sudo make uninstall`.

Running this as part of the full search stack (Open WebUI + cptr + omp)?
See **[STACK.md](STACK.md)** for the end-to-end runbook and
`deploy/wire-apps.sh` to configure the apps automatically.

## Configure clients

Exact commands for each app are in [STACK.md](STACK.md). Summary:

**Open WebUI** — Admin Settings → Web Search → engine **external**,
URL `http://127.0.0.1:8010/external`. (Or set `EXTERNAL_WEB_SEARCH_URL`.)

**cptr** — set its `searxng` provider at the adapter:

```sh
sqlite3 ~/.cptr/app.db "INSERT OR REPLACE INTO config (key,value,updated_at) VALUES
 ('web.search_provider','\"searxng\"',strftime('%s','now')),
 ('web.searxng_base_url','\"http://127.0.0.1:8010\"',strftime('%s','now'));"
```

> cptr has no custom-provider option, so this presents the adapter as SearXNG.
> If cptr ever gains a generic search provider, prefer that.

**bb** — the plugin in `dmytri/bb-plugin-synthetic-search` points at `/v2/search`.

**omp** — needs no adapter; it has a native `synthetic` search provider:

```sh
omp config set modelRoles '{"default":"synthetic/hf:zai-org/GLM-5.3-Flash","web":"synthetic"}'
```

## Configuration

| Env var | Default | Meaning |
| --- | --- | --- |
| `SYNTHETIC_API_KEY` | — (required) | Synthetic API key |
| `ADAPTER_LISTEN_ADDR` | `127.0.0.1:8010` | listen address |

## Development

```sh
make build        # compile
make vet          # static checks
ADAPTER=http://127.0.0.1:8010 ./smoke.sh   # route/shape smoke test (running service)
```

`deploy/` holds deployment tooling that assumes Open WebUI, cptr and omp run on
the same host — not needed to use the adapter by itself:

- `wire-apps.sh` — point the apps at the adapter (idempotent)
- `verify.sh` — end-to-end check across all apps
- `run-tests.sh` — the assertion suite (URL-overlap with Synthetic)

## Why Go

The whole service is ~240 lines using only the standard library — `net/http`
covers everything, so there are no dependencies to audit, pin, or update.

The bigger reason is deployment: Go compiles to a single static binary with no
runtime, so the systemd unit is just an `ExecStart` line and a key file. A Python
equivalent would need a virtualenv, a requirements pin, and a Python that
outlives OS upgrades; a Node one needs node_modules. For a small piece of
always-on infrastructure wedged between other people's apps, "copy one file and
run it" is the property worth optimizing for.

Python would have been a perfectly reasonable choice too — the surrounding stack
(Open WebUI, cptr) is Python. Go was chosen for operational simplicity, not
capability.

## License

MIT — see [LICENSE](LICENSE).
