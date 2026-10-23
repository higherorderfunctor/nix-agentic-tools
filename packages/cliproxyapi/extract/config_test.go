// cspell:ignore fset
// Copied into a copy of CLIProxyAPI's internal/config by lib/extracted's
// goTestExtract; it is not part of CLIProxyAPI. In-package, so it reads the v8
// layout from CPA's own tables (v8Paths, v8StructPaths, v8KeyFamilies,
// sharedKeyFields, v8AllowedRoots) instead of restating them. The node type
// vocabulary, field walk and output come from
// lib/extracted/go/nat_shared_test.go.
//
// TestNatExtract writes the v8 configuration tree to $NAT_EXTRACT_OUT: one
// node per path, typed by reflect over the runtime structs, described by the
// field's Go doc comment and by the comment config.example.yaml carries at
// the same v8 path.
//
// Path grammar: `.` between keys, `[]` for a list element, `.<name>` for a
// map value.
package config

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

const natModule = "github.com/router-for-me/CLIProxyAPI/v8/"

type natNode struct {
	Description string `json:"description,omitempty"`
	Template    string `json:"template,omitempty"`
	Type        string `json:"type"`
}

var (
	natDuration    = reflect.TypeOf(time.Duration(0))
	natUnmarshaler = reflect.TypeOf((*yaml.Unmarshaler)(nil)).Elem()
	natYAML        = natCodec{tag: "yaml", untagged: strings.ToLower}
	natYAMLNode    = reflect.TypeOf(yaml.Node{})
)

type natExtractor struct {
	active map[reflect.Type]bool
	docs   map[string]map[string]string
	nodes  map[string]natNode
	t      *testing.T
}

// The Go doc comment of field `name` of struct `owner`, parsed from the
// owner's package source on first use.
func (x *natExtractor) doc(owner reflect.Type, name string) string {
	pkg := owner.PkgPath()
	if !strings.HasPrefix(pkg, natModule) {
		return ""
	}
	docs, ok := x.docs[pkg]
	if !ok {
		docs = map[string]string{}
		dir := filepath.Join("..", "..", strings.TrimPrefix(pkg, natModule))
		entries, err := os.ReadDir(dir)
		if err != nil {
			x.t.Fatalf("read %s: %v", dir, err)
		}
		fset := token.NewFileSet()
		for _, entry := range entries {
			if !strings.HasSuffix(entry.Name(), ".go") || strings.HasSuffix(entry.Name(), "_test.go") {
				continue
			}
			file, err := parser.ParseFile(fset, filepath.Join(dir, entry.Name()), nil, parser.ParseComments)
			if err != nil {
				x.t.Fatalf("parse %s: %v", entry.Name(), err)
			}
			for _, decl := range file.Decls {
				gen, ok := decl.(*ast.GenDecl)
				if !ok || gen.Tok != token.TYPE {
					continue
				}
				for _, spec := range gen.Specs {
					typeSpec := spec.(*ast.TypeSpec)
					structType, ok := typeSpec.Type.(*ast.StructType)
					if !ok {
						continue
					}
					for _, field := range structType.Fields.List {
						text := field.Doc.Text()
						if text == "" {
							text = field.Comment.Text()
						}
						for _, ident := range field.Names {
							docs[typeSpec.Name.Name+"."+ident.Name] = strings.TrimSpace(text)
						}
					}
				}
			}
		}
		x.docs[pkg] = docs
	}
	return docs[owner.Name()+"."+name]
}

// A custom YAML decoder's node type is measured through yaml.v3, CPA's
// decoding library. Try `true` then `[]` until one succeeds: accepting a
// non-mapping makes the type `any`. PluginInstanceConfig
// (plugins.configs.<name>) keeps any YAML subtree, and
// DisableImageGenerationMode (multimedia.disable-image-generation) reads `true`.
// If both reject, require `{}` to succeed before walk publishes `object`
// with reflected children; otherwise extraction fails. The empty mapping
// avoids inventing valid values for tagged fields such as durations.
// CredentialConcurrencyConfig (credentials.concurrency) and
// CodexLiveMediaRelayConfig (oauth.providers.codex.live-media-relay) first
// decode ordinary structs, which reject both non-mappings and accept `{}`.
var natNonMappings = []string{"true", "[]"}

func natDecodes(t reflect.Type, probe string) bool {
	return yaml.Unmarshal([]byte(probe), reflect.New(t).Interface()) == nil
}

// A YAML-decoded Go type as a node type.
func (x *natExtractor) kind(t reflect.Type, path string) string {
	if t == natDuration {
		return "duration"
	}
	if t == natYAMLNode {
		return "any"
	}
	if t.Implements(natUnmarshaler) || reflect.PointerTo(t).Implements(natUnmarshaler) {
		for _, probe := range natNonMappings {
			if natDecodes(t, probe) {
				return "any"
			}
		}
		if !natDecodes(t, "{}") {
			x.t.Fatalf("%s: Go type %s rejects YAML mapping probe {}", path, t)
		}
		return "object"
	}
	kind, ok := natKind(t)
	if !ok {
		x.t.Fatalf("%s: no node type for Go type %s", path, t)
	}
	return kind
}

