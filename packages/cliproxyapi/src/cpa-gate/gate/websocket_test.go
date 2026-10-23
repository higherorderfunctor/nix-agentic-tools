package gate

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
	"github.com/gorilla/websocket"
)

// Hide Hijacker exactly as a Caddy middleware wrapper can.
type wrappedWriter struct{ http.ResponseWriter }

func (w wrappedWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func websocketFixture(t *testing.T, hostedTypes ...string) (string, <-chan string) {
	t.Helper()
	received := make(chan string, 20)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+responsesInternal || r.URL.RawQuery != "" || r.Header.Get("Sec-WebSocket-Extensions") != "" || r.Header.Get("X-Client") != "retained" {
			t.Errorf("upstream credential, query, compression or client header differs")
		}
		conn, err := (&websocket.Upgrader{Subprotocols: []string{"responses"}}).Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		defer func() { received <- "closed" }()
		if r.Header.Get("X-Controls") == "close" {
			_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseGoingAway, "upstream-done"), time.Now().Add(time.Second))
			return
		}
		if r.Header.Get("X-Controls") == "yes" {
			_ = conn.WriteControl(websocket.PingMessage, []byte("server-ping"), time.Now().Add(time.Second))
			_ = conn.WriteControl(websocket.PongMessage, []byte("server-pong"), time.Now().Add(time.Second))
		}
		conn.SetPingHandler(func(payload string) error {
			return conn.WriteControl(websocket.PongMessage, []byte(payload), time.Now().Add(time.Second))
		})
		conn.SetPongHandler(func(payload string) error { received <- "pong:" + payload; return nil })
		conn.SetCloseHandler(func(code int, text string) error { received <- fmt.Sprintf("close:%d:%s", code, text); return nil })
		for {
			kind, body, err := conn.ReadMessage()
			if err != nil {
				return
			}
			received <- string(body)
			// Responses may contain arbitrary models and binary output: never inspect.
			if conn.WriteMessage(kind, body) != nil || conn.WriteMessage(websocket.BinaryMessage, []byte("outside-model")) != nil {
				return
			}
		}
	}))
	t.Cleanup(upstream.Close)
	g, _ := newGate(t)
	g.Upstream = upstream.URL
	// Even a literal whitespace policy entry must not create CPA's trimmed alias.
	for _, e := range g.keys {
		e.models[" m "] = true
		for _, kind := range hostedTypes {
			e.hostedTools[kind] = true
		}
	}
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next := caddyhttp.HandlerFunc(func(http.ResponseWriter, *http.Request) error { t.Error("websocket reached reverse proxy"); return nil })
		if err := g.ServeHTTP(wrappedWriter{w}, r, next); err != nil {
			t.Error(err)
		}
	}))
	t.Cleanup(front.Close)
	return "ws" + strings.TrimPrefix(front.URL, "http"), received
}

func dialWebsocket(t *testing.T, target string, controls ...string) *websocket.Conn {
	t.Helper()
	dialer := websocket.Dialer{EnableCompression: true, HandshakeTimeout: 5 * time.Second, Subprotocols: []string{"responses"}}
	if len(controls) > 0 {
		dialer.WriteBufferSize = 16
	}
	conn, response, err := dialer.Dial(target, http.Header{"X-Client": {"retained"}, "X-Controls": controls})
	if err != nil {
		t.Fatal(err)
	}
	if response.Header.Get("Sec-WebSocket-Extensions") != "" {
		t.Fatal("client compression was negotiated")
	}
	t.Cleanup(func() { _ = conn.Close() })
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	return conn
}

