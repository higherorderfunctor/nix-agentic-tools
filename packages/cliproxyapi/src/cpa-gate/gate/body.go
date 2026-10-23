package gate

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/klauspost/compress/zstd"
	"github.com/tidwall/gjson"
)

// CPA's server.max-request-body-bytes will be set to the same value when the
// gate is wired. Both the wire body and its decoded form have this ceiling.
const maxBodyBytes int64 = 32 << 20

// checkBody forwards precisely the bytes it checked. In particular, CPA must
// not get a compressed body that one of its handlers decodes differently.
func checkBody(r *http.Request, e *entry) bool {
	contentType := r.Header.Values("Content-Type")
	if len(contentType) != 1 {
		return false
	}
	mediaType, params, err := mime.ParseMediaType(contentType[0])
	if err != nil || mediaType != "application/json" || (params["charset"] != "" && !strings.EqualFold(params["charset"], "utf-8")) {
		return false
	}
	encoding, ok := wireEncoding(r.Header)
	if !ok || r.Body == nil {
		return false
	}
	wired, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes+1))
	_ = r.Body.Close()
	if err != nil || int64(len(wired)) > maxBodyBytes {
		return false
	}
	decoded, err := decodeWire(wired, encoding)
	if err != nil || !validBody(decoded, e) {
		return false
	}
	r.Body = io.NopCloser(bytes.NewReader(decoded))
	r.ContentLength = int64(len(decoded))
	r.Header.Set("Content-Length", strconv.Itoa(len(decoded)))
	r.Header.Del("Content-Encoding")
	return true
}

// wireEncoding returns the one Content-Encoding the gate can decode.
func wireEncoding(header http.Header) (string, bool) {
	values := header.Values("Content-Encoding")
	if len(values) > 1 {
		return "", false
	}
	encoding := "identity"
	if len(values) == 1 {
		encoding = values[0]
	}
	return encoding, encoding == "identity" || encoding == "gzip" || encoding == "zstd"
}

// decodeWire has the same decoded-size ceiling for calls and listings. The
// caller limits the wire bytes, so an identity body needs no further check.
func decodeWire(wired []byte, encoding string) ([]byte, error) {
	var source io.Reader
	switch encoding {
	case "gzip":
		reader, err := gzip.NewReader(bytes.NewReader(wired))
		if err != nil {
			return nil, err
		}
		defer reader.Close()
		source = reader
	case "zstd":
		reader, err := zstd.NewReader(bytes.NewReader(wired), zstd.WithDecoderMaxMemory(uint64(maxBodyBytes*2)))
		if err != nil {
			return nil, err
		}
		defer reader.Close()
		source = reader
	default:
		return wired, nil
	}
	decoded, err := io.ReadAll(io.LimitReader(source, maxBodyBytes+1))
	if err == nil && int64(len(decoded)) > maxBodyBytes {
		err = errors.New("decoded body exceeds limit")
	}
	return decoded, err
}

// validBody checks the syntax and names before relying on gjson's first-name
// lookup. CPA 8.0.38 reads its model with gjson v1.18.0 GetBytes.
func validBody(body []byte, e *entry) bool {
	return validMessage(body, e, true)
}

// A later websocket request may inherit its model from the checked first one.
func validMessage(body []byte, e *entry, requireModel bool) bool {
	if !utf8.Valid(body) || !gjson.ValidBytes(body) {
		return false
	}
	s := strictScanner{body: body, text: string(body)}
	if !s.value(nil, false, 0) || !s.done() || len(body) == 0 || body[firstNonSpace(body)] != '{' || (requireModel && !s.hasModel) {
		return false
	}
	model := gjson.GetBytes(body, "model")
	if s.hasModel && (model.Type != gjson.String || model.String() != s.model || !e.models[s.model]) {
		return false
	}
	return checkNode(gjson.ParseBytes(body), nil, e)
}

// strictScanner validates the lexical distinctions gjson intentionally
// normalizes: duplicate names, escaped directive names and lone surrogates.
// JSON syntax has already been checked by gjson.ValidBytes.
type strictScanner struct {
	body     []byte
	text     string
	pos      int
	model    string
	hasModel bool
}

// A path step records whether it came from an array. A JSON name such as "*"
// can never masquerade as an array position.
type pathStep struct {
	name  string
	array bool
}

func childPath(path []pathStep, step pathStep) []pathStep {
	return append(append([]pathStep(nil), path...), step)
}

func firstNonSpace(body []byte) int {
	for i, b := range body {
		if b != ' ' && b != '\n' && b != '\r' && b != '\t' {
			return i
		}
	}
	return 0
}

func (s *strictScanner) space() {
	for s.pos < len(s.body) {
		switch s.body[s.pos] {
		case ' ', '\n', '\r', '\t':
			s.pos++
		default:
			return
		}
	}
}