// Two structs may flatten into one v8 mapping (`claude` and its
// `claude-code` both land on upstream.claude); their descriptions join. Two
// leaves on one path are an extraction error.
func (x *natExtractor) emit(path string, node natNode) {
	old, ok := x.nodes[path]
	if ok && old != node {
		if old.Type != "object" || node.Type != "object" {
			x.t.Fatalf("%s: two fields map here: %+v and %+v", path, old, node)
		}
		node.Description = strings.TrimSpace(old.Description + "\n\n" + node.Description)
	}
	x.nodes[path] = node
}

// Emits `path` and every node below it. `skip` drops direct fields of an
// object at `path` by tag. A struct whose custom decoder makes it `any` keeps
// its reflected fields as children.
func (x *natExtractor) walk(t reflect.Type, path, doc string, emit func(string, natNode), skip func(string) bool) {
	t = natDeref(t)
	kind := x.kind(t, path)
	if path != "" {
		emit(path, natNode{Description: doc, Type: kind})
	}
	switch {
	case kind == "list":
		x.walk(t.Elem(), path+"[]", "", emit, nil)
	case kind == "map":
		x.walk(t.Elem(), path+".<name>", "", emit, nil)
	case t.Kind() == reflect.Struct && t != natYAMLNode:
		if x.active[t] {
			x.t.Fatalf("%s: recursive type %s", path, t)
		}
		x.active[t] = true
		natFields(t, natYAML, func(tag string, field reflect.StructField, owner reflect.Type) {
			if skip == nil || !skip(tag) {
				x.walk(field.Type, natJoin(path, tag), x.doc(owner, field.Name), emit, nil)
			}
		})
		delete(x.active, t)
	}
}

// The v8 path of a legacy path, as flattenV8 reads it back: a relocated
// field's prefix is rewritten, a field already at its v8 path keeps it, and
// a field under a root v8 does not accept is dropped.
func natV8(legacy string) (string, bool) {
	for _, path := range v8Paths {
		if legacy == path.old || strings.HasPrefix(legacy, path.old+".") || strings.HasPrefix(legacy, path.old+"[") {
			return path.current + strings.TrimPrefix(legacy, path.old), true
		}
	}
	for _, path := range v8StructPaths {
		if legacy == path.old {
			return path.current, true
		}
	}
	root := strings.FieldsFunc(legacy, func(r rune) bool { return r == '.' || r == '[' })[0]
	return legacy, v8AllowedRoots()[root]
}

// An upstream key family: v8 lists groups that carry `name`, `base-url` and
// the shared key fields, each holding `keys` (expandV8Groups).
// openai-compatibility keeps its own group struct and lists its
// `api-key-entries` as `keys`. Neither layout reads `auth-index`.
func (x *natExtractor) family(field reflect.StructField, owner reflect.Type, current string) {
	base := "api-keys." + current
	elem := natDeref(field.Type.Elem())
	authIndex := func(tag string) bool { return tag == "auth-index" || tag == "auth_index" }
	x.emit(base, natNode{Description: x.doc(owner, field.Name), Type: "list"})
	x.emit(base+"[]", natNode{Type: "object"})
	if current == "openai-compatibility" {
		x.walk(elem, base+"[]", "", func(path string, node natNode) {
			if path != base+"[]" {
				x.emit(path, node)
			}
		}, func(tag string) bool { return tag == "api-key-entries" || authIndex(tag) })
		entries, ok := elem.FieldByName("APIKeyEntries")
		if !ok || strings.Split(entries.Tag.Get("yaml"), ",")[0] != "api-key-entries" {
			x.t.Fatalf("%s: no api-key-entries field", base)
		}
		x.emit(base+"[].keys", natNode{Description: x.doc(elem, entries.Name), Type: "list"})
		x.walk(natDeref(entries.Type.Elem()), base+"[].keys[]", "", x.emit, authIndex)
		return
	}
	x.emit(base+"[].keys", natNode{Type: "list"})
	x.emit(base+"[].keys[]", natNode{Type: "object"})
	x.emit(base+"[].name", natNode{Type: "string"})
	natFields(elem, natYAML, func(tag string, keyField reflect.StructField, keyOwner reflect.Type) {
		if authIndex(tag) {
			return
		}
		doc := x.doc(keyOwner, keyField.Name)
		if tag != "base-url" {
			x.walk(keyField.Type, base+"[].keys[]."+tag, doc, x.emit, nil)
		}
		if tag == "base-url" || sharedKeyFields[tag] {
			x.walk(keyField.Type, base+"[]."+tag, doc, x.emit, nil)
		}
	})
}

// The parent of a path and the type that parent must have.
func natParent(path string) (string, string, bool) {
	if strings.HasSuffix(path, "[]") {
		return strings.TrimSuffix(path, "[]"), "list", true
	}
	i := strings.LastIndex(path, ".")
	if i < 0 {
		return "", "", false
	}
	if path[i+1:] == "<name>" {
		return path[:i], "map", true
	}
	return path[:i], "object", true
}

