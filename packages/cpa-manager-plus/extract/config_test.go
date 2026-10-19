// cspell:ignore fset
// Copied into a copy of CPA Manager Plus's apps/manager-server/internal/config
// by lib/extracted's goTestExtract; it is not part of CPA Manager Plus. In-package, so it
// reflects the unexported fileConfig, the shape config.json decodes into. The
// node type vocabulary, field walk and output come from
// lib/extracted/go/nat_shared_test.go.
//
// TestNatExtract writes two surfaces to $NAT_EXTRACT_OUT:
//
//   - config: one node per config.json path, typed by reflect over
//     fileConfig. Path grammar: `.` between keys, `[]` for a list element,
//     `.<name>` for a map value.
//   - environment: one node per environment variable the module's code reads,
//     found with go/ast, described by the operations guide's table.
package config

import (
	"encoding"
	"encoding/json"
	"go/ast"
	"go/build"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

type natNode struct {
	Type string `json:"type"`
}

type natVariable struct {
	ConfigKeys  []string `json:"configKeys,omitempty"`
	Description string   `json:"description,omitempty"`
	ReadBy      []string `json:"readBy"`
	Type        string   `json:"type"`
}

var (
	natJSON = natCodec{tag: "json", untagged: func(name string) string { return name }}
	// A type decoding itself would need a probe like CLIProxyAPI's; none does.
	natDecoders = []reflect.Type{
		reflect.TypeOf((*json.Unmarshaler)(nil)).Elem(),
		reflect.TypeOf((*encoding.TextUnmarshaler)(nil)).Elem(),
	}
)

func natConfig(t *testing.T, nodes map[string]natNode, typ reflect.Type, path string) {
	typ = natDeref(typ)
	for _, decoder := range natDecoders {
		if typ.Implements(decoder) || reflect.PointerTo(typ).Implements(decoder) {
			t.Fatalf("%s: Go type %s has a custom JSON decoder, which is not measured", path, typ)
		}
	}
	kind, ok := natKind(typ)
	if !ok {
		t.Fatalf("%s: no node type for Go type %s", path, typ)
	}
	if path != "" {
		nodes[path] = natNode{Type: kind}
	}
	switch kind {
	case "list":
		natConfig(t, nodes, typ.Elem(), path+"[]")
	case "map":
		natConfig(t, nodes, typ.Elem(), path+".<name>")
	case "object":
		natFields(typ, natJSON, func(key string, field reflect.StructField, _ reflect.Type) {
			natConfig(t, nodes, field.Type, natJoin(path, key))
		})
	}
}

// One package of the module: its name, functions and package-level
// constants; `self` is this test's package, which declares fileConfig.
// Methods are keyed `Receiver.Name`, which no plain call names.
type natPackage struct {
	consts map[string]*ast.ValueSpec
	funcs  map[string]*ast.FuncDecl
	name   string
	self   bool
}

// A function of a package; `forwards` holds the indexes of the parameters it
// reads as environment variable names, itself or through another forwarder.
type natFunc struct {
	decl     *ast.FuncDecl
	forwards map[int]bool
	name     string
	pkg      *natPackage
}

func (f *natFunc) qualified() string { return f.pkg.name + "." + f.name }

func natFuncName(decl *ast.FuncDecl) string {
	if decl.Recv == nil {
		return decl.Name.Name
	}
	receiver := decl.Recv.List[0].Type
	if star, ok := receiver.(*ast.StarExpr); ok {
		receiver = star.X
	}
	if index, ok := receiver.(*ast.IndexExpr); ok {
		receiver = index.X
	}
	return receiver.(*ast.Ident).Name + "." + decl.Name.Name
}

// The module's non-test Go files this platform builds, by package directory.
func natParse(t *testing.T, root string) []*natPackage {
	self, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err = filepath.Abs(root)
	if err != nil {
		t.Fatal(err)
	}
	byDir := map[string]*natPackage{}
	var dirs []string
	fset := token.NewFileSet()
	err = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if entry.Name() == "vendor" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		if match, err := build.Default.MatchFile(filepath.Dir(path), entry.Name()); err != nil || !match {
			return err
		}
		file, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return err
		}
		dir := filepath.Dir(path)
		pkg, ok := byDir[dir]
		if !ok {
			pkg = &natPackage{consts: map[string]*ast.ValueSpec{}, funcs: map[string]*ast.FuncDecl{}, name: file.Name.Name, self: dir == self}
			byDir[dir] = pkg
			dirs = append(dirs, dir)
		}
		for _, decl := range file.Decls {
			switch decl := decl.(type) {
			case *ast.FuncDecl:
				pkg.funcs[natFuncName(decl)] = decl
			case *ast.GenDecl:
				if decl.Tok != token.CONST {
					continue
				}
				for _, spec := range decl.Specs {
					for _, name := range spec.(*ast.ValueSpec).Names {
						pkg.consts[name.Name] = spec.(*ast.ValueSpec)
					}
				}
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(dirs)
	packages := make([]*natPackage, 0, len(dirs))
	for _, dir := range dirs {
		packages = append(packages, byDir[dir])
	}
	return packages
}

// The string a constant expression names: a literal, or a constant declared
// in the file or the package.
func natConstant(pkg *natPackage, expr ast.Expr) (string, bool) {
	switch expr := expr.(type) {
	case *ast.BasicLit:
		if expr.Kind == token.STRING {
			value, err := strconv.Unquote(expr.Value)
			return value, err == nil
		}
	case *ast.Ident:
		spec := pkg.consts[expr.Name]
		if expr.Obj != nil {
			spec, _ = expr.Obj.Decl.(*ast.ValueSpec)
			if expr.Obj.Kind != ast.Con {
				spec = nil
			}
		}
		if spec == nil {
			return "", false
		}
		for i, name := range spec.Names {
			if name.Name == expr.Name && i < len(spec.Values) {
				return natConstant(pkg, spec.Values[i])
			}
		}
	}
	return "", false
}

// The index of the parameter `expr` names in `decl`, or -1.
func natParameter(decl *ast.FuncDecl, expr ast.Expr) int {
	ident, ok := expr.(*ast.Ident)
	if !ok {
		return -1
	}
	index := 0
	for _, field := range decl.Type.Params.List {
		for _, name := range field.Names {
			if name.Name == ident.Name {
				return index
			}
			index++
		}
	}
	return -1
}

func natIsOS(call *ast.CallExpr) bool {
	selector, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	pkg, ok := selector.X.(*ast.Ident)
	return ok && pkg.Name == "os" && (selector.Sel.Name == "Getenv" || selector.Sel.Name == "LookupEnv" || selector.Sel.Name == "Environ")
}

// The positions of `call`'s arguments that name environment variables: 0
// for os.Getenv and os.LookupEnv, a forwarder's forwarded parameters.
func natKeyArgs(funcs map[*natPackage]map[string]*natFunc, pkg *natPackage, call *ast.CallExpr) (map[int]bool, *natFunc) {
	if natIsOS(call) {
		return map[int]bool{0: true}, nil
	}
	ident, ok := call.Fun.(*ast.Ident)
	if !ok {
		return nil, nil
	}
	callee, ok := funcs[pkg][ident.Name]
	if !ok || len(callee.forwards) == 0 {
		return nil, nil
	}
	return callee.forwards, callee
}

// The config.json keys an expression in the config package derives from:
// fileConfig fields it selects, directly or through a local variable of
// `decl` assigned from them.
func natConfigKeys(decl *ast.FuncDecl, fields map[string]string, expr ast.Expr, expand bool, keys map[string]bool) {
	ast.Inspect(expr, func(node ast.Node) bool {
		switch node := node.(type) {
		case *ast.SelectorExpr:
			if key, ok := fields[node.Sel.Name]; ok {
				keys[key] = true
			}
		case *ast.Ident:
			if !expand || node.Obj == nil || node.Obj.Kind != ast.Var {
				return true
			}
			ast.Inspect(decl.Body, func(inner ast.Node) bool {
				assign, ok := inner.(*ast.AssignStmt)
				if !ok {
					return true
				}
				for i, lhs := range assign.Lhs {
					if ident, ok := lhs.(*ast.Ident); ok && ident.Obj == node.Obj && len(assign.Rhs) == len(assign.Lhs) {
						natConfigKeys(decl, fields, assign.Rhs[i], false, keys)
					}
				}
				return true
			})
		}
		return true
	})
}

// Every call in `decl`'s body.
func natCalls(decl *ast.FuncDecl, visit func(call *ast.CallExpr)) {
	if decl.Body == nil {
		return
	}
	ast.Inspect(decl.Body, func(node ast.Node) bool {
		if call, ok := node.(*ast.CallExpr); ok {
			visit(call)
		}
		return true
	})
}

// The operations guide's environment table: variable name to description.
var natRow = regexp.MustCompile("^\\| `([A-Z0-9_]+)` +\\|[^|]*\\| (.*?) +\\|$")

func natGuide(t *testing.T, path string) map[string]string {
	text, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	rows := map[string]string{}
	inside := false
	for _, line := range strings.Split(string(text), "\n") {
		if strings.HasPrefix(line, "## ") {
			inside = line == "## Environment Variables"
			continue
		}
		if match := natRow.FindStringSubmatch(line); inside && match != nil {
			rows[match[1]] = match[2]
		}
	}
	if len(rows) == 0 {
		t.Fatalf("%s: no environment table rows", path)
	}
	return rows
}

func natEnvironment(t *testing.T, packages []*natPackage, fields map[string]string) map[string]*natVariable {
	funcs := map[*natPackage]map[string]*natFunc{}
	for _, pkg := range packages {
		funcs[pkg] = map[string]*natFunc{}
		for name, decl := range pkg.funcs {
			funcs[pkg][name] = &natFunc{decl: decl, forwards: map[int]bool{}, name: name, pkg: pkg}
		}
	}
	// Forwarders, to a fixpoint: a function passing its parameter where an
	// environment variable name goes forwards that parameter.
	for changed := true; changed; {
		changed = false
		for _, pkg := range packages {
			for _, f := range funcs[pkg] {
				natCalls(f.decl, func(call *ast.CallExpr) {
					keys, _ := natKeyArgs(funcs, pkg, call)
					for index := range keys {
						if index >= len(call.Args) {
							continue
						}
						if param := natParameter(f.decl, call.Args[index]); param >= 0 && !f.forwards[param] {
							f.forwards[param] = true
							changed = true
						}
					}
				})
			}
		}
	}
	variables := map[string]*natVariable{}
	for _, pkg := range packages {
		for _, f := range funcs[pkg] {
			natCalls(f.decl, func(call *ast.CallExpr) {
				keys, callee := natKeyArgs(funcs, pkg, call)
				if natIsOS(call) && call.Fun.(*ast.SelectorExpr).Sel.Name == "Environ" {
					t.Fatalf("%s reads the whole environment; its names are not measured", f.qualified())
				}
				for index := range keys {
					if index >= len(call.Args) || natParameter(f.decl, call.Args[index]) >= 0 {
						continue
					}
					name, ok := natConstant(pkg, call.Args[index])
					if !ok {
						t.Fatalf("%s: environment variable name is not a constant", f.qualified())
					}
					variable, ok := variables[name]
					if !ok {
						variable = &natVariable{Type: "string"}
						variables[name] = variable
					}
					reader := f
					if callee != nil {
						reader = callee
					}
					variable.ReadBy = append(variable.ReadBy, reader.qualified())
					if !pkg.self {
						continue
					}
					// What the read falls back to: a forwarder call's other
					// arguments, or what callers pass the reading function.
					configKeys := map[string]bool{}
					if callee != nil {
						for i, arg := range call.Args {
							if !keys[i] {
								natConfigKeys(f.decl, fields, arg, true, configKeys)
							}
						}
					} else {
						for _, caller := range funcs[pkg] {
							natCalls(caller.decl, func(site *ast.CallExpr) {
								if ident, ok := site.Fun.(*ast.Ident); ok && ident.Name == f.name {
									for _, arg := range site.Args {
										natConfigKeys(caller.decl, fields, arg, true, configKeys)
									}
								}
							})
						}
					}
					for key := range configKeys {
						variable.ConfigKeys = append(variable.ConfigKeys, key)
					}
				}
			})
		}
	}
	for _, variable := range variables {
		variable.ConfigKeys = natSorted(variable.ConfigKeys)
		variable.ReadBy = natSorted(variable.ReadBy)
	}
	return variables
}

func natSorted(values []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, value := range values {
		if !seen[value] {
			seen[value] = true
			out = append(out, value)
		}
	}
	sort.Strings(out)
	return out
}

func TestNatExtract(t *testing.T) {
	config := map[string]natNode{}
	natConfig(t, config, reflect.TypeOf(fileConfig{}), "")
	fields := map[string]string{}
	natFields(reflect.TypeOf(fileConfig{}), natJSON, func(key string, field reflect.StructField, _ reflect.Type) {
		fields[field.Name] = key
	})
	environment := natEnvironment(t, natParse(t, filepath.Join("..", "..")), fields)
	guide := filepath.Join("..", "..", "..", "docs", "en", "operations", "manager-server.md")
	for name, description := range natGuide(t, guide) {
		variable, ok := environment[name]
		if !ok {
			t.Fatalf("%s: the operations guide documents %s, which no code reads", guide, name)
		}
		variable.Description = description
	}
	natWrite(t, map[string]any{"config": config, "environment": environment})
}
