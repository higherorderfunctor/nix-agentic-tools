// Shared by every Go owner's extractor test (`goTestExtract` in
// ../default.nix). The extractor copies this file next to the owner's test
// and replaces the placeholder package clause below with the owner test's
// own, so both compile into the package they read. It is never compiled here.
//
// It holds what every Go owner's facts share: the node type vocabulary, the
// field walk over a codec's struct tags and the raw's output.
package nat

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

// How a codec names struct fields: the tag key it reads, and the key an
// untagged field takes.
type natCodec struct {
	tag      string
	untagged func(name string) string
}

// The node type of a Go type its codec decodes by kind. An owner types
// custom decoders and codec-specific types (a YAML duration string) before
// asking; false means the vocabulary has no type for it.
func natKind(t reflect.Type) (string, bool) {
	switch t.Kind() {
	case reflect.Struct:
		return "object", true
	case reflect.Interface:
		return "any", true
	case reflect.Bool:
		return "bool", true
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64,
		reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return "int", true
	case reflect.Float32, reflect.Float64:
		return "number", true
	case reflect.String:
		return "string", true
	case reflect.Array, reflect.Slice:
		return "list", true
	case reflect.Map:
		if t.Key().Kind() == reflect.String {
			return "map", true
		}
	}
	return "", false
}

func natDeref(t reflect.Type) reflect.Type {
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	return t
}

func natJoin(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

// Visits the fields of struct `t` the codec reads, inlining anonymous ones,
// with the struct that declares each field (for its doc comment).
func natFields(t reflect.Type, codec natCodec, visit func(key string, field reflect.StructField, owner reflect.Type)) {
	for i := 0; i < t.NumField(); i++ {
		field := t.Field(i)
		key := strings.Split(field.Tag.Get(codec.tag), ",")[0]
		if key == "-" || field.PkgPath != "" {
			continue
		}
		if field.Anonymous {
			natFields(field.Type, codec, visit)
			continue
		}
		if key == "" {
			key = codec.untagged(field.Name)
		}
		visit(key, field, t)
	}
}

// Writes the owner's raw, an object of surfaces, to $NAT_EXTRACT_OUT.
func natWrite(t *testing.T, raw map[string]any) {
	out, err := json.MarshalIndent(raw, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("NAT_EXTRACT_OUT"), out, 0o644); err != nil {
		t.Fatal(err)
	}
}
