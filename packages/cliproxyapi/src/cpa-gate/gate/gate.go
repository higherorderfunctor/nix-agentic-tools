// Package gate is the http.handlers.cpa_gate Caddy module. It stands in front
// of CLIProxyAPI (CPA), admits a request only when it carries exactly one
// known client key on an allowed route, and replaces that key with the
// entry's internal key, so CPA enforces its rules for the principal the gate
// chose.
//
// It is NOT a security boundary while a harness runs under the same uid as
// the gate: such a harness can read the policy file and the internal keys in
// it.
package gate

import (
	"crypto/sha256"
	"crypto/subtle"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/httpcaddyfile"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
	"go.uber.org/zap"
)

func init() {
	caddy.RegisterModule(Gate{})
	caddy.RegisterModule(Health{})
	httpcaddyfile.RegisterHandlerDirective("cpa_gate", parseCaddyfile)
	httpcaddyfile.RegisterHandlerDirective("cpa_gate_health", parseHealthCaddyfile)
}

// Gate is the module. A Caddyfile sets it with
// `cpa_gate * <policy path> <loopback CPA origin>`:
// Caddy reads the first argument of a handler directive as a matcher when it
// starts with `/`, so an absolute path needs the `*` before it.
type Gate struct {
	// Policy is the path of the policy file. Keys never appear in the
	// Caddyfile: Caddy splices `{$VAR}` values in before parsing and keeps
	// them in the adapted config.
	Policy   string `json:"policy"`
	Upstream string `json:"upstream"`

	keys   map[[sha256.Size]byte]*entry
	logger *zap.Logger
	health *healthState
}

// Caddy provisions a module only through this interface, so a wrong
// Provision signature would leave the gate refusing every key.
var _ caddy.Provisioner = (*Gate)(nil)

// CaddyModule returns the module's registration.
func (Gate) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "http.handlers.cpa_gate",
		New: func() caddy.Module { return new(Gate) },
	}
}

// Provision loads the policy. A policy the gate cannot enforce fails
// `caddy run` and `caddy validate`.
func (g *Gate) Provision(ctx caddy.Context) error {
	g.logger = ctx.Logger()
	keys, err := loadPolicy(g.Policy)
	if err != nil {
		return fmt.Errorf("cpa_gate: %w", err)
	}
	g.keys = keys
	return g.startChecker()
}

func (g *Gate) Cleanup() error {
	g.stopChecker()
	return nil
}

func parseCaddyfile(h httpcaddyfile.Helper) (caddyhttp.MiddlewareHandler, error) {
	g := new(Gate)
	h.Next()
	// An unset `{$VAR}` substitutes nothing, so it arrives here as a
	// missing argument.
	if !h.AllArgs(&g.Policy, &g.Upstream) {
		return nil, h.ArgErr()
	}
	if h.NextBlock(0) {
		return nil, h.Err("cpa_gate takes no block")
	}
	return g, nil
}

// The carriers CPA reads a client key from
// (internal/access/config_access/provider.go).
var (
	headerCarriers = []string{"Authorization", "X-Api-Key", "X-Goog-Api-Key"}
	queryCarriers  = []string{"auth_token", "key"}
)

// ServeHTTP authenticates, admits checked calls and filters listings.
// Websocket frames remain refused until their separate check is present.
func (g *Gate) ServeHTTP(w http.ResponseWriter, r *http.Request, next caddyhttp.Handler) error {
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return g.refuse(w, unauthorized, "-", "-", "query")
	}
	e := g.authenticate(r.Header, query)
	if e == nil {
		return g.refuse(w, unauthorized, "-", "-", "key")
	}
	rt, ok := routes[r.Method+" "+r.URL.Path]
	if !ok && r.Method == http.MethodGet {
		rt, ok = detailRoute(r.URL.Path, e)
	}
	// RawPath is set only when the path was escaped some other way than
	// Go would escape it, as when a slash arrives as %2F.
	if !ok || r.URL.RawPath != "" || (rt.api != "" && !e.apis[rt.api]) || !queryAllowed(query, rt.query) {
		return g.refuse(w, notFound, e.name, "-", "route")
	}
	// reverse_proxy relays an upgrade on any route; only the websocket
	// routes may ask for one.
	if rt.class != classWebsocket {
		r.Header.Del("Connection")
		r.Header.Del("Upgrade")
	}
	if rt.class == classCall {
		if !checkBody(r, e) {
			return g.refuse(w, notFound, e.name, rt.class, "body")
		}
		rewrite(r, query, e.internal)
		return next.ServeHTTP(w, r)
	}
	rewrite(r, query, e.internal)
	if rt.class == classListing {
		return g.serveListing(w, r, next, e, rt.detail)
	}
	return g.refuse(w, notFound, e.name, rt.class, "pending")
}

// authenticate returns the entry whose client key the request carries in
// exactly one carrier, or nil. A repeated header or query key counts once
// per value, so it is refused like two carriers.
func (g *Gate) authenticate(header http.Header, query url.Values) *entry {
	var tokens []string
	for _, name := range headerCarriers {
		tokens = append(tokens, header.Values(name)...)
	}
	for _, name := range queryCarriers {
		tokens = append(tokens, query[name]...)
	}
	if len(tokens) != 1 {
		return nil
	}
	token := tokens[0]
	if len(header.Values("Authorization")) == 1 {
		scheme, rest, found := strings.Cut(token, " ")
		if !found || !strings.EqualFold(scheme, "Bearer") {
			return nil
		}
		token = rest
	}
	sum := sha256.Sum256([]byte(token))
	var selected *entry
	for digest, e := range g.keys {
		if subtle.ConstantTimeCompare(sum[:], digest[:]) == 1 {
			selected = e
		}
	}
	return selected
}

// rewrite removes every carrier and sets the internal key as the one
// credential CPA sees.
func rewrite(r *http.Request, query url.Values, internal string) {
	for _, name := range headerCarriers {
		r.Header.Del(name)
	}
	for _, name := range queryCarriers {
		query.Del(name)
	}
	r.URL.RawQuery = query.Encode()
	r.Header.Set("Authorization", "Bearer "+internal)
}

// refusal is one fixed response, so a probe learns nothing from the bytes.
type refusal struct {
	status int
	header http.Header
	body   []byte
}

var (
	// CPA's own answer to a key it does not know (sdk/access/errors.go).
	unauthorized = refusal{
		status: http.StatusUnauthorized,
		header: http.Header{"Content-Type": {"application/json; charset=utf-8"}},
		body:   []byte(`{"error":"Invalid API key"}`),
	}
	// CPA's own unknown route: gin's NoRoute 404 with no body.
	notFound = refusal{status: http.StatusNotFound}
)

// refuse writes f and logs the refusal. The line names the entry, the route
// class and the reason, never a key, a header or the request URI. It returns
// nil: an error would make Caddy log the whole request.
func (g *Gate) refuse(w http.ResponseWriter, f refusal, entry, class, reason string) error {
	g.logger.Info("refused",
		zap.String("entry", entry),
		zap.String("route", class),
		zap.Int("status", f.status),
		zap.String("reason", reason),
	)
	for name, values := range f.header {
		w.Header()[name] = values
	}
	w.WriteHeader(f.status)
	_, _ = w.Write(f.body)
	return nil
}
