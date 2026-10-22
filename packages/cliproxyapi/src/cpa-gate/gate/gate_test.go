package gate

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/caddyserver/caddy/v2/caddyconfig"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

// Every key below contains "secret", so one substring search proves that no
// log line and no error message carries any of them.
const (
	allKey       = "secret-client-all"
	allInternal  = "secret-internal-all"
	chatKey      = "secret-client-chat"
	chatInternal = "secret-internal-chat"
	unknownKey   = "secret-client-unknown"
)

const validPolicy = `{"entries":[
	{"name":"all","key":"` + allKey + `","internal":"` + allInternal + `","apis":["anthropic","chat","responses"],"models":["m"]},
	{"name":"chat","key":"` + chatKey + `","internal":"` + chatInternal + `","apis":["chat"],"models":["m"]}
]}`

func writePolicy(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "policy.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// newGate returns a gate on validPolicy whose log lands in the buffer.
func newGate(t *testing.T) (*Gate, *bytes.Buffer) {
	t.Helper()
	keys, err := loadPolicy(writePolicy(t, validPolicy))
	if err != nil {
		t.Fatal(err)
	}
	var log bytes.Buffer
	core := zapcore.NewCore(zapcore.NewJSONEncoder(zap.NewProductionEncoderConfig()), zapcore.AddSync(&log), zapcore.DebugLevel)
	t.Cleanup(func() {
		if strings.Contains(log.String(), "secret") {
			t.Errorf("the log carries a key:\n%s", log.String())
		}
	})
	return &Gate{keys: keys, logger: zap.New(core)}, &log
}

// serve runs one request through the gate, failing if it is forwarded.
func serve(t *testing.T, g *Gate, r *http.Request) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	next := caddyhttp.HandlerFunc(func(http.ResponseWriter, *http.Request) error {
		t.Errorf("%s %s was forwarded", r.Method, r.URL)
		return nil
	})
	if err := g.ServeHTTP(w, r, next); err != nil {
		t.Errorf("ServeHTTP returned %v; a refusal must not become a Caddy error log", err)
	}
	return w
}

// carriers sets the key in each of the five places CPA reads one.
var carriers = map[string]func(*http.Request, string){
	"authorization": func(r *http.Request, key string) { r.Header.Set("Authorization", "Bearer "+key) },
	"bearer case":   func(r *http.Request, key string) { r.Header.Set("Authorization", "bEaReR "+key) },
	"x-goog-api-key": func(r *http.Request, key string) {
		r.Header.Set("X-Goog-Api-Key", key)
	},
	"x-api-key":  func(r *http.Request, key string) { r.Header.Set("X-Api-Key", key) },
	"key":        func(r *http.Request, key string) { addQuery(r, "key", key) },
	"auth_token": func(r *http.Request, key string) { addQuery(r, "auth_token", key) },
}

func addQuery(r *http.Request, name, value string) {
	q := r.URL.Query()
	q.Add(name, value)
	r.URL.RawQuery = q.Encode()
}

func lastLine(log *bytes.Buffer) string {
	lines := strings.Split(strings.TrimSpace(log.String()), "\n")
	return lines[len(lines)-1]
}

// Every allowed route, through every carrier, reaches the end of the gate:
// the credential is rewritten to the one internal key and the route is held
// back for the check its class still needs.
func TestAllowedRoutesRewriteTheCredential(t *testing.T) {
	g, log := newGate(t)
	for target, rt := range routes {
		method, path, _ := strings.Cut(target, " ")
		for name, carry := range carriers {
			r := httptest.NewRequest(method, path, nil)
			for _, q := range rt.query {
				addQuery(r, q, "1")
			}
			carry(r, allKey)
			w := serve(t, g, r)
			if w.Code != http.StatusNotFound || w.Body.Len() != 0 {
				t.Errorf("%s via %s: got %d %q, want the empty 404", target, name, w.Code, w.Body)
			}
			if want := `"reason":"pending"`; !strings.Contains(lastLine(log), want) || !strings.Contains(lastLine(log), `"route":"`+rt.class+`"`) {
				t.Errorf("%s via %s: log %s, want %s for class %s", target, name, lastLine(log), want, rt.class)
			}
			if got := r.Header.Values("Authorization"); !slices.Equal(got, []string{"Bearer " + allInternal}) {
				t.Errorf("%s via %s: Authorization %q after the rewrite", target, name, got)
			}
			for _, h := range []string{"X-Api-Key", "X-Goog-Api-Key"} {
				if r.Header.Get(h) != "" {
					t.Errorf("%s via %s: %s survived the rewrite", target, name, h)
				}
			}
			q := r.URL.Query()
			if q.Has("key") || q.Has("auth_token") {
				t.Errorf("%s via %s: a query carrier survived the rewrite: %s", target, name, r.URL.RawQuery)
			}
			for _, k := range rt.query {
				if q.Get(k) != "1" {
					t.Errorf("%s via %s: the rewrite dropped the query key %s", target, name, k)
				}
			}
		}
	}
}