func TestWebsocketRelayAndControls(t *testing.T) {
	front, received := websocketFixture(t)
	for _, path := range []string{"/v1/responses", "/backend-api/codex/responses"} {
		t.Run(path, func(t *testing.T) {
			conn := dialWebsocket(t, front+path+"?key="+responsesKey, "yes")
			if conn.Subprotocol() != "responses" {
				t.Fatal("negotiated subprotocol was lost")
			}
			pongs := map[string]bool{}
			ping := ""
			conn.SetPingHandler(func(payload string) error {
				ping = payload
				return conn.WriteControl(websocket.PongMessage, []byte(payload), time.Now().Add(time.Second))
			})
			conn.SetPongHandler(func(payload string) error { pongs[payload] = true; return nil })
			if err := conn.WriteControl(websocket.PingMessage, []byte("ping-original"), time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			if err := conn.WriteControl(websocket.PongMessage, []byte("pong-original"), time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			for _, body := range []string{` {"type":"response.create", "model":"m","input":[]} `, `{"type":"response.append","input":[]}`, `{"type":"response.interrupt","response_id":"r","model":"m"}`} {
				writer, err := conn.NextWriter(websocket.TextMessage)
				if err != nil {
					t.Fatal(err)
				}
				// A fragmented message is checked after reassembly.
				_, _ = io.WriteString(writer, body[:len(body)/2])
				_, _ = io.WriteString(writer, body[len(body)/2:])
				if err := writer.Close(); err != nil {
					t.Fatal(err)
				}
				for _, expected := range []struct {
					kind int
					body string
				}{{websocket.TextMessage, body}, {websocket.BinaryMessage, "outside-model"}} {
					kind, got, err := conn.ReadMessage()
					if err != nil || kind != expected.kind || string(got) != expected.body {
						t.Fatalf("relay: %d %q %v", kind, got, err)
					}
				}
			}
			if ping != "server-ping" || !pongs["server-pong"] || !pongs["ping-original"] {
				t.Fatalf("server controls: ping %q, pong %v", ping, pongs)
			}
			if err := conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, "bye"), time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			expected := map[string]bool{}
			for _, body := range []string{"pong:server-ping", "pong:pong-original", ` {"type":"response.create", "model":"m","input":[]} `, `{"type":"response.append","input":[]}`, `{"type":"response.interrupt","response_id":"r","model":"m"}`, "close:1000:bye", "closed"} {
				expected[body] = true
			}
			for len(expected) > 0 {
				select {
				case got := <-received:
					if !expected[got] {
						t.Fatalf("unexpected upstream message/control: %q", got)
					}
					delete(expected, got)
				case <-time.After(10 * time.Second):
					t.Fatal("upstream did not receive message/control")
				}
			}
		})
	}
}

// The upstream is reachable, so these must exercise Gorilla's client-facing
// handshake error callback rather than a failed upstream dial.
func TestWebsocketHandshakeRefusals(t *testing.T) {
	front, received := websocketFixture(t)
	for _, key := range []string{"", "malformed", "AA=="} {
		req, err := http.NewRequest(http.MethodGet, "http"+strings.TrimPrefix(front, "ws")+"/v1/responses", nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header = http.Header{"Authorization": {"Bearer " + responsesKey}, "Connection": {"Upgrade"}, "Upgrade": {"websocket"}, "Sec-Websocket-Version": {"13"}, "X-Client": {"retained"}}
		if key != "" {
			req.Header.Set("Sec-WebSocket-Key", key)
		}
		resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if err != nil || resp.StatusCode != http.StatusNotFound || len(body) != 0 || resp.Header.Get("Sec-WebSocket-Version") != "" {
			t.Fatalf("handshake refusal: %d %v %q %v", resp.StatusCode, resp.Header, body, err)
		}
		select {
		case got := <-received:
			if got != "closed" {
				t.Fatalf("bad handshake forwarded data: %q", got)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("upstream handshake was not exercised and closed")
		}
	}
}

func TestWebsocketUpstreamClose(t *testing.T) {
	front, _ := websocketFixture(t)
	conn := dialWebsocket(t, front+"/v1/responses?key="+responsesKey, "close")
	_, _, err := conn.ReadMessage()
	closed, ok := err.(*websocket.CloseError)
	if !ok || closed.Code != websocket.CloseGoingAway || closed.Text != "upstream-done" {
		t.Fatalf("upstream close changed: %v", err)
	}
}

func TestWebsocketRefusalsCloseBeforeForwarding(t *testing.T) {
	cases := []struct {
		name, body string
		kind       int
	}{
		{"binary", `{"model":"m"}`, websocket.BinaryMessage},
		{"case", `{"model":"M"}`, websocket.TextMessage},
		{"duplicate-type", `{"type":"response.interrupt","type":"response.create","model":"m"}`, websocket.TextMessage},
		{"escaped", `{"mo\u0064el":"m"}`, websocket.TextMessage},
		{"hosted-tool", `{"model":"m","tools":[{"type":"web_search"}]}`, websocket.TextMessage},
		{"invalid-json", `{"model":`, websocket.TextMessage},
		{"invalid-utf8", "{\"model\":\"m\",\"data\":\"\xff\"}", websocket.TextMessage},
		{"later-model", `{"type":"response.interrupt","model":"outside"}`, websocket.TextMessage},
		{"missing-model", `{}`, websocket.TextMessage},
		{"nested-model", `{"model":"m","fallbacks":[{"model":"outside"}]}`, websocket.TextMessage},
		{"non-object", `[]`, websocket.TextMessage},
		{"null-model", `{"model":null}`, websocket.TextMessage},
		{"oversize", `{"model":"m","data":"` + strings.Repeat("x", int(maxBodyBytes)) + `"}`, websocket.TextMessage},
		{"trailing", `{"model":"m"}{}`, websocket.TextMessage},
		{"trim-alias", `{"model":" m "}`, websocket.TextMessage},
	}
	var hostedTypes []string
	for _, c := range nonCanonicalHostedTypes {
		hostedTypes = append(hostedTypes, c.kind)
		cases = append(cases, struct {
			name, body string
			kind       int
		}{c.name, hostedTypeBody(c.field, c.kind), websocket.TextMessage})
	}
	for _, test := range cases {
		for _, later := range []bool{false, true} {
			if later && test.name == "missing-model" {
				continue
			}
			t.Run(fmt.Sprintf("%s/later=%t", test.name, later), func(t *testing.T) {
				front, received := websocketFixture(t, hostedTypes...)
				conn := dialWebsocket(t, front+"/v1/responses?key="+responsesKey)
				if later {
					_ = conn.WriteMessage(websocket.TextMessage, []byte(`{"model":"m"}`))
					for range 2 {
						if _, _, err := conn.ReadMessage(); err != nil {
							t.Fatal(err)
						}
					}
					if got := <-received; got != `{"model":"m"}` {
						t.Fatalf("first frame: %q", got)
					}
				}
				// The close can race a large write; its result is checked by reading.
				_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				writeStarted := time.Now()
				writeErr := conn.WriteMessage(test.kind, []byte(test.body))
				t.Logf("refusal write: elapsed=%s err=%v", time.Since(writeStarted), writeErr)
				_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
				_, _, err := conn.ReadMessage()
				closeError, ok := err.(*websocket.CloseError)
				if !ok || closeError.Code != websocket.ClosePolicyViolation || closeError.Text != "request refused" {
					t.Fatalf("nonuniform refusal: %v", err)
				}
				select {
				case got := <-received:
					if got != "closed" {
						t.Fatalf("refused input reached upstream: %q", got)
					}
				case <-time.After(10 * time.Second):
					t.Fatal("upstream connection survived refusal")
				}
			})
		}
	}
}

// Exercise the real Caddy writer in a child, then terminate the process just
// as a service restart does. HTTP shutdown alone does not own hijacked sockets.
func TestWebsocketProcessExit(t *testing.T) {
	if upstream := os.Getenv("CPA_GATE_WEBSOCKET_CHILD"); upstream != "" {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		addr := listener.Addr().String()
		_ = listener.Close()
		site := fmt.Sprintf("{\n admin off\n}\nhttp://%s {\n route {\n  cpa_gate * %s %s\n }\n}\n", addr, writePolicy(t, validPolicy), upstream)
		config, _, err := caddyconfig.GetAdapter("caddyfile").Adapt([]byte(site), nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := caddy.Load(config, true); err != nil {
			t.Fatal(err)
		}
		fmt.Println("READY ws://" + addr)
		_, _ = io.Copy(io.Discard, os.Stdin)
		_ = caddy.Stop()
		return
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/models" {
			_, _ = io.WriteString(w, `{"data":[{"id":"m"}]}`)
			return
		}
		conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			kind, body, err := conn.ReadMessage()
			if err != nil || conn.WriteMessage(kind, body) != nil {
				return
			}
		}
	}))
	defer upstream.Close()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(binary, "-test.run=^TestWebsocketProcessExit$")
	cmd.Env = append(os.Environ(), "CPA_GATE_WEBSOCKET_CHILD="+upstream.URL)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer stdin.Close()
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	ready := make(chan string, 1)
	var childOutput bytes.Buffer
	go func() {
		scanner := bufio.NewScanner(io.TeeReader(stdout, &childOutput))
		for scanner.Scan() {
			if strings.HasPrefix(scanner.Text(), "READY ") {
				ready <- strings.TrimPrefix(scanner.Text(), "READY ")
				return
			}
		}
		ready <- ""
	}()
	var target string
	select {
	case target = <-ready:
	case <-time.After(20 * time.Second):
		t.Fatal("child Caddy did not start")
	}
	if target == "" {
		_ = cmd.Wait()
		t.Fatalf("child failed:\nstdout: %s\nstderr: %s", &childOutput, &stderr)
	}
	conn := dialWebsocket(t, target+"/v1/responses?key="+responsesKey)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"model":"m"}`)); err != nil {
		t.Fatal(err)
	}
	if _, body, err := conn.ReadMessage(); err != nil || string(body) != `{"model":"m"}` {
		t.Fatalf("Caddy relay: %q %v", body, err)
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	if _, _, err := conn.ReadMessage(); err == nil {
		t.Fatal("hijacked websocket survived process exit")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("process exit did not close the socket before its read deadline")
	}
}
