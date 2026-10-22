package gate

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/httpcaddyfile"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
	"go.uber.org/zap"
)

type entryHealth struct {
	OK      bool `json:"ok"`
	Missing int  `json:"missing"`
}

type healthState struct {
	mu      sync.RWMutex
	entries map[string]entryHealth
	cancel  context.CancelFunc
	done    chan struct{}
}

var healthRegistry = struct {
	sync.RWMutex
	states map[string]*healthState
}{states: map[string]*healthState{}}

// startChecker validates the one upstream it may probe and registers initial
// failed state before the asynchronous first check. A dead CPA never looks
// healthy merely because Caddy started.
func (g *Gate) startChecker() error {
	// The probe sends every internal key, and appends a path to the string, so
	// the upstream must be exactly `http://<loopback IP>:<port>`: a bare host
	// would probe another port than reverse_proxy, and a `?x` or `#x` suffix
	// would swallow the `/v1/models` path.
	u, err := url.Parse(g.Upstream)
	if err != nil || g.Upstream != "http://"+u.Host || u.Port() == "" || !net.ParseIP(u.Hostname()).IsLoopback() {
		return fmt.Errorf("cpa_gate: upstream must be a loopback HTTP origin")
	}
	state := &healthState{entries: map[string]entryHealth{}, done: make(chan struct{})}
	for _, e := range g.keys {
		state.entries[e.name] = entryHealth{Missing: len(e.models)}
	}
	ctx, cancel := context.WithCancel(context.Background())
	state.cancel = cancel
	healthRegistry.Lock()
	if _, exists := healthRegistry.states[g.Policy]; exists {
		healthRegistry.Unlock()
		cancel()
		return fmt.Errorf("cpa_gate: policy already registered")
	}
	healthRegistry.states[g.Policy] = state
	healthRegistry.Unlock()
	g.health = state
	go func() {
		defer close(state.done)
		g.checkOnce(ctx)
		ticker := time.NewTicker(60 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				g.checkOnce(ctx)
			}
		}
	}()
	return nil
}

func (g *Gate) stopChecker() {
	// Caddy calls Cleanup after a failed Provision, before startChecker set g.health.
	if g.health == nil {
		return
	}
	g.health.cancel()
	<-g.health.done
	healthRegistry.Lock()
	if healthRegistry.states[g.Policy] == g.health {
		delete(healthRegistry.states, g.Policy)
	}
	healthRegistry.Unlock()
	g.health = nil
}

// checkOnce asks CPA's OpenAI listing as each internal principal. It logs
// counts only. The policy model set remains in memory, never in health JSON.
func (g *Gate) checkOnce(ctx context.Context) {
	// A redirect must not carry an internal key to wherever Location points.
	client := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	for _, e := range g.keys {
		result := entryHealth{Missing: len(e.models)}
		if ids, ok := fetchListing(ctx, client, g.Upstream, e); ok {
			result.Missing = 0
			for model := range e.models {
				if !ids[model] {
					result.Missing++
				}
			}
			result.OK = result.Missing == 0
		}
		g.health.mu.Lock()
		g.health.entries[e.name] = result
		g.health.mu.Unlock()
		g.logger.Info("listing check", zap.Bool("ok", result.OK), zap.Int("missing", result.Missing))
	}
}

func fetchListing(ctx context.Context, client *http.Client, upstream string, e *entry) (map[string]bool, bool) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, upstream+"/v1/models", nil)
	if err != nil {
		return nil, false
	}
	req.Header.Set("Accept-Encoding", "identity")
	req.Header.Set("Authorization", "Bearer "+e.internal)
	resp, err := client.Do(req)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, false
	}
	wired, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes+1))
	if err != nil || int64(len(wired)) > maxBodyBytes {
		return nil, false
	}
	decoded, ok := decodeListing(wired, resp.Header)
	if !ok {
		return nil, false
	}
	result, ok := interpretListing(decoded, e)
	return result.ids, ok && result.openAI
}

// Health is served on a separately bound loopback site. It holds only the
// policy path; requests read current state from the gate's lifecycle registry.
type Health struct {
	Policy string `json:"policy"`
}

func (Health) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{ID: "http.handlers.cpa_gate_health", New: func() caddy.Module { return new(Health) }}
}

func parseHealthCaddyfile(h httpcaddyfile.Helper) (caddyhttp.MiddlewareHandler, error) {
	check := new(Health)
	h.Next()
	if !h.AllArgs(&check.Policy) {
		return nil, h.ArgErr()
	}
	if h.NextBlock(0) {
		return nil, h.Err("cpa_gate_health takes no block")
	}
	return check, nil
}

func (h *Health) ServeHTTP(w http.ResponseWriter, r *http.Request, _ caddyhttp.Handler) error {
	if r.Method != http.MethodGet || r.URL.Path != "/-/health" || r.URL.RawQuery != "" || r.URL.RawPath != "" {
		return writeHealthStatus(w, http.StatusNotFound)
	}
	for _, name := range headerCarriers {
		if len(r.Header.Values(name)) != 0 {
			return writeHealthStatus(w, http.StatusNotFound)
		}
	}
	healthRegistry.RLock()
	state := healthRegistry.states[h.Policy]
	healthRegistry.RUnlock()
	if state == nil {
		return writeHealthStatus(w, http.StatusServiceUnavailable)
	}
	state.mu.RLock()
	status := http.StatusOK
	for _, result := range state.entries {
		if !result.OK {
			status = http.StatusServiceUnavailable
		}
	}
	body, _ := json.Marshal(struct {
		Entries map[string]entryHealth `json:"entries"`
	}{Entries: state.entries})
	state.mu.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
	return nil
}

func writeHealthStatus(w http.ResponseWriter, status int) error {
	w.WriteHeader(status)
	return nil
}
