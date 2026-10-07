# Synthetic web-search stack — runbook

How to stand up (or rebuild on a new VM) web search for **Open WebUI**, **cptr**
and **omp**, all backed by Synthetic's zero-data-retention search API.

Written for a single-operator box. `deploy/wire-apps.sh` automates the "Wire the
apps" section; the rest is copy-paste.

## Architecture

```
                            ┌───────────────────────────┐
  Open WebUI ── /external ──┤                           │
  cptr ──────── /search   ──┤  synthetic-search-adapter ├──► api.synthetic.new/v2/search
  bb (opt.) ─── /v2/search──┤  127.0.0.1:8010           │
                            └───────────────────────────┘
  omp ─────────────────────────────────────────────────────► (direct, native provider)
```

Two routes to the same API:

- **omp** calls Synthetic directly — it has a native `synthetic` search provider
  and keeps its own key in its keyring. No adapter, no dependency on it.
- **Open WebUI, cptr, (bb)** go through the adapter, which translates Synthetic's
  response shape into what each app expects and holds the API key in one place.

That split is deliberate: stopping the adapter breaks the three apps but not omp.

## 1. Install the adapter

```sh
git clone https://github.com/dmytri/synthetic-search-adapter
cd synthetic-search-adapter
make build
sudo make install                      # binary + systemd unit (+ example key file)
sudoedit /etc/synthetic-search-adapter/adapter.env    # SYNTHETIC_API_KEY=sk-...
sudo systemctl enable --now synthetic-search-adapter
./smoke.sh                             # verifies every route
```

`make install` is idempotent and never overwrites an existing key file.
Updating later: `git pull && make build && sudo make install && sudo systemctl restart synthetic-search-adapter`.

## 2. Wire the apps

### Open WebUI — engine `external`

Admin Settings → Web Search → engine **external**, URL
`http://127.0.0.1:8010/external`. Equivalent from the shell (needs a restart
because Open WebUI reads this config at startup):

```sh
DB=~/open-webui/data/webui.db          # adjust to your DATA_DIR
sudo systemctl stop open-webui
sqlite3 "$DB" "INSERT OR REPLACE INTO config (key,value,updated_at) VALUES
 ('web.search.engine','\"external\"',strftime('%s','now')),
 ('web.search.external_web_search_url','\"http://127.0.0.1:8010/external\"',strftime('%s','now')),
 ('web.search.external_web_search_api_key','\"local-adapter\"',strftime('%s','now'));"
sudo systemctl start open-webui
```

### cptr — SearXNG provider pointed at the adapter

cptr has no generic search provider; SearXNG is its only URL-configurable one, so
the adapter presents that shape. Config is read live — **no restart needed**:

```sh
sqlite3 ~/.cptr/app.db "INSERT OR REPLACE INTO config (key,value,updated_at) VALUES
 ('web.search_provider','\"searxng\"',strftime('%s','now')),
 ('web.searxng_base_url','\"http://127.0.0.1:8010\"',strftime('%s','now'));"
```

### omp — native provider, no adapter

```sh
omp config set modelRoles '{"default":"synthetic/hf:zai-org/GLM-5.3-Flash","web":"synthetic"}'
```

omp re-reads its config live, so running sessions pick this up without a restart.
Nested form (`omp config set modelRoles.web …`) does **not** work — set the whole record.

### bb (optional, non-critical)

A **local-only** plugin at `~/bb-plugin-synthetic-search/` (its own git repo, not
on GitHub) adds `bb synthetic-search`, which calls the adapter's `/v2/search`.

Droppable — nothing here depends on it, and bb's only agent provider is omp,
which searches Synthetic natively anyway. The plugin's README has the purge
commands.

## 3. Verify

```sh
./smoke.sh                              # adapter's own routes + shapes
bash deploy/verify.sh "some query"      # end-to-end across all apps
```

`deploy/verify.sh` prints the adapter's authoritative results, then each app's
config and live output, and flags whether the URLs match Synthetic's. A quick
manual check: run one web search in Open WebUI, then

```sh
sudo journalctl -u synthetic-search-adapter -f     # should log POST /external ...
```

## 4. Fresh-VM checklist

- [ ] Go installed (`go version`)
- [ ] Adapter cloned, `make build && sudo make install`, key set, service enabled
- [ ] `./smoke.sh` passes
- [ ] Open WebUI: engine `external` (+ restart)
- [ ] cptr: `searxng` provider → adapter
- [ ] omp: `modelRoles.web = synthetic`
- [ ] `deploy/verify.sh` shows Synthetic URLs for each app
- [ ] Revert notes if needed: see `REVERT.md`

## Notes / gotchas

- The adapter is **localhost-only** (`127.0.0.1:8010`). It is not exposed.
- Result text is truncated (1200 B per result; 8000 B on `/v2/search`) because
  Synthetic returns whole page text and the apps were sized for short snippets.
- Open WebUI's search engines are a hardcoded list — `external` is the *official*
  extension point, not a workaround. cptr's SearXNG impersonation *is* a
  workaround; prefer a native provider if cptr ever adds one.
