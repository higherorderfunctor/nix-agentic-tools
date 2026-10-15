// cspell:ignore cliproxy coreauth Elts fset
// Copied into a copy of CLIProxyAPI's internal/watcher/synthesizer by
// ./default.nix; it is not part of CLIProxyAPI.
//
// TestNatAccounts writes to $NAT_EXTRACT_OUT the top-level fields CPA reads
// from an OAuth auth file. It follows the calls from synthesizeFileAuths
// through this package and sdk/cliproxy/auth, and records every read of the
// file's metadata map (`metadata[...]`, `<auth>.Metadata[...]`): the key, the
// Go types the read asserts, and the legacy spellings that
// CanonicalCredentialMetadataKey folds into it. A read whose key it cannot
// resolve fails the test, so a new read shape surfaces here, not as a field
// that silently goes missing.
package synthesizer

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	coreauth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

type natAccountField struct {
	Aliases []string `json:"aliases,omitempty"`
	// The Go type the reads assert, when they agree on exactly one.
	Type *string `json:"type"`
	// Every Go type any read asserts.
	Types []string `json:"types"`
}

type natPackage struct {
	consts map[string]string
	funcs  map[string]*ast.FuncDecl
	// Import path -> local name, per file of each function.
	imports map[*ast.FuncDecl]map[string]string
}

const natAuthPath = "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"

func natParse(t *testing.T, dir string) natPackage {
	pkg := natPackage{consts: map[string]string{}, funcs: map[string]*ast.FuncDecl{}, imports: map[*ast.FuncDecl]map[string]string{}}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".go") || strings.HasSuffix(entry.Name(), "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, filepath.Join(dir, entry.Name()), nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		imports := map[string]string{}
		for _, spec := range file.Imports {
			path, _ := strconv.Unquote(spec.Path.Value)
			name := path[strings.LastIndex(path, "/")+1:]
			if spec.Name != nil {
				name = spec.Name.Name
			}
			imports[path] = name
		}
		for _, decl := range file.Decls {
			switch decl := decl.(type) {
			case *ast.FuncDecl:
				if decl.Recv == nil {
					pkg.funcs[decl.Name.Name] = decl
					pkg.imports[decl] = imports
				}
			case *ast.GenDecl:
				if decl.Tok != token.CONST {
					continue
				}
				for _, spec := range decl.Specs {
					value := spec.(*ast.ValueSpec)
					for i, name := range value.Names {
						if i < len(value.Values) {
							if lit, ok := value.Values[i].(*ast.BasicLit); ok && lit.Kind == token.STRING {
								pkg.consts[name.Name], _ = strconv.Unquote(lit.Value)
							}
						}
					}
				}
			}
		}
	}
	return pkg
}

// The file's metadata map: an identifier `metadata` or a `.Metadata`
// selector.
func natIsMetadata(expr ast.Expr) bool {
	switch expr := expr.(type) {
	case *ast.Ident:
		return expr.Name == "metadata"
	case *ast.SelectorExpr:
		return expr.Sel.Name == "Metadata"
	}
	return false
}

