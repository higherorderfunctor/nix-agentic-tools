// CPA source contracts for the gate. Copied into internal/config in both the
// offline flake check and CPA's package check phase; never reads credentials.
package config

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/scanner"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Ignore comments and layout, including implicit semicolons, while preserving
// literal bytes. The AST chooses nodes; tokens give stable reviewable spellings.
func natGateTokens(src []byte) string {
	var s scanner.Scanner
	s.Init(token.NewFileSet().AddFile("", -1, len(src)), src, nil, 0)
	var out strings.Builder
	for {
		_, tok, lit := s.Scan()
		if tok == token.EOF {
			break
		}
		if tok == token.SEMICOLON && lit == "\n" {
			continue
		}
		if lit == "" {
			lit = tok.String()
		}
		out.WriteString(lit)
	}
	return out.String()
}

func natGateInventory(root string) ([]string, error) {
	var rows []string
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if entry.Name() == "vendor" || entry.Name() == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		positions := token.NewFileSet()
		file, err := parser.ParseFile(positions, path, src, 0)
		if err != nil {
			return err
		}
		text := func(node ast.Node) string {
			return natGateTokens(src[positions.Position(node.Pos()).Offset:positions.Position(node.End()).Offset])
		}
		add := func(kind, owner, value string) { rows = append(rows, kind+" "+rel+" "+owner+" "+value) }
		ast.Inspect(file, func(node ast.Node) bool {
			decl, ok := node.(*ast.GenDecl)
			if ok {
				for _, node := range decl.Specs {
					spec, ok := node.(*ast.ValueSpec)
					if !ok {
						continue
					}
					for _, name := range spec.Names {
						if name.Name == "claudeDDModelPrefix" {
							add("prefix", name.Name, decl.Tok.String()+" "+text(spec))
						}
					}
				}
			}
			return true
		})
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			owner := fn.Name.Name
			if fn.Recv != nil {
				owner = text(fn.Recv) + "." + owner
			}
			pin := rel == "internal/access/config_access/provider.go" && fn.Name.Name == "Authenticate"
			pin = pin || fn.Name.Name == "resolveClaudeWirePolicy" || fn.Name.Name == "applyCloakingInternal"
			pin = pin || fn.Name.Name == "ensureImageGenerationTool" || fn.Name.Name == "ensureWebSearchToolForHistory"
			ast.Inspect(fn.Body, func(node ast.Node) bool {
				if stmt, ok := node.(*ast.AssignStmt); ok && rel == "internal/api/server_routes.go" {
					for _, expr := range stmt.Rhs {
						if call, ok := expr.(*ast.CallExpr); ok {
							if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel.Name == "Group" {
								add("route", owner, text(stmt))
							}
						}
					}
				}
				call, ok := node.(*ast.CallExpr)
				if !ok {
					return true
				}
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok && len(call.Args) > 0 {
					method := sel.Sel.Name
					if rel == "internal/api/server_routes.go" && (method == "GET" || method == "HEAD" || method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE" || method == "OPTIONS" || method == "Any" || method == "Handle") {
						add("route", owner, text(call.Fun)+"("+text(call.Args[0])+")")
					}
					if rel == "internal/access/config_access/provider.go" && fn.Name.Name == "Authenticate" && method == "Get" {
						add("carrier", owner, text(call))
					}
					// Source-wide SetRawBytes calls whose path expression names tools.
					// Executors additionally pin setters of model/fallbacks/tools, including
					// computed paths (format strings and concatenation), without guessing
					// which values will be identity at runtime.
					if len(call.Args) >= 3 {
						key := text(call.Args[1])
						relevant := strings.Contains(key, "tools") && method == "SetRawBytes"
						executor := strings.HasPrefix(rel, "internal/runtime/executor/")
						setter := method == "SetBytes" || method == "SetRawBytes" || strings.HasPrefix(method, "SetString")
						relevant = relevant || executor && setter && (strings.Contains(key, "model") || strings.Contains(key, "fallbacks") || strings.Contains(key, "tools"))
						if relevant {
							add("write", owner, text(call))
						}
						if executor && setter && strings.Contains(key, "fallbacks") {
							pin = true
						}
					}
				}
				if id, ok := call.Fun.(*ast.Ident); ok && (id.Name == "ensureImageGenerationTool" || id.Name == "ensureWebSearchToolForHistory") {
					add("tool", owner, text(call))
					pin = true // Includes the enclosing DisableImageGenerationOff condition.
				}
				return true
			})
			if pin {
				add("guard", owner, fmt.Sprintf("sha256:% x", sha256.Sum256([]byte(text(fn)))))
			}
		}
		return nil
	})
	sort.Strings(rows)
	return rows, err
}

func natGateDrift(expected, actual []string) string {
	counts := map[string]int{}
	for _, row := range expected {
		counts[row]--
	}
	for _, row := range actual {
		counts[row]++
	}
	var changes []string
	for row, count := range counts {
		if count != 0 {
			// Keep the change summary compact; the full inventory follows it.
			parts := strings.SplitN(row, " ", 4)
			if len(parts) == 4 && (parts[0] == "write" || parts[0] == "prefix") {
				row = strings.Join(parts[:3], " ") + fmt.Sprintf(" sha256:%x", sha256.Sum256([]byte(parts[3])))
			}
			changes = append(changes, fmt.Sprintf("%+d %s", count, row))
		}
	}
	sort.Strings(changes)
	return strings.Join(changes, "\n")
}

