package gate

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"strconv"
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
		"anthropic": `{"data":[{"id":"outside"},{"id":"m"}],"first_id":"outside","has_more":false,"last_id":"m"}`,
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
	filtered, ok := filterListing([]byte(cases["anthropic"]), e)
	if !ok || !bytes.Contains(filtered, []byte(`"first_id":"m"`)) || !bytes.Contains(filtered, []byte(`"last_id":"m"`)) {
		t.Errorf("pagination IDs not recomputed: %s, %v", filtered, ok)
	}
}

// The checked-in row is the complete gpt-5.5 template from CPA 8.0.38's
// internal/registry/models/codex_client_models.json, kept under testdata as
// a compact one-row catalog. It includes CPA's real upgrade.model reference.
// For this catalog the callable set is the single row ID; adding a different
// allowed ID makes the subset precondition false before filtering.
func TestRecordedCodexTemplateListingEqualsCallableSet(t *testing.T) {
	raw, err := os.ReadFile("testdata/codex-client-model-gpt-5.5.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	root, _, ok := parseListing(raw)
	if !ok {
		t.Fatal("CPA template fixture did not parse")
	}
	rows, ok := root["models"].([]any)
	if !ok || len(rows) != 1 {
		t.Fatalf("CPA template fixture rows: %v", root["models"])
	}
	id, ok := listingID(rows[0].(map[string]any), "models")
	if !ok || id != "gpt-5.5" {
		t.Fatalf("CPA template fixture ID: %q, %v", id, ok)
	}
	e := &entry{models: map[string]bool{id: true}}
	filtered, ok := filterListing(raw, e)
	if !ok || strings.Contains(string(filtered), "gpt-6.1-sol") || !bytes.Contains(filtered, []byte(`"upgrade":null`)) {
		t.Fatalf("filtered CPA template: ok %v, leaked %v, upgrade null %v", ok, strings.Contains(string(filtered), "gpt-6.1-sol"), bytes.Contains(filtered, []byte(`"upgrade":null`)))
	}
	result, _, ok := parseListing(filtered)
	if !ok || len(result["models"].([]any)) != len(e.models) {
		t.Fatalf("filtered IDs differ from callable set: %s", filtered)
	}
	e.models["not-listed"] = true
	if len(result["models"].([]any)) == len(e.models) {
		t.Error("a callable model absent from the CPA listing passed the subset check")
	}
}

func TestListingRefusesUnrecognizedOrAmbiguousWireShapes(t *testing.T) {
	g, _ := newGate(t)
	e := g.keys[sha256.Sum256([]byte(allKey))]
	// cspell:ignore modél
	cases := map[string][]byte{
		"both envelopes": []byte(`{"data":[],"models":[]}`),
		"duplicate name": []byte(`{"data":[],"data":[{"id":"m"}]}`),
		"escaped name": []byte(`{"d\u0061ta":[{"id":"m"}]}`),
		"invalid utf8": append([]byte(`{"data":[{"id":"m","note":"`), 0xff, '"', '}', ']', '}'),
		"mixed codex gemini row": []byte(`{"models":[{"slug":"m","name":"models/outside"}]}`),
		"mismatched data identity": []byte(`{"data":[{"id":"m","name":"models/outside"}]}`),
		"non ascii name": []byte(`{"data":[{"id":"m","modél":"outside"}]}`),
		"paginated unseen rows": []byte(`{"data":[{"id":"m"}],"has_more":true}`),
		"trailing value": []byte(`{"data":[]} {"data":[{"id":"m"}]}`),
		"unknown envelope": []byte(`{"items":[{"id":"m"}]}`),
		"unknown row": []byte(`{"data":[{"slug":"m"}]}`),
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
	for _, body := range []string{`{"items":[{"id":"outside"}]}`, `{"data":[{"id":"m"},{"id":"m"}],"hidden_model":"outside"}`} {
		w := call(http.StatusOK, body, upstreamHeaders)
		if w.Code != http.StatusNotFound || w.Body.Len() != 0 || w.Header().Get("Location") != "" {
			t.Errorf("unparseable response leaked: %d %v %s", w.Code, w.Header(), w.Body)
		}
	}
	w = call(http.StatusFound, `outside`, upstreamHeaders)
	if w.Code != http.StatusNotFound || w.Header().Get("Location") != "" {
		t.Errorf("upstream redirect leaked: %d %v", w.Code, w.Header())
	}
	capture := &listingCapture{header: make(http.Header)}
	if _, err := capture.Write(bytes.Repeat([]byte{'x'}, int(maxBodyBytes)+1)); err == nil || capture.body.Len() != 0 {
		t.Error("oversized upstream write was buffered")
	}
}

func TestListingDecompressionIsBounded(t *testing.T) {
	var compressed bytes.Buffer
	w := gzip.NewWriter(&compressed)
	if _, err := w.Write(bytes.Repeat([]byte{'x'}, int(maxBodyBytes)+1)); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if _, ok := decodeListing(bytes.NewBuffer(compressed.Bytes()), http.Header{"Content-Encoding": {"gzip"}}); ok {
		t.Error("decoded listing exceeded the limit")
	}
}

func TestDetailRoutesHaveTheSameUniformRefusal(t *testing.T) {
	g, _ := newGate(t)
	g.keys[sha256.Sum256([]byte(allKey))].apis["gemini"] = true
	for _, target := range []string{"/v1/models/m", "/v1beta/models/m"} {
		r := httptest.NewRequest(http.MethodGet, target, nil)
		r.Header.Set("Authorization", "Bearer "+allKey)
		w := httptest.NewRecorder()
		if err := g.ServeHTTP(w, r, caddyhttp.HandlerFunc(func(out http.ResponseWriter, _ *http.Request) error {
			out.Header().Set("Content-Type", "application/json")
			body := `{"id":"m"}`
			if strings.HasPrefix(target, "/v1beta") {
				body = `{"name":"models/m"}`
			}
			_, _ = io.WriteString(out, body)
			return nil
		})); err != nil || w.Code != http.StatusOK {
			t.Errorf("%s: %d %s %v", target, w.Code, w.Body, err)
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
}
