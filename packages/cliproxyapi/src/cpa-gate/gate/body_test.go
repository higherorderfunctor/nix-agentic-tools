package gate

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
	"github.com/klauspost/compress/zstd"
	"github.com/tidwall/gjson"
)

func bodyEntry(t *testing.T) *entry {
	t.Helper()
	keys, err := loadPolicy(writePolicy(t, `{"entries":[{"name":"a","key":"secret-client","internal":"secret-internal","apis":["responses"],"models":["m"],"hostedTools":{"web_search":[]}}]}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range keys {
		return e
	}
	t.Fatal("no entry")
	return nil
}

func TestStrictBodyAndModelRules(t *testing.T) {
	// cspell:ignore modelſ ufeff
	e := bodyEntry(t)
	cases := []struct {
		name string
		body string
		pass bool
	}{
		{"simple", `{"model":"m"}`, true},
		{"all model names", `{"model":"m","fallbackModel":"m","other_model":null,"models":["m"],"nested":[{"MODEL":"m"}]}`, true},
		{"schema paths", `{"model":"m","tools":[{"type":"function","input_schema":{"properties":{"model":{"type":"string"}}},"parameters":{"model":{"type":"string"}}}],"text":{"format":{"schema":{"model":{"type":"string"}}}},"response_format":{"json_schema":{"schema":{"model":{"type":"string"}}}},"output_format":{"schema":{"model":{"type":"string"}}}}`, true},
		{"chat function schema", `{"model":"m","tools":[{"type":"function","function":{"name":"f","parameters":{"properties":{"model":{"type":"string"}}}}}]}`, true},
		{"client arguments", `{"model":"m","input":[{"type":"function_call","arguments":{"model":"other"}},{"type":"custom_tool_call","input":{"model":"other"}}],"messages":[{"content":[{"type":"tool_use","input":{"model":"other"}}]}]}`, true},
		{"hosted tool and call", `{"model":"m","tools":[{"type":"web_search"}],"input":[{"type":"web_search_call"},{"type":"web_search_call_output"}]}`, true},
		{"nested hosted tool", `{"model":"m","x":{"tools":[{"type":"web_search"}]}}`, true},
		{"array model outside set", `{"model":"m","models":["other"]}`, false},
		{"nested model outside set", `{"model":"m","fallbacks":[{"model":"other"}]}`, false},
		{"null model", `{"model":null}`, false},
		{"non-string model", `{"model":1}`, false},
		{"object models", `{"model":"m","models":{}}`, false},
		{"empty model array allowed", `{"model":"m","models":[]}`, true},
		{"hosted tool denied", `{"model":"m","tools":[{"type":"image_generation"}]}`, false},
		{"nested hosted tool denied", `{"model":"m","x":{"tools":[{"type":"image_generation"}]}}`, false},
		{"hosted tool implied by history denied", `{"model":"m","input":[{"type":"image_generation_call"}]}`, false},
		{"server tool input checked", `{"model":"m","messages":[{"content":[{"type":"server_tool_use","input":{"model":"other"}}]}]}`, false},
		{"top schema is directive", `{"model":"m","schema":{"model":"other"}}`, false},
		{"literal array marker is directive", `{"model":"m","tools":{"*":{"parameters":{"model":"other"}}}}`, false},
		{"literal array marker is not client arguments", `{"model":"m","input":{"*":{"type":"function_call","arguments":{"model":"other"}}}}`, false},
		{"literal array marker inside real schema", `{"model":"m","tools":[{"type":"function","parameters":{"properties":{"*":{"model":"other"}}}}]}`, true},
		{"nested schema is directive", `{"model":"m","x":{"text":{"format":{"schema":{"model":"other"}}}}}`, false},
		{"chat adjacent directive", `{"model":"m","tools":[{"type":"function","function":{"parameters":{"model":"other"},"other":{"model":"other"}}}]}`, false},
		{"nested chat parameters are directive", `{"model":"m","tools":[{"type":"function","function":{"other":{"parameters":{"model":"other"}}}}]}`, false},
		{"tool input is directive", `{"model":"m","tools":[{"type":"function","input":{"model":"other"}}]}`, false},
		{"duplicate model", `{"model":"m","model":"other"}`, false},
		{"duplicate in schema", `{"model":"m","tools":[{"type":"function","parameters":{"x":1,"x":2}}]}`, false},
		{"folded names in schema", `{"model":"m","tools":[{"type":"function","parameters":{"models":1,"modelſ":2}}]}`, false},
		{"case folded model", `{"model":"m","MODEL":"other"}`, false},
		{"escaped model name", `{"mo\u0064el":"m"}`, false},
		{"escaped unrelated name", `{"model":"m","\u0078":1}`, false},
		{"non-ASCII name", `{"model":"m","modelſ":"other"}`, false},
		{"escaped schema data name", `{"model":"m","tools":[{"type":"function","parameters":{"\u0078":1}}]}`, true},
		{"lone surrogate", `{"model":"m","x":"\ud800"}`, false},
		{"lone surrogate in schema", `{"model":"m","tools":[{"type":"function","parameters":{"x":"\ud800"}}]}`, false},
		{"trailing object", `{"model":"m"}{"model":"other"}`, false},
		{"leading BOM", "\ufeff" + `{"model":"m"}`, false},
		{"invalid utf8 in schema", `{"model":"m","tools":[{"type":"function","parameters":{"x":"` + string([]byte{0xff}) + `"}}]}`, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := validBody([]byte(c.body), e)
			if got != c.pass {
				t.Errorf("accepted %v, want %v", got, c.pass)
			}
			if got {
				// The same gjson call CPA 8.0.38 makes must see our set member.
				model := gjson.GetBytes([]byte(c.body), "model")
				if model.Type != gjson.String || model.String() != "m" {
					t.Errorf("CPA would read %q", model.String())
				}
			}
		})
	}
	emptyHosted := *e
	emptyHosted.hostedTools = map[string]bool{}
	if validBody([]byte(`{"model":"m","tools":[{"type":"web_search"}]}`), &emptyHosted) {
		t.Error("hosted tool passed with empty policy")
	}
	if validBody([]byte(`{"model":"m","input":[{"type":"web_search_call"}]}`), &emptyHosted) {
		t.Error("hosted history call passed with empty policy")
	}
}

func TestBodyDepthBoundary(t *testing.T) {
	e := bodyEntry(t)
	for _, c := range []struct {
		depth int
		pass  bool
	}{{127, true}, {128, false}} {
		body := []byte(`{"model":"m","x":` + strings.Repeat("[", c.depth) + `0` + strings.Repeat("]", c.depth) + `}`)
		if got := validBody(body, e); got != c.pass {
			t.Errorf("%d array levels: accepted %v, want %v", c.depth, got, c.pass)
		}
	}
}

// Trailing/both-end input whitespace and raw policy-granted declarations pass
// the old guards. Leading-only input whitespace and empty-policy malformed
// declarations are existing rejection baselines.
var nonCanonicalHostedTypes = []struct {
	name, field, kind string
}{
	{"input both ASCII", "input", " web_search_call "},
	{"input both Unicode", "input", "\u00a0web_search_call\u00a0"},
	{"input leading ASCII", "input", " web_search_call"},
	{"input leading Unicode", "input", "\u00a0web_search_call"},
	{"input trailing ASCII", "input", "web_search_call "},
	{"input trailing Unicode", "input", "web_search_call\u00a0"},
	{"input trailing hosted output", "input", "web_search_call_output "},
	{"input trailing other hosted call", "input", "image_generation_call "},
	{"tool both ASCII", "tools", " web_search "},
	{"tool both Unicode", "tools", "\u00a0web_search\u00a0"},
	{"tool case", "tools", "WEB_SEARCH_20250305"},
	{"tool leading ASCII", "tools", " web_search"},
	{"tool leading Unicode", "tools", "\u00a0web_search"},
	{"tool trailing ASCII", "tools", "web_search "},
	{"tool trailing Unicode", "tools", "web_search\u00a0"},
}

func hostedTypeBody(field, kind string) string {
	encoded, _ := json.Marshal(kind) // A string cannot fail JSON encoding.
	return `{"model":"m","` + field + `":[{"type":` + string(encoded) + `}]}`
}

func TestHostedToolTypeCanonicalSpellings(t *testing.T) {
	for _, c := range nonCanonicalHostedTypes {
		t.Run(c.name, func(t *testing.T) {
			// The policy loader permits raw spellings: types must be canonical even
			// when the exact malformed declaration has an explicit policy grant.
			encoded, _ := json.Marshal(c.kind)
			keys, err := loadPolicy(writePolicy(t, `{"entries":[{"name":"a","key":"secret-client","internal":"secret-internal","apis":["responses"],"models":["m"],"hostedTools":{`+string(encoded)+`:[],"web_search":[]}}]}`))
			if err != nil {
				t.Fatal(err)
			}
			for _, e := range keys {
				for _, allow := range []bool{false, true} {
					checked := *e
					if !allow {
						checked.hostedTools = map[string]bool{}
					}
					if validBody([]byte(hostedTypeBody(c.field, c.kind)), &checked) {
						t.Errorf("non-canonical type accepted with raw policy grants %v", allow)
					}
				}
			}
		})
	}
}

// Canonical allow/deny and client-owned data are existing behavior baselines.
func TestCanonicalHostedToolTypes(t *testing.T) {
	for _, c := range []struct{ field, kind, tool string }{
		{"input", "image_generation_call", "image_generation"},
		{"input", "web_search_call", "web_search"},
		{"input", "web_search_call_output", "web_search"},
		{"tools", "web_search", "web_search"},
		{"tools", "web_search_20250305", "web_search_20250305"},
		{"tools", "web_search_preview", "web_search_preview"},
		{"tools", "web_search_preview_2025_03_11", "web_search_preview_2025_03_11"},
	} {
		t.Run(c.field+"/"+c.kind, func(t *testing.T) {
			for _, allow := range []bool{false, true} {
				e := bodyEntry(t)
				e.hostedTools = map[string]bool{}
				if allow {
					e.hostedTools[c.tool] = true
				}
				if got := validBody([]byte(hostedTypeBody(c.field, c.kind)), e); got != allow {
					t.Errorf("canonical type accepted %v with grant %v", got, allow)
				}
			}
		})
	}
	for _, body := range []string{
		`{"model":"m","tools":[{"type":"function"},{"type":"custom"}]}`,
		`{"model":"m","input":[{"type":"function_call"},{"type":"function_call_output"},{"type":"custom_tool_call"},{"type":"custom_tool_call_output"}]}`,
		`{"model":"m","tools":[{"type":"function","parameters":{"type":" WEB_SEARCH "}}],"input":[{"type":"function_call","arguments":{"type":" web_search_call "}}]}`,
	} {
		if !validBody([]byte(body), bodyEntry(t)) {
			t.Error("canonical client tools or client-owned type data refused")
		}
	}
}

func TestNonCanonicalHostedTypesRefusedBeforeHTTPForwarding(t *testing.T) {
	for _, c := range nonCanonicalHostedTypes {
		t.Run(c.name, func(t *testing.T) {
			g, log := newGate(t)
			for _, e := range g.keys {
				e.hostedTools[c.kind] = true
				e.hostedTools["web_search"] = true
			}
			r := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(hostedTypeBody(c.field, c.kind)))
			r.Header.Set("Authorization", "Bearer "+responsesKey)
			r.Header.Set("Content-Type", "application/json")
			w := serve(t, g, r)
			if w.Code != http.StatusNotFound || w.Body.Len() != 0 || !strings.Contains(lastLine(log), `"reason":"body"`) {
				t.Errorf("nonuniform refusal: %d %q %s", w.Code, w.Body, lastLine(log))
			}
			if strings.Contains(log.String(), `"m"`) || strings.Contains(log.String(), c.kind) {
				t.Error("refusal log carries model or tool data")
			}
		})
	}
}

func TestWideObject(t *testing.T) {
	var body strings.Builder
	body.WriteString(`{"model":"m"`)
	for i := 0; i < 50000; i++ {
		body.WriteString(`,"field`)
		body.WriteString(strconv.Itoa(i))
		body.WriteString(`":0`)
	}
	body.WriteByte('}')
	if !validBody([]byte(body.String()), bodyEntry(t)) {
		t.Fatal("wide object with unique names was refused")
	}
}

func FuzzStrictBodyAgreesWithCPA(f *testing.F) {
	e := &entry{models: map[string]bool{"m": true}, hostedTools: map[string]bool{}}
	for _, seed := range []string{`{"model":"m"}`, `{"model":"m","nested":[{"model":"m"}]}`, `{"model":"m","MODEL":"other"}`, `{"mo\u0064el":"m"}`} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, body []byte) {
		if !utf8.Valid(body) || !gjson.ValidBytes(body) {
			return
		}
		s := strictScanner{body: body, text: string(body)}
		if !s.value(nil, false, 0) || !s.done() || len(body) == 0 || body[firstNonSpace(body)] != '{' || !s.hasModel || !checkNode(gjson.ParseBytes(body), nil, e) {
			return
		}
		var standard struct{ Model string `json:"model"` }
		if err := json.Unmarshal(body, &standard); err != nil {
			t.Fatal(err)
		}
		got := gjson.GetBytes(body, "model")
		if got.Type != gjson.String || got.String() != s.model || standard.Model != s.model {
			t.Fatalf("strict scanner %q, CPA %q, Go decoder %q", s.model, got.String(), standard.Model)
		}
	})
}

