package gate

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"net/textproto"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig"
	_ "github.com/caddyserver/caddy/v2/modules/caddyhttp/reverseproxy"
)

// Caddy's reverse proxy panics with http.ErrAbortHandler when its response
// copy fails. Exercise the actual copy path, including an interrupted source.
func TestCaddyListingCopyFailuresRefuseWithoutUpstreamHeaders(t *testing.T) {
	listing := `{"object":"list","data":[{"id":"m"},{"id":"outside"}]}`
	var defaultMode atomic.Value
	defaultMode.Store("early-hints")
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Location", "/v1/models/outside")
		w.Header().Set("X-Upstream-Model", "outside")
		mode := r.Header.Get("X-Gate-Test")
		if mode == "" {
			mode = defaultMode.Load().(string)
		}
		switch mode {
		case "early-hints", "early-hints-error":
			w.Header().Set("Link", "</v1/models/outside>; rel=preload")
			w.WriteHeader(http.StatusEarlyHints)
			w.Header().Del("Link")
			if mode == "early-hints-error" {
				w.WriteHeader(http.StatusBadGateway)
			}
			_, _ = io.WriteString(w, listing)
		case "truncated":
			conn, rw, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			defer conn.Close()
			_, _ = fmt.Fprintf(rw, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nLocation: /v1/models/outside\r\nX-Upstream-Model: outside\r\n\r\n%s", len(listing)+100, listing)
			_ = rw.Flush()
		}
	}))
	defer upstream.Close()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := listener.Addr().String()
	_ = listener.Close()
	policy := writePolicy(t, validPolicy)
	site := fmt.Sprintf("{\n admin off\n}\nhttp://%s {\n @listing path /v1/models\n route {\n  cpa_gate * %s %s\n  reverse_proxy @listing %s\n }\n}\n", addr, policy, upstream.URL, strings.TrimPrefix(upstream.URL, "http://"))
	config, _, err := caddyconfig.GetAdapter("caddyfile").Adapt([]byte(site), nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := caddy.Load(config, true); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := caddy.Stop(); err != nil {
			t.Error(err)
		}
	}()
	client := &http.Client{Timeout: 10 * time.Second}
	for _, test := range []struct {
		name   string
		status int
	}{
		{"early-hints", http.StatusOK},
		{"early-hints-error", http.StatusNotFound},
		{"truncated", http.StatusNotFound},
	} {
		t.Run(test.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodGet, "http://"+addr+"/v1/models", nil)
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("Authorization", "Bearer "+allKey)
			req.Header.Set("X-Gate-Test", test.name)
			req = req.WithContext(httptrace.WithClientTrace(req.Context(), &httptrace.ClientTrace{
				Got1xxResponse: func(code int, header textproto.MIMEHeader) error {
					t.Errorf("%s: client received informational status %d with headers %v", test.name, code, header)
					return nil
				},
			}))
			resp, err := client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			body, err := io.ReadAll(resp.Body)
			if err != nil {
				t.Fatal(err)
			}
			if resp.StatusCode != test.status || resp.Header.Get("Link") != "" || resp.Header.Get("Location") != "" || resp.Header.Get("X-Upstream-Model") != "" {
				t.Errorf("%s: status %d, headers %v", test.name, resp.StatusCode, resp.Header)
			}
			if test.status == http.StatusOK {
				if !bytes.Contains(body, []byte(`"id":"m"`)) || bytes.Contains(body, []byte("outside")) {
					t.Errorf("filtered listing differs from the callable set: %s", body)
				}
			} else if len(body) != 0 {
				t.Errorf("%s refusal has body: %s", test.name, body)
			}
		})
	}
	// Health probes the same upstream as serving does, so it must see the
	// same 103, and then agree with the listing that serving accepted.
	var healthSaw103 bool
	ctx := httptrace.WithClientTrace(context.Background(), &httptrace.ClientTrace{
		Got1xxResponse: func(code int, header textproto.MIMEHeader) error {
			healthSaw103 = code == http.StatusEarlyHints && header.Get("Link") == "</v1/models/outside>; rel=preload"
			return nil
		},
	})
	g, _ := newGate(t)
	g.Upstream = upstream.URL
	g.health = &healthState{entries: map[string]entryHealth{}}
	g.checkOnce(ctx)
	if !healthSaw103 {
		t.Error("health probe did not receive the same 103 response as serving")
	}
	for _, result := range g.health.entries {
		if !result.OK || result.Missing != 0 {
			t.Errorf("103 then valid 200 was unhealthy: %+v", result)
		}
	}
	defaultMode.Store("early-hints-error")
	g.checkOnce(context.Background())
	for _, result := range g.health.entries {
		if result.OK || result.Missing != 1 {
			t.Errorf("103 then failing final status was healthy: %+v", result)
		}
	}
}