func (s *strictScanner) done() bool {
	s.space()
	return s.pos == len(s.body)
}

// string returns the unescaped string and whether its raw spelling contained
// a backslash. A high surrogate must have an immediately paired low surrogate.
func (s *strictScanner) string() (string, bool, bool) {
	start := s.pos
	s.pos++ // opening quote; gjson.ValidBytes established it
	escaped := false
	for s.pos < len(s.body) {
		ch := s.body[s.pos]
		if ch == '"' {
			s.pos++
			return gjson.ParseBytes(s.body[start:s.pos]).String(), escaped, true
		}
		if ch != '\\' {
			s.pos++
			continue
		}
		escaped = true
		if s.pos+1 >= len(s.body) {
			return "", false, false
		}
		if s.body[s.pos+1] != 'u' {
			s.pos += 2
			continue
		}
		if s.pos+6 > len(s.body) {
			return "", false, false
		}
		first, err := strconv.ParseUint(string(s.body[s.pos+2:s.pos+6]), 16, 16)
		if err != nil {
			return "", false, false
		}
		s.pos += 6
		if first >= 0xdc00 && first <= 0xdfff {
			return "", false, false
		}
		if first >= 0xd800 && first <= 0xdbff {
			if s.pos+6 > len(s.body) || s.body[s.pos] != '\\' || s.body[s.pos+1] != 'u' {
				return "", false, false
			}
			second, err := strconv.ParseUint(string(s.body[s.pos+2:s.pos+6]), 16, 16)
			if err != nil || second < 0xdc00 || second > 0xdfff {
				return "", false, false
			}
			s.pos += 6
		}
	}
	return "", false, false
}

func (s *strictScanner) value(path []pathStep, skip bool, depth int) bool {
	s.space()
	if s.pos >= len(s.body) {
		return false
	}
	switch s.body[s.pos] {
	case '{':
		if depth >= 128 {
			return false
		}
		parentType := gjson.Parse(s.text[s.pos:]).Get("type").String()
		s.pos++
		s.space()
		seen := map[string]bool{}
		folded := map[string]bool{}
		for s.pos < len(s.body) && s.body[s.pos] != '}' {
			if s.body[s.pos] != '"' {
				return false
			}
			name, escaped, ok := s.string()
			if !ok || seen[name] || (!skip && (escaped || !asciiName(name))) {
				return false
			}
			fold := simpleFold(name)
			like := modelLike(name)
			if previousLike, found := folded[fold]; found && (like || previousLike) {
				return false
			}
			seen[name] = true
			folded[fold] = folded[fold] || like
			s.space()
			if s.pos >= len(s.body) || s.body[s.pos] != ':' {
				return false
			}
			s.pos++
			child := childPath(path, pathStep{name: name})
			s.space()
			start := s.pos
			if !s.value(child, skip || schemaSkip(path, name) || clientArgSkip(path, name, parentType), depth+1) {
				return false
			}
			if len(path) == 0 && name == "model" {
				if err := json.Unmarshal(s.body[start:s.pos], &s.model); err != nil {
					return false
				}
				s.hasModel = true
			}
			s.space()
			if s.pos < len(s.body) && s.body[s.pos] == ',' {
				s.pos++
				s.space()
				continue
			}
			break
		}
		if s.pos >= len(s.body) || s.body[s.pos] != '}' {
			return false
		}
		s.pos++
	case '[':
		if depth >= 128 {
			return false
		}
		s.pos++
		s.space()
		for s.pos < len(s.body) && s.body[s.pos] != ']' {
			if !s.value(childPath(path, pathStep{array: true}), skip, depth+1) {
				return false
			}
			s.space()
			if s.pos < len(s.body) && s.body[s.pos] == ',' {
				s.pos++
				s.space()
				continue
			}
			break
		}
		if s.pos >= len(s.body) || s.body[s.pos] != ']' {
			return false
		}
		s.pos++
	case '"':
		_, _, ok := s.string()
		return ok
	default:
		for s.pos < len(s.body) && !strings.ContainsRune(",]} \n\r\t", rune(s.body[s.pos])) {
			s.pos++
		}
	}
	return true
}

func asciiName(name string) bool {
	for i := 0; i < len(name); i++ {
		if name[i] < 0x20 || name[i] > 0x7e {
			return false
		}
	}
	return true
}

func modelLike(name string) bool {
	lower := strings.ToLower(name)
	return lower == "model" || lower == "models" || strings.HasSuffix(lower, "_model") ||
		strings.HasSuffix(lower, "_models") || strings.HasSuffix(name, "Model") || strings.HasSuffix(name, "Models")
}