func TestRefusals(t *testing.T) {
	bearer := func(key string) func(*http.Request) {
		return func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+key) }
	}
	cases := []struct {
		name, method, target string
		set                  func(*http.Request)
		status               int
		reason               string
	}{
		// Authentication: one known key in exactly one carrier.
		{"no carrier", "POST", "/v1/messages", func(*http.Request) {}, 401, "key"},
		{"unknown key", "POST", "/v1/messages", bearer(unknownKey), 401, "key"},
		{"empty bearer", "POST", "/v1/messages", bearer(""), 401, "key"},
		{"two carriers", "POST", "/v1/messages", func(r *http.Request) {
			r.Header.Set("Authorization", "Bearer "+allKey)
			r.Header.Set("X-Api-Key", allKey)
		}, 401, "key"},
		{"header and query carriers", "POST", "/v1/messages?key=" + allKey, func(r *http.Request) {
			r.Header.Set("X-Goog-Api-Key", allKey)
		}, 401, "key"},
		{"repeated header", "POST", "/v1/messages", func(r *http.Request) {
			r.Header.Add("X-Api-Key", allKey)
			r.Header.Add("X-Api-Key", allKey)
		}, 401, "key"},
		{"repeated authorization", "POST", "/v1/messages", func(r *http.Request) {
			r.Header.Add("Authorization", "Bearer "+allKey)
			r.Header.Add("Authorization", "Bearer "+allKey)
		}, 401, "key"},
		{"repeated query carrier", "POST", "/v1/messages?key=" + allKey + "&key=" + allKey, func(*http.Request) {}, 401, "key"},
		{"basic scheme", "POST", "/v1/messages", func(r *http.Request) { r.Header.Set("Authorization", "Basic "+allKey) }, 401, "key"},
		{"no scheme", "POST", "/v1/messages", func(r *http.Request) { r.Header.Set("Authorization", allKey) }, 401, "key"},
		{"two spaces", "POST", "/v1/messages", func(r *http.Request) { r.Header.Set("Authorization", "Bearer  "+allKey) }, 401, "key"},
		{"unparsable query", "POST", "/v1/messages?%zz", bearer(allKey), 401, "query"},

		// Routes: exact method and path, no other escaping, admitted API.
		// cspell:ignore Fmodels Dessages
		{"double slash", "GET", "//v1/models", bearer(allKey), 404, "route"},
		{"trailing slash", "GET", "/v1/models/", bearer(allKey), 404, "route"},
		{"case", "GET", "/V1/models", bearer(allKey), 404, "route"},
		{"escaped slash", "GET", "/v1%2Fmodels", bearer(allKey), 404, "route"},
		{"escaped letter", "POST", "/v1/%6Dessages", bearer(allKey), 404, "route"},
		{"dot segments", "GET", "/v1/../v0/management", bearer(allKey), 404, "route"},
		{"management", "GET", "/v0/management", bearer(allKey), 404, "route"},
		{"images", "POST", "/v1/images/generations", bearer(allKey), 404, "route"},
		{"realtime", "GET", "/v1/realtime", bearer(allKey), 404, "route"},
		{"keep-alive", "GET", "/keep-alive", bearer(allKey), 404, "route"},
		{"root", "GET", "/", bearer(allKey), 404, "route"},
		{"model detail", "GET", "/v1/models/m", bearer(allKey), 404, "route"},
		{"wrong method", "GET", "/v1/messages", bearer(allKey), 404, "route"},
		{"api not admitted", "POST", "/v1/messages", bearer(chatKey), 404, "route"},

		// Query: only the route's own keys, once each.
		{"unlisted query key", "POST", "/v1/messages?foo=1", bearer(allKey), 404, "route"},
		{"another route's query key", "POST", "/v1/responses?beta=true", bearer(allKey), 404, "route"},
		{"repeated query key", "POST", "/v1/messages?beta=true&beta=false", bearer(allKey), 404, "route"},
	}

	g, log := newGate(t)
	// The pending refusal is the reference: a refused route must answer
	// exactly as an allowed route does today, and as CPA does for a route
	// it lacks.
	reference := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	reference.Header.Set("Authorization", "Bearer "+chatKey)
	want404 := serve(t, g, reference)
	want401 := map[string][]byte{}
	for _, c := range cases {
		r := httptest.NewRequest(c.method, c.target, nil)
		c.set(r)
		before := r.Header.Clone()
		w := serve(t, g, r)
		if w.Code != c.status {
			t.Errorf("%s: got %d, want %d", c.name, w.Code, c.status)
		}
		if want := `"reason":"` + c.reason + `"`; !strings.Contains(lastLine(log), want) {
			t.Errorf("%s: log %s, want %s", c.name, lastLine(log), want)
		}
		if !slices.Equal(r.Header.Values("Authorization"), before.Values("Authorization")) {
			t.Errorf("%s: a refused request was rewritten", c.name)
		}
		switch c.status {
		case 404:
			if !bytes.Equal(w.Body.Bytes(), want404.Body.Bytes()) || !headersEqual(w.Header(), want404.Header()) {
				t.Errorf("%s: the 404 differs from the pending 404", c.name)
			}
		case 401:
			want401[w.Body.String()+w.Header().Get("Content-Type")] = nil
		}
	}
	if len(want401) != 1 {
		t.Errorf("the 401s differ: %q", want401)
	}
}

