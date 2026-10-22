package gate

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
	"github.com/tidwall/gjson"
)

// listingCapture owns its headers, so even interim headers and trailers from
// CPA cannot reach the client before filtering. Writes stop at the same limit
// used for decoded request bodies.
type listingCapture struct {
	header  http.Header
	body    bytes.Buffer
	status  int
	failed  bool
}

func (c *listingCapture) Header() http.Header { return c.header }

func (c *listingCapture) WriteHeader(status int) {
	if status < 200 {
		return
	}
	if c.status == 0 {
		c.status = status
	}
}

func (c *listingCapture) Write(p []byte) (int, error) {
	if c.status == 0 {
		c.status = http.StatusOK
	}
	if int64(len(p)) > maxBodyBytes-int64(c.body.Len()) {
		c.failed = true
		return 0, errors.New("listing exceeds limit")
	}
	n, err := c.body.Write(p)
	if err != nil {
		c.failed = true
	}
	return n, err
}

func (c *listingCapture) Flush() {}

// Listings are the only downstream responses the gate inspects.
func (g *Gate) serveListing(w http.ResponseWriter, r *http.Request, next caddyhttp.Handler, e *entry, detail bool) (err error) {
	r.Header.Set("Accept-Encoding", "identity")
	rec := &listingCapture{header: make(http.Header)}
	defer func() {
		if caught := recover(); caught != nil {
			if caught != http.ErrAbortHandler {
				panic(caught)
			}
			err = g.refuse(w, notFound, e.name, classListing, "upstream")
		}
	}()
	if err := next.ServeHTTP(rec, r); err != nil {
		return g.refuse(w, notFound, e.name, classListing, "upstream")
	}
	if rec.failed || rec.status != http.StatusOK {
		return g.refuse(w, notFound, e.name, classListing, "upstream")
	}
	decoded, ok := decodeListing(&rec.body, rec.header)
	if !ok {
		return g.refuse(w, notFound, e.name, classListing, "shape")
	}
	var filtered []byte
	if detail {
		filtered, ok = filterDetail(decoded, e, r.URL.Path)
	} else {
		filtered, ok = filterListing(decoded, e)
	}
	if !ok {
		return g.refuse(w, notFound, e.name, classListing, "shape")
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(filtered)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(filtered)
	return nil
}

func decodeListing(buf *bytes.Buffer, header http.Header) ([]byte, bool) {
	if value := header.Get("Content-Type"); value != "" {
		mediaType, _, err := mime.ParseMediaType(value)
		if err != nil || mediaType != "application/json" {
			return nil, false
		}
	}
	encodings := header.Values("Content-Encoding")
	if len(encodings) > 1 {
		return nil, false
	}
	encoding := "identity"
	if len(encodings) == 1 {
		encoding = encodings[0]
	}
	if encoding != "identity" && encoding != "gzip" && encoding != "zstd" {
		return nil, false
	}
	decoded, err := decodeWire(buf.Bytes(), encoding)
	return decoded, err == nil
}

// parseListing shares PR3's strict lexical walk before any decoder can fold
// names or choose a different duplicate. A listing need not name a model at
// its root, unlike a call.
func parseListing(raw []byte) (map[string]any, gjson.Result, bool) {
	if len(raw) == 0 || !utf8.Valid(raw) || !gjson.ValidBytes(raw) || raw[firstNonSpace(raw)] != '{' {
		return nil, gjson.Result{}, false
	}
	s := strictScanner{body: raw, text: string(raw)}
	if !s.value(nil, false, 0) || !s.done() {
		return nil, gjson.Result{}, false
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var root map[string]any
	if err := decoder.Decode(&root); err != nil || root == nil {
		return nil, gjson.Result{}, false
	}
	var trailing any
	return root, gjson.ParseBytes(raw), decoder.Decode(&trailing) == io.EOF
}

type listingResult struct {
	body   []byte
	ids    map[string]bool
	openAI bool
}

// interpretListing handles the five CPA 8.0.38 producers by their wire shape:
// OpenAI, Anthropic and Grok have data[].id; Codex has models[].slug;
// Gemini has models[].name with a models/ prefix. Headers and user agents do
// not select a parser. Unknown envelope fields fail closed.
func interpretListing(raw []byte, e *entry) (listingResult, bool) {
	root, parsed, ok := parseListing(raw)
	if !ok {
		return listingResult{}, false
	}
	field := "data"
	if _, found := root[field]; !found {
		field = "models"
	}
	for name := range root {
		if !(field == "data" && (name == "data" || name == "object" || name == "first_id" || name == "last_id" || name == "has_more")) &&
			!(field == "models" && name == "models") {
			return listingResult{}, false
		}
	}
	rows, ok := root[field].([]any)
	if !ok {
		return listingResult{}, false
	}
	if object, present := root["object"]; present && object != "list" {
		return listingResult{}, false
	}
	if more, present := root["has_more"]; present && more != false {
		return listingResult{}, false
	}
	parsedRows := parsed.Get(field).Array()
	if len(parsedRows) != len(rows) {
		return listingResult{}, false
	}
	kept := make([]any, 0, len(rows))
	ids := make([]string, 0, len(rows))
	for i, value := range rows {
		row, ok := value.(map[string]any)
		if !ok {
			return listingResult{}, false
		}
		id, ok := listingID(row, field)
		if !ok {
			return listingResult{}, false
		}
		if !e.models[id] {
			continue
		}
		if !scrubModelRefs(parsedRows[i], row, e) {
			// A top-level row with a forbidden model directive is omitted.
			continue
		}
		kept = append(kept, row)
		ids = append(ids, id)
	}
	root[field] = kept
	if _, found := root["first_id"]; found {
		root["first_id"] = ""
		if len(ids) > 0 {
			root["first_id"] = ids[0]
		}
	}
	if _, found := root["last_id"]; found {
		root["last_id"] = ""
		if len(ids) > 0 {
			root["last_id"] = ids[len(ids)-1]
		}
	}
	filtered, err := json.Marshal(root)
	if err != nil {
		return listingResult{}, false
	}
	result := listingResult{body: filtered, ids: make(map[string]bool, len(ids)), openAI: field == "data" && root["object"] == "list"}
	for _, id := range ids {
		result.ids[id] = true
	}
	return result, true
}

func filterListing(raw []byte, e *entry) ([]byte, bool) {
	result, ok := interpretListing(raw, e)
	return result.body, ok
}

func listingID(row map[string]any, field string) (string, bool) {
	if field == "data" {
		if _, found := row["slug"]; found {
			return "", false
		}
		id, ok := row["id"].(string)
		if name, found := row["name"].(string); found {
			if model, prefixed := strings.CutPrefix(name, "models/"); prefixed && model != id {
				return "", false
			}
		}
		return id, ok && id != ""
	}
	if _, found := row["id"]; found {
		return "", false
	}
	if slug, present := row["slug"]; present {
		if _, found := row["name"]; found {
			return "", false
		}
		id, ok := slug.(string)
		return id, ok && id != ""
	}
	name, ok := row["name"].(string)
	id, found := strings.CutPrefix(name, "models/")
	return id, ok && found && id != ""
}

// A model-like directive outside the set invalidates its enclosing object.
// Nested objects become null, including Codex's upgrade object; a bad row is
// dropped by filterListing. Other metadata remains from CPA.
func scrubModelRefs(node gjson.Result, output any, e *entry) bool {
	switch value := output.(type) {
	case map[string]any:
		allowed := true
		node.ForEach(func(key, child gjson.Result) bool {
			name := key.String()
			allowed = !modelLike(name) || allowedModel(child, e, name)
			return allowed
		})
		if !allowed {
			return false
		}
		node.ForEach(func(key, child gjson.Result) bool {
			name := key.String()
			if !scrubModelRefs(child, value[name], e) {
				value[name] = nil
			}
			return true
		})
	case []any:
		children := node.Array()
		for i, child := range value {
			if !scrubModelRefs(children[i], child, e) {
				value[i] = nil
			}
		}
	}
	return true
}

func filterDetail(raw []byte, e *entry, path string) ([]byte, bool) {
	row, parsed, ok := parseListing(raw)
	if !ok {
		return nil, false
	}
	id := path[strings.LastIndex(path, "/")+1:]
	field := "models"
	if _, hasID := row["id"]; hasID {
		field = "data"
	}
	got, valid := listingID(row, field)
	if !valid || got != id || !e.models[got] || !scrubModelRefs(parsed, row, e) {
		return nil, false
	}
	filtered, err := json.Marshal(row)
	return filtered, err == nil
}