// simpleFold gives EqualFold-equivalent names one key without a quadratic
// comparison of every pair of fields in a large object.
func simpleFold(name string) string {
	var b strings.Builder
	b.Grow(len(name))
	for _, r := range name {
		canonical := r
		for next := unicode.SimpleFold(r); next != r; next = unicode.SimpleFold(next) {
			if next < canonical {
				canonical = next
			}
		}
		b.WriteRune(canonical)
	}
	return b.String()
}

func schemaSkip(path []pathStep, name string) bool {
	if len(path) >= 2 && path[len(path)-2] == (pathStep{name: "tools"}) && path[len(path)-1].array {
		return name == "input_schema" || name == "parameters"
	}
	if len(path) >= 3 && path[len(path)-3] == (pathStep{name: "tools"}) && path[len(path)-2].array && path[len(path)-1] == (pathStep{name: "function"}) {
		return name == "parameters"
	}
	return name == "schema" && (equalPath(path, "text", "format") ||
		equalPath(path, "response_format", "json_schema") || equalPath(path, "output_format"))
}

func equalPath(path []pathStep, parts ...string) bool {
	if len(path) != len(parts) {
		return false
	}
	for i, part := range parts {
		if path[i] != (pathStep{name: part}) {
			return false
		}
	}
	return true
}

// Client-owned arguments are data only at these structural positions.
func clientArgSkip(path []pathStep, name, parentType string) bool {
	return (len(path) == 2 && path[0] == (pathStep{name: "input"}) && path[1].array && (parentType == "function_call" || parentType == "custom_tool_call") && (name == "arguments" || name == "input")) ||
		(len(path) >= 2 && path[len(path)-2] == (pathStep{name: "content"}) && path[len(path)-1].array && parentType == "tool_use" && name == "input")
}

func allowedModel(value gjson.Result, e *entry, name string) bool {
	if value.Type == gjson.Null {
		return strings.HasSuffix(strings.ToLower(name), "_model")
	}
	if value.Type == gjson.String {
		return e.models[value.String()]
	}
	if !value.IsArray() {
		return false
	}
	ok := true
	value.ForEach(func(_, item gjson.Result) bool {
		ok = item.Type == gjson.String && e.models[item.String()]
		return ok
	})
	return ok
}

func checkNode(node gjson.Result, path []pathStep, e *entry) bool {
	if node.IsArray() {
		ok := true
		node.ForEach(func(_, item gjson.Result) bool {
			ok = checkNode(item, childPath(path, pathStep{array: true}), e)
			return ok
		})
		return ok
	}
	if !node.IsObject() {
		return true
	}
	parentType := node.Get("type").String()
	ok := true
	node.ForEach(func(key, value gjson.Result) bool {
		name := key.String()
		if modelLike(name) && !allowedModel(value, e, name) {
			ok = false
			return false
		}
		if name == "tools" && value.IsArray() && !checkTools(value, e) {
			ok = false
			return false
		}
		if len(path) == 0 && name == "input" && value.IsArray() && !checkInputCalls(value, e) {
			ok = false
			return false
		}
		if schemaSkip(path, name) || clientArgSkip(path, name, parentType) {
			return true
		}
		ok = checkNode(value, childPath(path, pathStep{name: name}), e)
		return ok
	})
	return ok
}

func checkTools(tools gjson.Result, e *entry) bool {
	ok := true
	tools.ForEach(func(_, tool gjson.Result) bool {
		if !tool.IsObject() {
			ok = false
			return false
		}
		typeValue := tool.Get("type")
		if !typeValue.Exists() {
			return true
		}
		kind := typeValue.String()
		ok = typeValue.Type == gjson.String && (kind == "function" || kind == "custom" || e.hostedTools[kind])
		return ok
	})
	return ok
}

func checkInputCalls(input gjson.Result, e *entry) bool {
	ok := true
	input.ForEach(func(_, item gjson.Result) bool {
		if !item.IsObject() {
			return true
		}
		typeValue := item.Get("type")
		if !typeValue.Exists() || typeValue.Type != gjson.String {
			return true
		}
		kind := typeValue.String()
		if !strings.HasSuffix(kind, "_call") && !strings.HasSuffix(kind, "_call_output") {
			return true
		}
		if kind == "function_call" || kind == "function_call_output" || kind == "custom_tool_call" || kind == "custom_tool_call_output" {
			return true
		}
		for hosted := range e.hostedTools {
			base := hosted
			if i := strings.LastIndexByte(hosted, '_'); i >= 0 && len(hosted)-i == 9 {
				if _, err := strconv.Atoi(hosted[i+1:]); err == nil {
					base = hosted[:i]
				}
			}
			if kind == base+"_call" || kind == base+"_call_output" {
				return true
			}
		}
		ok = false
		return false
	})
	return ok
}
