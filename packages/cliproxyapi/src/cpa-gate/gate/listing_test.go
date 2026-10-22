package gate

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
)

// These envelopes come from CPA 8.0.38's OpenAI handler,
// internal/client/claude/models/models.go:BuildResponse,
// internal/client/grokbuild/grokbuild.go:BuildResponse,
// internal/client/codex/models/models.go:BuildResponse and
// internal/api/server_routes.go:handleHomeGeminiModels. Their model IDs are
// synthetic; the wire field names and envelopes are from those producers.
func TestListingShapesFilterToTheCallableSet(t *testing.T) {
	g, _ := newGate(t)
	e := g.keys[sha256.Sum256([]byte(allKey))]
	cases := map[string]string{
		"anthropic": `{"data":[{"id":"outside"},{"id":"m"},{"id":"outsider"}],"first_id":"outside","has_more":false,"last_id":"outsider"}`,
		"codex": `{"models":[{"slug":"m","display_name":"M","upgrade":{"model":"outside","migration_markdown":"switch to outside"}},{"slug":"outside"}]}`,
		"gemini": `{"models":[{"name":"models/m","displayName":"M"},{"name":"models/outside"}]}`,
		"grok": `{"object":"list","data":[{"id":"m","model":"m","name":"M","api_backend":"openai","supported_in_api":true},{"id":"outside","model":"outside"}]}`,
		"openai": `{"object":"list","data":[{"id":"m","object":"model"},{"id":"outside","object":"model"}]}`,
	}
	for name, raw := range cases {
		filtered, ok := filterListing([]byte(raw), e)
		if !ok || bytes.Contains(filtered, []byte("outside")) {
			t.Errorf("%s: filtered %s, ok %v", name, filtered, ok)
			continue
		}
		var root map[string]any
		if err := json.Unmarshal(filtered, &root); err != nil {
			t.Fatal(err)
		}
		field := "data"
		if _, found := root["models"]; found {
			field = "models"
		}
		rows, ok := root[field].([]any)
		if !ok || len(rows) != 1 {
			t.Errorf("%s: kept %v", name, root[field])
		}
		if name == "codex" && !bytes.Contains(filtered, []byte(`"upgrade":null`)) {
			t.Errorf("%s: outside upgrade not null: %s", name, filtered)
		}
	}
}

