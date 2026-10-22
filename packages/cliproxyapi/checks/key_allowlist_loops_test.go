// Joined into the patched sdk/cliproxy/auth package by
// checks/cliproxyapi-key-allowlist.nix. The allowlist lives in
// authSelectionEligibility.allows, so a candidate loop that never calls it
// selects outside the allowlist. The signature change in
// patches/key-allowlist.patch catches new calls to the eligibility
// constructor only. This test fails on a range statement over the
// Manager.auths field whose own body calls no allowlist predicate, in a
// function or in a closure, each judged on its own. It sees nothing else (see
// keyAllowlistLoopsWithoutAllows), so a CPA bump that touches candidate
// selection still needs a reviewer. It reads the AST with go/types rather
// than grepping, because a loop is recognized by what it ranges over (the
// field, under any receiver name) and a call by its receiver's type.
package auth

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Functions that range over the credential pool without an allowlist
// predicate, each with the reason it does not choose a request's credential.
// An entry added here needs that reason, checked against the bump's source.
var keyAllowlistLoopExemptions = map[string]string{
	"Manager.AvailableProviders":            "lists provider names, chooses no credential",
	"Manager.ForceRefreshAll":               "refreshes tokens for every credential, serves no request",
	"Manager.HasProviderAuth":               "reports whether a provider has any credential, chooses none",
	"Manager.List":                          "returns copies of the pool; a caller that selects from them is outside this check",
	"Manager.LookupSessionAffinity":         "observes a binding for the plugin host's affinity callback; the instance module refuses plugins beside the allowlist",
	"Manager.RefreshSchedulerAll":           "re-syncs scheduler entries; in 8.0.38 every scheduler pick entry point builds its predicate with scheduledAuthPredicate (scheduler.go:426,487,494); re-check on bump",
	"Manager.RegisterExecutor":              "reschedules refreshes for an executor's credentials",
	"Manager.clearDisabledCooldownStates":   "clears cooldown state on config reload",
	"Manager.cooldownStateRecordsSnapshot":  "snapshots cooldown state for persistence",
	"Manager.rebuildAPIKeyModelAliasLocked": "rebuilds model alias tables on config reload",
	"Manager.requestRetryRoundExclusions":   "returns IDs to exclude; it only narrows a selection that still runs allows",
	"Manager.snapshotAuths":                 "copies the pool for scheduler rebuilds; in 8.0.38 every scheduler pick entry point builds its predicate with scheduledAuthPredicate (scheduler.go:426,487,494); re-check on bump",
	"authAutoRefreshLoop.rebuild":           "schedules background token refreshes, serves no request",
}

// A filtered loop cannot hide a second bare loop or one in its closure.
const keyAllowlistBypassFixture = `package auth
func (m *Manager) keyAllowlistBypass(eligibility authSelectionEligibility) *Auth {
	for _, auth := range m.auths {
		if !eligibility.allows(auth) {
			continue
		}
		return auth
	}
	for _, auth := range m.auths {
		return auth
	}
	return nil
}
func (m *Manager) keyAllowlistBypassClosure(eligibility authSelectionEligibility) func() *Auth {
	for _, auth := range m.auths {
		if !eligibility.allows(auth) {
			return nil
		}
	}
	return func() *Auth {
		for _, auth := range m.auths {
			return auth
		}
		return nil
	}
}
`

