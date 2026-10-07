// synthetic-search-adapter: tiny localhost adapter that exposes Synthetic's
// zero-data-retention web search API (/v2/search) in the shapes that local
// apps already speak:
//
//	POST /external      -> Open WebUI "external" engine: [{link,title,snippet}]
//	GET  /search        -> SearXNG JSON API: {query,answers,infoboxes,results,suggestions}
//	POST /v2/search     -> passthrough of Synthetic's native response
//
// Revert: see REVERT.md in this directory.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

const syntheticURL = "https://api.synthetic.new/v2/search"

var httpClient = &http.Client{Timeout: 25 * time.Second}

func apiKey() string { return os.Getenv("SYNTHETIC_API_KEY") }

type syntheticResult struct {
	URL       string `json:"url"`
	Title     string `json:"title"`
	Text      string `json:"text"`
	Published string `json:"published"`
}

// syntheticSearch calls Synthetic and returns raw results.
func syntheticSearch(query string) ([]syntheticResult, error) {
	body, _ := json.Marshal(map[string]string{"query": query})
	req, err := http.NewRequest(http.MethodPost, syntheticURL, strings.NewReader(string(body)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey())
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("synthetic returned %d: %s", resp.StatusCode, truncate(string(raw), 300))
	}
	var parsed struct {
		Results []syntheticResult `json:"results"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, fmt.Errorf("decode synthetic response: %w", err)
	}
	return parsed.Results, nil
}

// Per-result text caps keep downstream app context reasonable (DuckDuckGo
// snippets, which these apps used before, are short). /v2/search passthrough
// stays near-full fidelity.
const snippetCap = 1200
const passthroughCap = 8000

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	log.Printf("error: %s", msg)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// handleExternal serves Open WebUI's "external" web search engine.
// Request: {"query": string, "count": int}; Response: [{link,title,snippet}]
func handleExternal(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Query string `json:"query"`
		Count int    `json:"count"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&in); err != nil || strings.TrimSpace(in.Query) == "" {
		writeErr(w, http.StatusBadRequest, "invalid request: need JSON body with non-empty \"query\"")
		return
	}
	results, err := syntheticSearch(in.Query)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	type extResult struct {
		Link    string `json:"link"`
		Title   string `json:"title"`
		Snippet string `json:"snippet"`
	}
	out := make([]extResult, 0, len(results))
	for _, res := range results {
		if in.Count > 0 && len(out) >= in.Count {
			break
		}
		out = append(out, extResult{Link: res.URL, Title: res.Title, Snippet: truncate(res.Text, snippetCap)})
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

// handleSearxng serves a SearXNG JSON-API-compatible response for cptr.
// Request: GET /search?q=...&format=json
func handleSearxng(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeErr(w, http.StatusBadRequest, "missing ?q=")
		return
	}
	count := 5
	if c := r.URL.Query().Get("count"); c != "" {
		fmt.Sscanf(c, "%d", &count)
	}
	results, err := syntheticSearch(q)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	type searResult struct {
		URL     string  `json:"url"`
		Title   string  `json:"title"`
		Content string  `json:"content"`
		Score   float64 `json:"score"`
	}
	out := make([]searResult, 0, len(results))
	for i, res := range results {
		if count > 0 && i >= count {
			break
		}
		score := float64(len(results) - i) // stable descending relevance
		out = append(out, searResult{URL: res.URL, Title: res.Title, Content: truncate(res.Text, snippetCap), Score: score})
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"query":       q,
		"answers":     []string{},
		"infoboxes":   []any{},
		"results":     out,
		"suggestions": []string{},
	})
}

// handlePassthrough forwards Synthetic's native /v2/search response.
func handlePassthrough(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Query string `json:"query"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&in); err != nil || strings.TrimSpace(in.Query) == "" {
		writeErr(w, http.StatusBadRequest, "invalid request: need JSON body with non-empty \"query\"")
		return
	}
	results, err := syntheticSearch(in.Query)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	for i := range results {
		results[i].Text = truncate(results[i].Text, passthroughCap)
	}
	json.NewEncoder(w).Encode(map[string]any{"results": results})
}

func main() {
	if apiKey() == "" {
		log.Fatal("SYNTHETIC_API_KEY not set")
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/external", handleExternal)
	mux.HandleFunc("/search", handleSearxng)
	mux.HandleFunc("/v2/search", handlePassthrough)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeErr(w, http.StatusNotFound, "unknown route; use /external, /search, /v2/search, /health")
	})

	// Access log: every request with query and duration, so adapter traffic
	// is attributable in `journalctl -u synthetic-search-adapter`.
	handler := logMiddleware(mux)

	addr := os.Getenv("ADAPTER_LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8010"
	}
	log.Printf("synthetic-search-adapter listening on %s", addr)
	server := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}

// loggingResponseWriter preserves the status code for the access log.
type loggingResponseWriter struct {
	http.ResponseWriter
	status int
}

func (w *loggingResponseWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func logMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		var q string
		if r.Method == http.MethodPost {
			// Buffer the body so handlers can still decode it.
			raw, _ := io.ReadAll(io.LimitReader(r.Body, 64<<10))
			r.Body.Close()
			r.Body = io.NopCloser(bytes.NewReader(raw))
			var in struct {
				Query string `json:"query"`
			}
			json.Unmarshal(raw, &in)
			q = in.Query
		} else {
			q = r.URL.Query().Get("q")
		}
		lw := &loggingResponseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(lw, r)
		log.Printf("%s %s status=%d dur=%s query=%q", r.Method, r.URL.Path, lw.status, time.Since(start).Round(time.Millisecond), q)
	})
}
