package gate

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"github.com/tidwall/gjson"
)

// Caddy wraps the writer. Gorilla requires Hijacker directly, while the
// controller follows Unwrap to the underlying HTTP/1 connection.
type websocketWriter struct{ http.ResponseWriter }

func (w websocketWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return http.NewResponseController(w.ResponseWriter).Hijack()
}

func (g *Gate) serveWebsocket(w http.ResponseWriter, r *http.Request, e *entry) error {
	if !websocket.IsWebSocketUpgrade(r) || r.Header.Get("Sec-WebSocket-Version") != "13" {
		return g.refuse(w, notFound, e.name, classWebsocket, "websocket")
	}
	// Recreate transport headers on each hop; neither side negotiates compression.
	header := r.Header.Clone()
	for _, name := range []string{"Connection", "Upgrade", "Sec-WebSocket-Key", "Sec-WebSocket-Version", "Sec-WebSocket-Extensions"} {
		header.Del(name)
	}
	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
	upstream, response, err := dialer.DialContext(r.Context(), "ws"+strings.TrimPrefix(g.Upstream, "http")+r.URL.RequestURI(), header)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return g.refuse(w, notFound, e.name, classWebsocket, "websocket")
	}
	defer upstream.Close()
	upgrader := websocket.Upgrader{
		Error: func(w http.ResponseWriter, _ *http.Request, _ int, _ error) {
			_ = g.refuse(w, notFound, e.name, classWebsocket, "websocket")
		},
		// As with CPA, credentials authenticate non-browser clients. Origin is
		// forwarded to CPA, whose handshake may impose its own check.
		CheckOrigin:  func(*http.Request) bool { return true },
		Subprotocols: []string{upstream.Subprotocol()},
	}
	client, err := upgrader.Upgrade(websocketWriter{w}, r, nil)
	if err != nil {
		return nil // Never hand Caddy an error containing handshake headers.
	}
	defer client.Close()
	// Gorilla's defaults consume ping/pong and synthesize replies. Relay the
	// original control payload instead; WriteControl may run beside a data writer.
	for source, destination := range map[*websocket.Conn]*websocket.Conn{client: upstream, upstream: client} {
		source.SetPingHandler(func(payload string) error { return relayControl(destination, websocket.PingMessage, payload) })
		source.SetPongHandler(func(payload string) error { return relayControl(destination, websocket.PongMessage, payload) })
		source.SetCloseHandler(func(code int, text string) error {
			return destination.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(code, text), time.Now().Add(5*time.Second))
		})
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer client.Close() // Unblock the opposite reader on EOF or write failure.
		for {
			kind, payload, err := upstream.ReadMessage()
			if err != nil || client.WriteMessage(kind, payload) != nil {
				return
			}
		}
	}()
	first := true
	for {
		kind, reader, err := client.NextReader()
		if err != nil {
			break
		}
		// SetReadLimit emits its own, different 1009 close. Bound the read here
		// so oversized messages get exactly the same refusal as every bad input.
		payload, err := io.ReadAll(io.LimitReader(reader, maxBodyBytes+1))
		model := gjson.GetBytes(payload, "model")
		if err != nil || kind != websocket.TextMessage || int64(len(payload)) > maxBodyBytes ||
			!validMessage(payload, e, first) || (model.Exists() && strings.TrimSpace(model.String()) != model.String()) {
			_ = relayControl(client, websocket.CloseMessage, string(websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "request refused")))
			break
		}
		if upstream.WriteMessage(kind, payload) != nil {
			break
		}
		first = false
	}
	_ = upstream.Close()
	_ = client.Close()
	<-done
	return nil
}

func relayControl(conn *websocket.Conn, kind int, payload string) error {
	return conn.WriteControl(kind, []byte(payload), time.Now().Add(5*time.Second))
}