func TestNatAccounts(t *testing.T) {
	packages := map[string]natPackage{
		"auth":        natParse(t, filepath.Join("..", "..", "..", "sdk", "cliproxy", "auth")),
		"synthesizer": natParse(t, "."),
	}
	fields := map[string]map[string]bool{}
	read := func(key, goType string) {
		if fields[key] == nil {
			fields[key] = map[string]bool{}
		}
		if goType != "" {
			fields[key][goType] = true
		}
	}
	type call struct{ pkg, name string }
	seen := map[call]bool{}
	queue := []call{{"synthesizer", "synthesizeFileAuths"}}
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		if seen[current] {
			continue
		}
		seen[current] = true
		pkg := packages[current.pkg]
		fn := pkg.funcs[current.name]
		authName := pkg.imports[fn][natAuthPath]
		// Keys bound by `for _, k := range []string{...}`, and variables
		// assigned straight from a metadata read.
		rangeKeys := map[string][]string{}
		dynamic := map[string]bool{}
		bound := map[string]string{}
		written := map[*ast.IndexExpr]bool{}
		ast.Inspect(fn.Body, func(node ast.Node) bool {
			switch node := node.(type) {
			case *ast.RangeStmt:
				value, ok := node.Value.(*ast.Ident)
				if lit, isLit := node.X.(*ast.CompositeLit); ok && isLit {
					for _, element := range lit.Elts {
						if basic, ok := element.(*ast.BasicLit); ok && basic.Kind == token.STRING {
							key, _ := strconv.Unquote(basic.Value)
							rangeKeys[value.Name] = append(rangeKeys[value.Name], key)
						}
					}
				}
				// `for key := range metadata` walks the whole map, as
				// NormalizeCredentialMetadata does; no field is named, by the
				// key or by anything the loop derives from it.
				if key, ok := node.Key.(*ast.Ident); ok && natIsMetadata(node.X) {
					dynamic[key.Name] = true
					ast.Inspect(node.Body, func(inner ast.Node) bool {
						if assign, ok := inner.(*ast.AssignStmt); ok && assign.Tok == token.DEFINE {
							for _, lhs := range assign.Lhs {
								if ident, ok := lhs.(*ast.Ident); ok {
									dynamic[ident.Name] = true
								}
							}
						}
						return true
					})
				}
			case *ast.AssignStmt:
				for _, lhs := range node.Lhs {
					if index, ok := lhs.(*ast.IndexExpr); ok {
						written[index] = true
					}
				}
			}
			return true
		})
		keysOf := func(index *ast.IndexExpr) []string {
			switch key := index.Index.(type) {
			case *ast.BasicLit:
				value, _ := strconv.Unquote(key.Value)
				return []string{value}
			case *ast.Ident:
				if value, ok := pkg.consts[key.Name]; ok {
					return []string{value}
				}
				if values, ok := rangeKeys[key.Name]; ok {
					return values
				}
				if dynamic[key.Name] {
					return nil
				}
			case *ast.SelectorExpr:
				if x, ok := key.X.(*ast.Ident); ok && x.Name == authName {
					if value, ok := packages["auth"].consts[key.Sel.Name]; ok {
						return []string{value}
					}
				}
			}
			t.Fatalf("%s: metadata read with a key this extractor cannot resolve: %s", current.name, types.ExprString(index))
			return nil
		}
		metadataRead := func(expr ast.Expr) *ast.IndexExpr {
			index, ok := expr.(*ast.IndexExpr)
			if !ok || written[index] || !natIsMetadata(index.X) {
				return nil
			}
			return index
		}
		ast.Inspect(fn.Body, func(node ast.Node) bool {
			switch node := node.(type) {
			case *ast.CallExpr:
				switch fun := node.Fun.(type) {
				case *ast.Ident:
					if _, ok := pkg.funcs[fun.Name]; ok {
						queue = append(queue, call{current.pkg, fun.Name})
					}
				case *ast.SelectorExpr:
					if x, ok := fun.X.(*ast.Ident); ok && x.Name == authName {
						queue = append(queue, call{"auth", fun.Sel.Name})
					}
				}
			case *ast.AssignStmt:
				// `v, ok := metadata["k"]`: later assertions on `v` type it.
				if len(node.Rhs) == 1 {
					if index := metadataRead(node.Rhs[0]); index != nil {
						if name, ok := node.Lhs[0].(*ast.Ident); ok {
							for _, key := range keysOf(index) {
								bound[name.Name] = key
							}
						}
					}
				}
			case *ast.TypeAssertExpr:
				if index := metadataRead(node.X); index != nil && node.Type != nil {
					for _, key := range keysOf(index) {
						read(key, types.ExprString(node.Type))
					}
				}
			case *ast.TypeSwitchStmt:
				var subject ast.Expr
				switch assign := node.Assign.(type) {
				case *ast.AssignStmt:
					subject = assign.Rhs[0].(*ast.TypeAssertExpr).X
				case *ast.ExprStmt:
					subject = assign.X.(*ast.TypeAssertExpr).X
				}
				var keys []string
				if ident, ok := subject.(*ast.Ident); ok && bound[ident.Name] != "" {
					keys = []string{bound[ident.Name]}
				} else if index := metadataRead(subject); index != nil {
					keys = keysOf(index)
				}
				for _, clause := range node.Body.List {
					for _, caseType := range clause.(*ast.CaseClause).List {
						for _, key := range keys {
							read(key, types.ExprString(caseType))
						}
					}
				}
			case *ast.IndexExpr:
				if index := metadataRead(node); index != nil {
					for _, key := range keysOf(index) {
						read(key, "")
					}
				}
			}
			return true
		})
		// Assertions on a bound variable: `raw.(string)` after `raw := metadata["k"]`.
		ast.Inspect(fn.Body, func(node ast.Node) bool {
			if assertion, ok := node.(*ast.TypeAssertExpr); ok && assertion.Type != nil {
				if ident, ok := assertion.X.(*ast.Ident); ok && bound[ident.Name] != "" {
					read(bound[ident.Name], types.ExprString(assertion.Type))
				}
			}
			return true
		})
	}
	out := map[string]*natAccountField{}
	for key, goTypes := range fields {
		canonical := coreauth.CanonicalCredentialMetadataKey(key)
		field := out[canonical]
		if field == nil {
			field = &natAccountField{Types: []string{}}
			out[canonical] = field
		}
		if canonical != key {
			field.Aliases = append(field.Aliases, key)
		}
		for goType := range goTypes {
			field.Types = append(field.Types, goType)
		}
	}
	for _, field := range out {
		sort.Strings(field.Aliases)
		sort.Strings(field.Types)
		field.Types = compactStrings(field.Types)
		if len(field.Types) == 1 {
			field.Type = &field.Types[0]
		}
	}
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("NAT_EXTRACT_OUT"), data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func compactStrings(values []string) []string {
	out := values[:0]
	for i, value := range values {
		if i == 0 || value != values[i-1] {
			out = append(out, value)
		}
	}
	return out
}