// keyAllowlistLoopsWithoutAllows type-checks the package from source and
// returns every unit holding a range statement over the Manager's credential
// pool (Manager.auths) whose own body calls no allowlist predicate:
// authSelectionEligibility.allows, or clientKeyAllowlist.allows where a path
// applies the allowlist alone. A unit is a function, named Receiver.name, or a
// closure, named after its parent plus .funcN in source order; a closure's
// calls do not count for its parent's loops, nor the parent's for the
// closure's. Imports resolve to empty packages and type errors are ignored,
// since every type it needs is declared here.
//
// Not seen: an indexed lookup (m.auths[id]), an alias of the map, the map
// passed to a helper, a loop over a copy (snapshotAuths, List), and the
// scheduler's own pools and pickers, which match every entry on a nil
// predicate. In 8.0.38 none of these chooses a request's credential outside
// allows; that is a review obligation on each bump, not something this test
// checks.
func keyAllowlistLoopsWithoutAllows(t *testing.T, fixture bool) []string {
	t.Helper()
	fileSet := token.NewFileSet()
	var files []*ast.File
	paths, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fileSet, path, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, file)
	}
	if fixture {
		file, err := parser.ParseFile(fileSet, "zz_bypass_fixture.go", keyAllowlistBypassFixture, 0)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, file)
	}
	info := &types.Info{Types: map[ast.Expr]types.TypeAndValue{}, Uses: map[*ast.Ident]types.Object{}}
	config := types.Config{Error: func(error) {}, Importer: emptyImporter{}}
	pkg, _ := config.Check("auth", fileSet, files, info)
	lookup := func(name string) types.Object {
		object := pkg.Scope().Lookup(name)
		if object == nil {
			t.Fatalf("%s is no longer declared in sdk/cliproxy/auth; re-derive this check", name)
		}
		return object
	}
	predicates := map[types.Object]bool{lookup("authSelectionEligibility"): true, lookup("clientKeyAllowlist"): true}
	var pool types.Object
	if manager, ok := lookup("Manager").Type().Underlying().(*types.Struct); ok {
		for i := 0; i < manager.NumFields(); i++ {
			if manager.Field(i).Name() == "auths" {
				pool = manager.Field(i)
			}
		}
	}
	if pool == nil {
		t.Fatal("Manager.auths is no longer the credential pool; re-derive this check")
	}
	rangesPool := func(expr ast.Expr) (found bool) {
		ast.Inspect(expr, func(node ast.Node) bool {
			if ident, ok := node.(*ast.Ident); ok && info.Uses[ident] == pool {
				found = true
			}
			return !found
		})
		return found
	}
	isPredicate := func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return false
		}
		selector, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || selector.Sel.Name != "allows" {
			return false
		}
		receiver := info.TypeOf(selector.X)
		if pointer, ok := receiver.(*types.Pointer); ok {
			receiver = pointer.Elem()
		}
		named, ok := receiver.(*types.Named)
		return ok && predicates[named.Obj()]
	}
	callsPredicate := func(body ast.Node) (found bool) {
		ast.Inspect(body, func(node ast.Node) bool {
			if _, ok := node.(*ast.FuncLit); ok {
				return false
			}
			found = found || isPredicate(node)
			return !found
		})
		return found
	}
	var found []string
	var scan func(name string, unit ast.Node)
	scan = func(name string, unit ast.Node) {
		closures, bare := 0, false
		ast.Inspect(unit, func(node ast.Node) bool {
			switch node := node.(type) {
			case *ast.FuncLit:
				closures++
				scan(fmt.Sprintf("%s.func%d", name, closures), node.Body)
				return false
			case *ast.RangeStmt:
				if rangesPool(node.X) && !callsPredicate(node.Body) {
					bare = true
				}
			}
			return true
		})
		if bare {
			found = append(found, name)
		}
	}
	for _, file := range files {
		for _, decl := range file.Decls {
			function, ok := decl.(*ast.FuncDecl)
			if !ok {
				// Package-level closures, named after their file.
				scan(fileSet.File(decl.Pos()).Name(), decl)
				continue
			}
			if function.Body == nil {
				continue
			}
			name := function.Name.Name
			if function.Recv != nil && len(function.Recv.List) == 1 {
				receiver := function.Recv.List[0].Type
				if star, ok := receiver.(*ast.StarExpr); ok {
					receiver = star.X
				}
				if ident, ok := receiver.(*ast.Ident); ok {
					name = ident.Name + "." + name
				}
			}
			scan(name, function.Body)
		}
	}
	sort.Strings(found)
	return found
}

type emptyImporter struct{}

func (emptyImporter) Import(path string) (*types.Package, error) {
	if path == "unsafe" {
		return types.Unsafe, nil
	}
	pkg := types.NewPackage(path, filepath.Base(path))
	pkg.MarkComplete()
	return pkg, nil
}

func TestKeyAllowlistCandidateLoopsCallAllows(t *testing.T) {
	var flagged []string
	for _, name := range keyAllowlistLoopsWithoutAllows(t, true) {
		if strings.HasPrefix(name, "Manager.keyAllowlistBypass") {
			flagged = append(flagged, name)
		}
	}
	want := "Manager.keyAllowlistBypass Manager.keyAllowlistBypassClosure.func1"
	if got := strings.Join(flagged, " "); got != want {
		t.Fatalf("bare candidate loops flagged: got %q, want %q", got, want)
	}

	present := map[string]bool{}
	for _, name := range keyAllowlistLoopsWithoutAllows(t, false) {
		present[name] = true
		if _, ok := keyAllowlistLoopExemptions[name]; !ok {
			t.Errorf("%s has a loop over Manager.auths whose body calls no allowlist predicate: filter that loop through authSelectionEligibility.allows, or exempt the unit in keyAllowlistLoopExemptions with the reason it does not choose a request's credential", name)
		}
	}
	for name := range keyAllowlistLoopExemptions {
		if !present[name] {
			t.Errorf("exemption %s no longer matches a loop; delete it", name)
		}
	}
}