// v8 nests relocated fields under sections no Go struct declares (server,
// access, upstream, ...); each such section is an object node.
func (x *natExtractor) ancestors() {
	paths := make([]string, 0, len(x.nodes))
	for path := range x.nodes {
		paths = append(paths, path)
	}
	for _, path := range paths {
		for parent, kind, ok := natParent(path); ok; parent, kind, ok = natParent(parent) {
			if _, exists := x.nodes[parent]; !exists {
				x.nodes[parent] = natNode{Type: kind}
			}
		}
	}
}

// Whether `path` sits below an `any` node, whose contents are not measured.
func (x *natExtractor) opaque(path string) bool {
	for parent, _, ok := natParent(path); ok; parent, _, ok = natParent(parent) {
		if x.nodes[parent].Type == "any" {
			return true
		}
	}
	return false
}

// The comment config.example.yaml carries above or beside each key it sets,
// by the key's v8 path. Unreflected scalar roots accepted by v8 come from
// this canonical template (config-version is boundary metadata, not a Config
// field). Commented-out examples are not keys and carry none. Any other key
// the template sets without a node is a missed path.
func (x *natExtractor) template(node *yaml.Node, path string) {
	switch node.Kind {
	case yaml.DocumentNode:
		for _, child := range node.Content {
			x.template(child, path)
		}
	case yaml.SequenceNode:
		for _, child := range node.Content {
			x.template(child, path+"[]")
		}
	case yaml.MappingNode:
		for i := 0; i+1 < len(node.Content); i += 2 {
			key := node.Content[i].Value
			if parent, ok := x.nodes[path]; ok && parent.Type == "map" {
				key = "<name>"
			}
			child := natJoin(path, key)
			value := node.Content[i+1]
			if _, exists := x.nodes[child]; !exists && path == "" && v8AllowedRoots()[key] && value.Kind == yaml.ScalarNode {
				var decoded any
				if err := value.Decode(&decoded); err != nil {
					x.t.Fatal(err)
				}
				x.emit(child, natNode{Type: x.kind(reflect.TypeOf(decoded), child)})
			}
			if _, exists := x.nodes[child]; !exists && !x.opaque(child) {
				x.t.Fatalf("%s: config.example.yaml sets a key with no node", child)
			}
			text := natComment(node.Content[i].HeadComment, node.Content[i].LineComment, node.Content[i+1].LineComment)
			if existing, ok := x.nodes[child]; ok && text != "" && existing.Template == "" {
				existing.Template = text
				x.nodes[child] = existing
			}
			x.template(node.Content[i+1], child)
		}
	}
}

// A commented-out YAML line (`key: value`, `- item`) in the template: an
// example, not prose.
var natYAMLLine = regexp.MustCompile(`^(- |[a-z0-9][a-z0-9_-]*:( |$))`)

// The last paragraph of a key's comments, without the `#` markers or
// commented-out YAML.
func natComment(parts ...string) string {
	var lines []string
	for _, part := range parts {
		if part == "" {
			continue
		}
		for _, line := range strings.Split(part, "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				lines = nil
				continue
			}
			line = strings.TrimSpace(strings.TrimPrefix(line, "#"))
			if !natYAMLLine.MatchString(line) {
				lines = append(lines, line)
			}
		}
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func TestNatExtract(t *testing.T) {
	x := &natExtractor{active: map[reflect.Type]bool{}, docs: map[string]map[string]string{}, nodes: map[string]natNode{}, t: t}
	families := map[string]string{}
	for _, family := range v8KeyFamilies {
		families[family.old] = family.current
	}
	config := reflect.TypeOf(Config{})
	natFields(config, natYAML, func(tag string, field reflect.StructField, owner reflect.Type) {
		if current, ok := families[tag]; ok {
			x.family(field, owner, current)
			delete(families, tag)
			return
		}
		x.walk(field.Type, tag, x.doc(owner, field.Name), func(legacy string, node natNode) {
			if path, ok := natV8(legacy); ok {
				x.emit(path, node)
			}
		}, nil)
	})
	for old := range families {
		t.Fatalf("key family %s has no Config field", old)
	}
	for _, path := range v8Paths {
		if _, ok := x.nodes[path.current]; !ok {
			t.Fatalf("v8 path %s (from %s) was not extracted", path.current, path.old)
		}
	}
	example, err := os.ReadFile(filepath.Join("..", "..", "config.example.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var document yaml.Node
	if err := yaml.Unmarshal(example, &document); err != nil {
		t.Fatal(err)
	}
	x.ancestors()
	x.template(&document, "")
	catalog, err := os.ReadFile(filepath.Join("..", "registry", "models", "models.json"))
	if err != nil {
		t.Fatal(err)
	}
	var models map[string]any
	if err := json.Unmarshal(catalog, &models); err != nil {
		t.Fatal(err)
	}
	natWrite(t, map[string]any{"config": x.nodes, "models": models})
}
