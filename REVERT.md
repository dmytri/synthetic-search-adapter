# Revert Synthetic Search integration

Everything is additive; none of the original config was deleted. Snapshots live
in ~/backups/synthetic-search-baseline/.

## 1. Open WebUI -> back to DuckDuckGo
    sudo systemctl stop open-webui
    sqlite3 /home/exedev/open-webui/data/webui.db <<'EOF'
    INSERT OR REPLACE INTO config (key, value, updated_at) VALUES
     ('web.search.engine', '"duckduckgo"', strftime('%s','now'));
    DELETE FROM config WHERE key IN ('web.search.external_web_search_url','web.search.external_web_search_api_key');
    EOF
    sudo systemctl start open-webui
(or restore any values from open-webui-websearch-config.txt snapshot)

## 2. cptr -> back to auto chain (DuckDuckGo fallback)
    sqlite3 /home/exedev/.cptr/app.db "DELETE FROM config WHERE key IN ('web.search_provider','web.searxng_base_url')"

## 3. omp -> back to Parallel chain
Remove the `web: synthetic` line from modelRoles in ~/.omp/agent/config.yml
(snapshot: ~/backups/synthetic-search-baseline/omp-config.yml)

## 4. bb -> remove plugin
    bb plugin remove synthetic-search --yes
    rm -rf /home/exedev/bb-plugin-synthetic-search   # source dir (optional)

## 5. Stop & remove the adapter service
    sudo systemctl disable --now synthetic-search-adapter.service
    sudo rm /etc/systemd/system/synthetic-search-adapter.service
    sudo systemctl daemon-reload
    rm -rf /home/exedev/synthetic-search-adapter     # binary, key, source (optional)
