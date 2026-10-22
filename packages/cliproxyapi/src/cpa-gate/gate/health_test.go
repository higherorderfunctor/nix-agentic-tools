package gate

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthChecksEachInternalListingAndKeepsModelsPrivate(t *testing.T) {
	g, log := newGate(t)
	modelsByKey := map[string]string{}
	for _, e := range g.keys {
		model := e.name + "-private-model"
		e.models = map[string]bool{model: true}
		modelsByKey["Bearer "+e.internal] = model
	}
	mode := "ordinary"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/v1/models" || r.Header.Get("Accept-Encoding") != "identity" || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer secret-internal-") {
			t.Errorf("checker request shape: %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		row := map[string]any{"id": modelsByKey[r.Header.Get("Authorization")]}
		root := map[string]any{"object": "list", "data": []any{row}}
		switch mode {
		case "empty":
			root["data"] = []any{}
		case "failed":
			w.WriteHeader(http.StatusBadGateway)
		case "outside":
			row["model"] = "outside"
		}
		body, _ := json.Marshal(root)
		_, _ = w.Write(body)
	}))
	defer upstream.Close()
	g.Upstream = upstream.URL
	g.health = &healthState{entries: map[string]entryHealth{}}
	g.checkOnce(context.Background())
	for _, result := range g.health.entries {
		if !result.OK || result.Missing != 0 {
			t.Errorf("listed callable model is unhealthy: %+v", result)
		}
	}
	path := writePolicy(t, validPolicy)
	healthRegistry.Lock()
	healthRegistry.states[path] = g.health
	healthRegistry.Unlock()
	defer func() {
		healthRegistry.Lock()
		delete(healthRegistry.states, path)
		healthRegistry.Unlock()
	}()
	h := &Health{Policy: path}
	r := httptest.NewRequest(http.MethodGet, "/-/health", nil)
	w := httptest.NewRecorder()
	if err := h.ServeHTTP(w, r, nil); err != nil || w.Code != http.StatusOK {
		t.Errorf("listed callable set is unhealthy: %d %s %v", w.Code, w.Body, err)
	}
	// Health shares serving's validation: a row serving would drop is missing
	// ("outside"), and a listing serving would refuse reports nothing ("failed").
	for _, mode = range []string{"empty", "outside", "failed"} {
		g.checkOnce(context.Background())
		for _, result := range g.health.entries {
			if result.OK || result.Missing != 1 {
				t.Errorf("%s listing reported healthy: %+v", mode, result)
			}
		}
	}
	if strings.Contains(log.String(), "private-model") || strings.Contains(log.String(), "secret") {
		t.Errorf("checker log exposed model or key: %s", log)
	}

	w = httptest.NewRecorder()
	if err := h.ServeHTTP(w, r, nil); err != nil || w.Code != http.StatusServiceUnavailable || strings.Contains(w.Body.String(), "private-model") || strings.Contains(w.Body.String(), "secret") {
		t.Errorf("health leaked or passed: %d %s %v", w.Code, w.Body, err)
	}
	var body struct{ Entries map[string]entryHealth `json:"entries"` }
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || len(body.Entries) != len(g.keys) {
		t.Errorf("health entries: %+v, %v", body, err)
	}
	r.Header.Set("Authorization", "Bearer "+allKey)
	w = httptest.NewRecorder()
	if err := h.ServeHTTP(w, r, nil); err != nil || w.Code != http.StatusNotFound || w.Body.Len() != 0 {
		t.Errorf("key reached health: %d %s %v", w.Code, w.Body, err)
	}
}

func TestHealthRegistryLifecycle(t *testing.T) {
	g, _ := newGate(t)
	g.Policy = writePolicy(t, validPolicy)
	g.Upstream = "http://127.0.0.1:1"
	if err := g.startChecker(); err != nil {
		t.Fatal(err)
	}
	healthRegistry.RLock()
	registered := healthRegistry.states[g.Policy] == g.health
	healthRegistry.RUnlock()
	if !registered {
		t.Error("checker did not register initial failed state")
	}
	for _, result := range g.health.entries {
		if result.OK || result.Missing != 1 {
			t.Errorf("checker started healthy: %+v", result)
		}
	}
	g.stopChecker()
	healthRegistry.RLock()
	_, registered = healthRegistry.states[g.Policy]
	healthRegistry.RUnlock()
	if registered {
		t.Error("cleanup left a registered health state")
	}
	for _, upstream := range []string{"https://127.0.0.1:1", "http://example.com:1", "http://127.0.0.1:1/path"} {
		g.Upstream = upstream
		if err := g.startChecker(); err == nil {
			g.stopChecker()
			t.Errorf("accepted checker origin %s", upstream)
		}
	}
}