// The current pin and mutation controls use the same production failure.
func natGateFailure(drift string, actual []string) string {
	if drift == "" {
		return ""
	}
	var golden strings.Builder
	encoder := json.NewEncoder(&golden)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(actual); err != nil {
		panic(err)
	}
	return "CPA bump changes gate source contracts; review CPA source and gate coverage before updating packages/cliproxyapi/checks/fixtures/gate-bump-golden.json. After review, replace that file with the complete JSON between BEGIN/END lines (including its final newline); extracted-facts regeneration does not update this golden:\n" + drift +
		"\nBEGIN CPA GATE GOLDEN JSON\n" + golden.String() + "END CPA GATE GOLDEN JSON\n"
}

func TestNatGateBump(t *testing.T) {
	raw, err := os.ReadFile("nat_gate_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var expected []string
	if err := json.Unmarshal(raw, &expected); err != nil {
		t.Fatal(err)
	}
	actual, err := natGateInventory(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	if len(expected) == 0 || len(actual) == 0 {
		t.Fatal("empty CPA gate inventory")
	}
	if failure := natGateFailure(natGateDrift(expected, actual), actual); failure != "" {
		// Print directly so testing.T does not indent the fixture bytes.
		fmt.Print(failure)
		t.FailNow()
	}
	t.Logf("CPA gate golden: %d source contracts verified", len(actual))
}

// Fixtures exercise the same parser and comparison used on the current pin.
// Each added source node must fail with a diagnostic naming its new input.
func TestNatGateBumpControls(t *testing.T) {
	for _, probe := range []struct{ kind, path, before, after, name string }{
		{"route", "internal/api/server_routes.go", `package api; func routes(){ v1.GET("/models", handler) }`, `package api; func routes(){ v1.GET("/models", handler); v1.POST("/new-route", handler) }`, "new-route"},
		{"carrier", "internal/access/config_access/provider.go", `package configaccess; func Authenticate(){ r.Header.Get("Authorization") }`, `package configaccess; func Authenticate(){ r.Header.Get("Authorization"); r.Header.Get("X-New-Carrier") }`, "X-New-Carrier"},
		{"write", "internal/translator/new.go", `package translator; func existingToolWrite(){ sjson.SetRawBytes(body, "tools", existingTool) }`, `package translator; func existingToolWrite(){ sjson.SetRawBytes(body, "tools", existingTool) }; func newToolWrite(){ sjson.SetRawBytes(body, "tools", newHostedTool) }`, "newToolWrite"},
		{"prefix", "internal/client/claude/models/models.go", `package models; const claudeDDModelPrefix = "fixed-prefix-"`, `package models; var claudeDDModelPrefix = "fixed-prefix-"`, "claudeDDModelPrefix"},
	} {
		t.Run(probe.kind, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, filepath.FromSlash(probe.path))
			if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				t.Fatal(err)
			}
			inventory := func(source string) []string {
				t.Helper()
				if err := os.WriteFile(path, []byte(source), 0600); err != nil {
					t.Fatal(err)
				}
				rows, err := natGateInventory(root)
				if err != nil {
					t.Fatal(err)
				}
				return rows
			}
			before := inventory(probe.before)
			if len(before) == 0 {
				t.Fatal("empty acceptance control")
			}
			// Comments are inside selectors, function declarations and prefix specs.
			layout := strings.NewReplacer(".", " /* layout */ . ", "func ", "func /* layout */  ", " = ", " /* layout */ =  ").Replace(probe.before)
			layoutInventory := inventory(layout)
			if failure := natGateFailure(natGateDrift(before, layoutInventory), layoutInventory); failure != "" {
				t.Fatalf("comments or layout changed source contracts: %s", failure)
			}
			actual := inventory(probe.after)
			failure := natGateFailure(natGateDrift(before, actual), actual)
			for _, required := range []string{
				"review CPA source and gate coverage before updating",
				"packages/cliproxyapi/checks/fixtures/gate-bump-golden.json",
				probe.kind+" "+probe.path, probe.name,
			} {
				if !strings.Contains(failure, required) {
					t.Fatalf("refusal lacks %q: %s", required, failure)
				}
			}
			_, block, found := strings.Cut(failure, "\nBEGIN CPA GATE GOLDEN JSON\n")
			if !found {
				t.Fatal("refusal lacks golden JSON begin line")
			}
			block, suffix, found := strings.Cut(block, "END CPA GATE GOLDEN JSON\n")
			if !found || suffix != "" || !strings.HasSuffix(block, "\n") {
				t.Fatal("refusal lacks golden JSON end line or final newline")
			}
			var emitted []string
			if err := json.Unmarshal([]byte(block), &emitted); err != nil {
				t.Fatalf("refusal golden JSON: %v", err)
			}
			if len(emitted) != len(actual) || natGateDrift(actual, emitted) != "" || !sort.StringsAreSorted(emitted) {
				t.Fatal("refusal golden JSON differs from complete canonical inventory")
			}
			t.Log("refused new " + probe.kind + ": " + probe.name)
		})
	}
}