func headersEqual(a, b http.Header) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if !slices.Equal(v, b[k]) {
			return false
		}
	}
	return true
}

// An upgrade survives only on the websocket routes, so reverse_proxy never
// switches another route to an opaque byte relay.
func TestUpgradeOnlyOnWebsocketRoutes(t *testing.T) {
	g, _ := newGate(t)
	for target, keep := range map[string]bool{"POST /v1/responses": false, "GET /v1/responses": true} {
		method, path, _ := strings.Cut(target, " ")
		r := httptest.NewRequest(method, path, nil)
		r.Header.Set("Authorization", "Bearer "+allKey)
		r.Header.Set("Connection", "Upgrade")
		r.Header.Set("Upgrade", "websocket")
		serve(t, g, r)
		if got := r.Header.Get("Upgrade") != "" && r.Header.Get("Connection") != ""; got != keep {
			t.Errorf("%s: upgrade kept %v, want %v", target, got, keep)
		}
	}
}

func TestLoadPolicy(t *testing.T) {
	keys, err := loadPolicy(writePolicy(t, validPolicy))
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 2 {
		t.Fatalf("got %d entries, want 2", len(keys))
	}

	single := func(fields string) string {
		return `{"entries":[{"name":"a",` + fields + `}]}`
	}
	cases := map[string]struct{ policy, want string }{
		"empty client key":   {single(`"key":"","internal":"secret-i","apis":["chat"],"models":["m"]`), "empty client key"},
		"empty internal key": {single(`"key":"secret-k","internal":"","apis":["chat"],"models":["m"]`), "empty internal key"},
		"no apis":            {single(`"key":"secret-k","internal":"secret-i","apis":[],"models":["m"]`), "no apis"},
		"unknown api":        {single(`"key":"secret-k","internal":"secret-i","apis":["gemini"],"models":["m"]`), `unknown api "gemini"`},
		"no models":          {single(`"key":"secret-k","internal":"secret-i","apis":["chat"],"models":[]`), "no models"},
		"unknown field":      {single(`"key":"secret-k","internal":"secret-i","apis":["chat"],"models":["m"],"hostedTools":{}`), `unknown field "hostedTools"`},
		"duplicate client key": {`{"entries":[
			{"name":"a","key":"secret-k","internal":"secret-i1","apis":["chat"],"models":["m"]},
			{"name":"b","key":"secret-k","internal":"secret-i2","apis":["chat"],"models":["m"]}]}`, `"a" and "b" share a client key`},
		"client key is an internal key": {`{"entries":[
			{"name":"a","key":"secret-k1","internal":"secret-k2","apis":["chat"],"models":["m"]},
			{"name":"b","key":"secret-k2","internal":"secret-i","apis":["chat"],"models":["m"]}]}`, `"b": client key equals the internal key of entry "a"`},
		"own internal key": {single(`"key":"secret-k","internal":"secret-k","apis":["chat"],"models":["m"]`), "client key equals the internal key"},
	}
	for name, c := range cases {
		_, err := loadPolicy(writePolicy(t, c.policy))
		switch {
		case err == nil:
			t.Errorf("%s: loaded", name)
		case !strings.Contains(err.Error(), c.want):
			t.Errorf("%s: %v, want %q", name, err, c.want)
		case strings.Contains(err.Error(), "secret"):
			t.Errorf("%s: the error carries a key: %v", name, err)
		}
	}
	if _, err := loadPolicy(filepath.Join(t.TempDir(), "absent.json")); err == nil {
		t.Error("an absent policy file loaded")
	}
}

// The directive goes through Caddy's own adapter, which strips a leading
// matcher token before the module's parser sees the arguments.
func TestCaddyfileDirective(t *testing.T) {
	adapt := func(directive string) (string, error) {
		site := ":8080 {\n\troute {\n\t\t" + directive + "\n\t}\n}\n"
		out, _, err := caddyconfig.GetAdapter("caddyfile").Adapt([]byte(site), nil)
		return string(out), err
	}
	out, err := adapt("cpa_gate * /run/policy.json")
	if err != nil || !strings.Contains(out, `"handler":"cpa_gate","policy":"/run/policy.json"`) {
		t.Errorf("got %s, %v", out, err)
	}
	for _, directive := range []string{
		"cpa_gate /run/policy.json", // the path is taken as a matcher
		"cpa_gate *",                // an empty `{$VAR}`
		"cpa_gate * /a /b",
		"cpa_gate * /a {\n\t\t\tx\n\t\t}",
	} {
		if out, err := adapt(directive); err == nil {
			t.Errorf("%q adapted: %s", directive, out)
		}
	}
}
