package gate

import (
	"net/url"
	"slices"
	"strings"
)

// The check a route class needs before the gate forwards it.
const (
	classCall      = "call"      // a JSON request body that names a model
	classListing   = "listing"   // a model listing in the response
	classWebsocket = "websocket" // Responses websocket frames
)

type route struct {
	// api is the policy `apis` value that admits the route; "" admits it
	// for every entry.
	api   string
	class string
	detail bool
	// query lists the query keys the route takes besides the key carriers.
	query []string
}

// routes is the allowlist, keyed by method and exact path, from CPA's route
// table (internal/api/server_routes.go). Exact matching also refuses `//`,
// dot segments, a trailing slash and case variants.
var routes = map[string]route{
	"GET /v1/models": {class: classListing, query: []string{"client_version"}},
	"GET /v1beta/models": {api: "gemini", class: classListing},

	"POST /v1/messages":              {api: "anthropic", class: classCall, query: []string{"beta"}},
	"POST /v1/messages/count_tokens": {api: "anthropic", class: classCall, query: []string{"beta"}},

	"POST /v1/chat/completions": {api: "chat", class: classCall},

	"GET /backend-api/codex/responses":          {api: "responses", class: classWebsocket},
	"GET /v1/responses":                         {api: "responses", class: classWebsocket},
	"POST /backend-api/codex/responses":         {api: "responses", class: classCall},
	"POST /backend-api/codex/responses/compact": {api: "responses", class: classCall},
	"POST /v1/responses":                        {api: "responses", class: classCall},
	"POST /v1/responses/compact":                {api: "responses", class: classCall},
}

// Detail paths have a model ID in place of a literal route-table segment.
// Match one unescaped segment and the entry's byte-exact model set.
func detailRoute(path string, e *entry) (route, bool) {
	for _, prefix := range []struct{ path, api string }{
		{"/v1/models/", ""},
		{"/v1beta/models/", "gemini"},
	} {
		if id, ok := strings.CutPrefix(path, prefix.path); ok && id != "" && !strings.Contains(id, "/") && e.models[id] {
			return route{api: prefix.api, class: classListing, detail: true}, true
		}
	}
	return route{}, false
}

// knownAPI reports whether some route names api.
func knownAPI(api string) bool {
	for _, rt := range routes {
		if rt.api != "" && rt.api == api {
			return true
		}
	}
	return false
}

// queryAllowed reports whether every query key other than a key carrier is
// one the route takes, given once.
func queryAllowed(query url.Values, allowed []string) bool {
	for name, values := range query {
		if slices.Contains(queryCarriers, name) {
			continue
		}
		if len(values) != 1 || !slices.Contains(allowed, name) {
			return false
		}
	}
	return true
}