// The checked-in row is the complete gpt-5.5 template from CPA 8.0.38's
// internal/registry/models/codex_client_models.json, with CPA's real
// upgrade.model reference. The synthetic shapes above cannot show that CPA's
// own bytes pass the strict scanner.
func TestRecordedCodexTemplateSurvivesFiltering(t *testing.T) {
	raw, err := os.ReadFile("testdata/codex-client-model-gpt-5.5.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	interpreted, ok := interpretListing(raw, &entry{models: map[string]bool{"gpt-5.5": true}})
	if !ok || !interpreted.ids["gpt-5.5"] || len(interpreted.ids) != 1 || bytes.Contains(interpreted.body, []byte("gpt-6.1-sol")) || !bytes.Contains(interpreted.body, []byte(`"upgrade":null`)) {
		t.Fatalf("filtered CPA template: ok %v, ids %v, body %s", ok, interpreted.ids, interpreted.body)
	}
}

func TestListingRefusesUnrecognizedOrAmbiguousWireShapes(t *testing.T) {
	g, _ := newGate(t)
	e := g.keys[sha256.Sum256([]byte(allKey))]
	cases := map[string][]byte{
		"both envelopes": []byte(`{"data":[],"models":[]}`),
		"duplicate name": []byte(`{"data":[],"data":[{"id":"m"}]}`),
		"escaped name": []byte(`{"d\u0061ta":[{"id":"m"}]}`),
		"invalid utf8": append([]byte(`{"data":[{"id":"m","note":"`), 0xff, '"', '}', ']', '}'),
		"mixed codex id row": []byte(`{"models":[{"slug":"m","id":"outside"}]}`),
		"mixed codex gemini row": []byte(`{"models":[{"slug":"m","name":"models/outside"}]}`),
		"mismatched data identity": []byte(`{"data":[{"id":"m","name":"models/outside"}]}`),
		"non-array rows": []byte(`{"data":{}}`),
		"paginated unseen rows": []byte(`{"data":[{"id":"m"}],"has_more":true}`),
		"trailing value": []byte(`{"data":[]} {"data":[{"id":"m"}]}`),
		"data row with slug": []byte(`{"data":[{"id":"m","slug":"outside"}]}`),
	}
	for name, raw := range cases {
		if result, ok := filterListing(raw, e); ok {
			t.Errorf("%s accepted: %s", name, result)
		}
	}
}

func TestListingHandlerBoundsAndCleansTheResponse(t *testing.T) {
	g, _ := newGate(t)
	call := func(status int, body string, headers http.Header) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
		r.Header.Set("Authorization", "Bearer "+allKey)
		r.Header.Set("Accept-Encoding", "gzip")
		w := httptest.NewRecorder()
		next := caddyhttp.HandlerFunc(func(out http.ResponseWriter, req *http.Request) error {
			if req.Header.Get("Accept-Encoding") != "identity" {
				t.Error("listing did not force identity upstream")
			}
			for name, values := range headers {
				out.Header()[name] = values
			}
			out.WriteHeader(status)
			_, _ = io.WriteString(out, body)
			return nil
		})
		if err := g.ServeHTTP(w, r, next); err != nil {
			t.Fatal(err)
		}
		return w
	}
	upstreamHeaders := http.Header{"Content-Type": {"application/json"}, "Location": {"/v1/models/outside"}, "Trailer": {"X-Outside"}}
	w := call(http.StatusOK, `{"object":"list","data":[{"id":"m"},{"id":"outside"}]}`, upstreamHeaders)
	if w.Code != http.StatusOK || strings.Contains(w.Body.String(), "outside") || w.Header().Get("Location") != "" || w.Header().Get("Trailer") != "" || w.Header().Get("Content-Length") != strconv.Itoa(w.Body.Len()) {
		t.Errorf("filtered response: %d %v %s", w.Code, w.Header(), w.Body)
	}
	w = call(http.StatusOK, `{"items":[{"id":"outside"}]}`, upstreamHeaders)
	if w.Code != http.StatusNotFound || w.Body.Len() != 0 || w.Header().Get("Location") != "" {
		t.Errorf("unparseable response leaked: %d %v %s", w.Code, w.Header(), w.Body)
	}
	capture := &listingCapture{header: make(http.Header)}
	if _, err := capture.Write(bytes.Repeat([]byte{'x'}, int(maxBodyBytes)+1)); err == nil || capture.body.Len() != 0 {
		t.Error("oversized upstream write was buffered")
	}
	r := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	r.Header.Set("Authorization", "Bearer "+allKey)
	w = httptest.NewRecorder()
	if err := g.ServeHTTP(w, r, caddyhttp.HandlerFunc(func(out http.ResponseWriter, _ *http.Request) error {
		_, _ = io.WriteString(out, `{"object":"list","data":[{"id":"m"}]}`)
		_, _ = out.Write(bytes.Repeat([]byte{' '}, int(maxBodyBytes)+1)) // caller ignores the write error
		return nil
	})); err != nil || w.Code != http.StatusNotFound || w.Body.Len() != 0 {
		t.Errorf("ignored overflow accepted a valid prefix: %d %s %v", w.Code, w.Body, err)
	}
}

func TestDetailRoutesHaveTheSameUniformRefusal(t *testing.T) {
	g, _ := newGate(t)
	e := g.keys[sha256.Sum256([]byte(allKey))]
	e.apis["gemini"] = true
	for _, c := range []struct{ target, body string }{
		{"/v1/models/m", `{"id":"m"}`},
		{"/v1beta/models/m", `{"name":"models/m"}`},
	} {
		r := httptest.NewRequest(http.MethodGet, c.target, nil)
		r.Header.Set("Authorization", "Bearer "+allKey)
		w := httptest.NewRecorder()
		if err := g.ServeHTTP(w, r, caddyhttp.HandlerFunc(func(out http.ResponseWriter, _ *http.Request) error {
			out.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(out, c.body)
			return nil
		})); err != nil || w.Code != http.StatusOK {
			t.Errorf("%s %s: %d %s %v", c.target, c.body, w.Code, w.Body, err)
		}
	}
	for _, target := range []string{"/v1/models/outside", "/v1beta/models/outside"} {
		r := httptest.NewRequest(http.MethodGet, target, nil)
		r.Header.Set("Authorization", "Bearer "+allKey)
		w := serve(t, g, r)
		if w.Code != http.StatusNotFound || w.Body.Len() != 0 {
			t.Errorf("%s: %d %s", target, w.Code, w.Body)
		}
	}
	// A callable model that is not the one requested must not stand in for it.
	e.models["n"] = true
	if result, ok := filterDetail([]byte(`{"id":"n"}`), e, "/v1/models/m"); ok {
		t.Errorf("detail for another model accepted: %s", result)
	}
}