func TestBodyForwardingAndRefusals(t *testing.T) {
	g, log := newGate(t)
	model := []byte(`{"model":"m"}`)
	underLimit := []byte(`{"model":"m","pad":"` + strings.Repeat("x", 1<<20) + `"}`)
	overLimit := []byte(`{"model":"m","pad":"` + strings.Repeat("x", int(maxBodyBytes)) + `"}`)
	encode := func(kind string, body []byte) []byte {
		var out bytes.Buffer
		switch kind {
		case "gzip":
			writer := gzip.NewWriter(&out)
			if _, err := writer.Write(body); err != nil {
				t.Fatal(err)
			}
			if err := writer.Close(); err != nil {
				t.Fatal(err)
			}
		case "zstd":
			writer, err := zstd.NewWriter(&out)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := writer.Write(body); err != nil {
				t.Fatal(err)
			}
			if err := writer.Close(); err != nil {
				t.Fatal(err)
			}
		default:
			return body
		}
		return out.Bytes()
	}
	skippable := func(padding int, frame []byte) []byte {
		wire := make([]byte, 8+padding, 8+padding+len(frame))
		copy(wire, []byte{0x50, 0x2a, 0x4d, 0x18})
		binary.LittleEndian.PutUint32(wire[4:8], uint32(padding))
		return append(wire, frame...)
	}
	cases := []struct {
		name, encoding, contentType string
		body, want                  []byte
		pass                        bool
		repeatType, repeatEncoding  bool
	}{
		{name: "identity", contentType: "application/json", body: model, want: model, pass: true},
		{name: "identity explicit", encoding: "identity", contentType: "application/json; charset=utf-8", body: model, want: model, pass: true},
		{name: "gzip", encoding: "gzip", contentType: "application/json", body: encode("gzip", model), want: model, pass: true},
		{name: "zstd", encoding: "zstd", contentType: "application/json", body: encode("zstd", model), want: model, pass: true},
		{name: "gzip under limit", encoding: "gzip", contentType: "application/json", body: encode("gzip", underLimit), want: underLimit, pass: true},
		{name: "zstd under limit", encoding: "zstd", contentType: "application/json", body: encode("zstd", underLimit), want: underLimit, pass: true},
		{name: "zstd skippable under limit", encoding: "zstd", contentType: "application/json", body: skippable(16, encode("zstd", model)), want: model, pass: true},
		{name: "wrong model", contentType: "application/json", body: []byte(`{"model":"other"}`)},
		{name: "wrong type", contentType: "text/plain", body: model},
		{name: "wrong charset", contentType: "application/json; charset=utf-16", body: model},
		{name: "missing type", body: model},
		{name: "repeated type", contentType: "application/json", body: model, repeatType: true},
		{name: "unsupported encoding", encoding: "br", contentType: "application/json", body: model},
		{name: "repeated encoding", encoding: "gzip", contentType: "application/json", body: encode("gzip", model), repeatEncoding: true},
		{name: "bad gzip", encoding: "gzip", contentType: "application/json", body: model},
		{name: "bad zstd", encoding: "zstd", contentType: "application/json", body: model},
		{name: "gzip decoded limit", encoding: "gzip", contentType: "application/json", body: encode("gzip", overLimit)},
		{name: "zstd decoded limit", encoding: "zstd", contentType: "application/json", body: encode("zstd", overLimit)},
		{name: "zstd wire limit", encoding: "zstd", contentType: "application/json", body: skippable(int(maxBodyBytes), encode("zstd", model))},
	}
	var refusedBody []byte
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest("POST", "/v1/responses", bytes.NewReader(c.body))
			r.Header.Set("Authorization", "Bearer "+allKey)
			if c.contentType != "" {
				r.Header.Set("Content-Type", c.contentType)
			}
			if c.encoding != "" {
				r.Header.Set("Content-Encoding", c.encoding)
			}
			if c.repeatType {
				r.Header.Add("Content-Type", "application/json")
			}
			if c.repeatEncoding {
				r.Header.Add("Content-Encoding", c.encoding)
			}
			w := httptest.NewRecorder()
			forwarded := false
			next := caddyhttp.HandlerFunc(func(_ http.ResponseWriter, got *http.Request) error {
				forwarded = true
				actual, err := io.ReadAll(got.Body)
				if err != nil || !bytes.Equal(actual, c.want) || got.ContentLength != int64(len(c.want)) || got.Header.Get("Content-Length") != strconv.Itoa(len(c.want)) || got.Header.Get("Content-Encoding") != "" {
					t.Errorf("forwarded bytes or headers differ: %q, %v, %d, %q, %q", actual, err, got.ContentLength, got.Header.Get("Content-Length"), got.Header.Get("Content-Encoding"))
				}
				return nil
			})
			if err := g.ServeHTTP(w, r, next); err != nil {
				t.Fatal(err)
			}
			if forwarded != c.pass {
				t.Errorf("forwarded %v, want %v", forwarded, c.pass)
			}
			if !c.pass {
				if w.Code != http.StatusNotFound || !strings.Contains(lastLine(log), `"reason":"body"`) {
					t.Errorf("refusal: %d %s", w.Code, lastLine(log))
				}
				if refusedBody == nil {
					refusedBody = append([]byte(nil), w.Body.Bytes()...)
				}
				if !bytes.Equal(w.Body.Bytes(), refusedBody) {
					t.Errorf("refusal body varies: %q", w.Body.Bytes())
				}
			}
		})
	}
}

func TestHostedToolPolicy(t *testing.T) {
	e := bodyEntry(t)
	if !e.hostedTools["web_search"] || !e.models["m"] {
		t.Fatal("policy lost the hosted tool or model")
	}
	for _, body := range []string{
		`{"entries":[{"name":"a","key":"secret-k","internal":"secret-i","apis":["responses"],"models":["m"],"hostedTools":{"web_search":["other"]}}]}`,
		`{"entries":[{"name":"a","key":"secret-k","internal":"secret-i","apis":["responses"],"models":["m"],"hostedTools":{"function":[]}}]}`,
	} {
		if _, err := loadPolicy(writePolicy(t, body)); err == nil {
			t.Errorf("invalid policy loaded: %s", body)
		}
	}
}
