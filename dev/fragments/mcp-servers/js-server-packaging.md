## JS MCP Server Packaging — npm-workspaces gotcha

> **Last verified:** 2026-05-20 (commit pending — follows the
> modelcontextprotocol per-workspace `node_modules/` fix). If you
> touch any overlay that builds a JS MCP server from an npm-workspaces
> monorepo and this fragment isn't updated in the same commit, stop
> and fix it.

### The non-hoisting trap

`npm install --workspaces` does not always hoist scope-shared deps to
the root `node_modules/`. When the upstream lockfile contains explicit
per-workspace entries:

```json
"src/sequentialthinking/node_modules/@modelcontextprotocol/sdk": { ... }
"src/filesystem/node_modules/@modelcontextprotocol/sdk":         { ... }
```

npm preserves that placement — the dep lives at
`src/<workspace>/node_modules/<dep>/`, NOT at root. A packager that
copies only the root `node_modules/` into the output ships an
incomplete dep tree. The binary loads and crashes on first import
with `Cannot find module '...'` at runtime — never at build time.

`@modelcontextprotocol/sdk` in `modelcontextprotocol/servers` is the
canonical example; check the lockfile before assuming hoisting.

### Pattern: merge per-workspace node_modules

In any `mkJsPackage`-style installPhase that copies a single workspace
out of a monorepo, copy BOTH the root and the per-workspace
`node_modules/`:

```nix
cp -r src/${subdir}/dist $out/lib/${pname}/
cp -r node_modules       $out/lib/${pname}/
# Upstream lockfile may install some deps per-workspace at
# src/<workspace>/node_modules/ instead of hoisting to root.
# Merge them so node/bun resolution finds them at runtime.
if [ -d src/${subdir}/node_modules ]; then
  cp -r src/${subdir}/node_modules/. $out/lib/${pname}/node_modules/
fi
```

### Anti-pattern: timeout-and-discard smoke tests

NEVER write smoke tests of the form:

```nix
# WRONG — masks every import-time crash
timeout N "$bin" < /dev/null 2>&1 || true
```

`|| true` swallows the exit code. bun and node servers crash on
import in milliseconds, well inside the timeout, so the test passes
even when the binary is fundamentally broken. This is how the
`Cannot find module '@modelcontextprotocol/sdk/server/mcp.js'`
regression shipped for sequential-thinking-mcp / filesystem-mcp /
memory-mcp before being caught by manual user testing.

### Pattern: MCP initialize handshake smoke test

Exchange a real MCP `initialize` over stdio and assert a JSON-RPC
`result`:

```nix
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
for bin in $out/bin/*; do
  name=$(basename "$bin")
  out=$(printf '%s\n' "$init" | timeout 10 "$bin" 2>&1 || true)
  case "$out" in
    *"Cannot find module"*|*ModuleNotFoundError*|*ImportError*)
      echo "smoke-test FAIL: $name import error" >&2
      exit 1 ;;
  esac
  if [[ "$out" == *'"jsonrpc"'* && "$out" == *'"result"'* ]]; then
    echo "smoke-test: $name handshake OK"
  else
    echo "smoke-test FAIL: $name no init response" >&2
    exit 1
  fi
done
```

Key detail: JS MCP servers serialize `"result"` before `"jsonrpc"` in
key order; Python servers serialize them in canonical order. Check
both substrings independently — never as an ordered sequence
(`*'"jsonrpc"'*'"result"'*`), which silently rejects working JS
servers.

### Debugging entry points

If a JS MCP server fails with `Cannot find module 'X'`:

1. Grep the upstream `package-lock.json` for
   `"src/*/node_modules/<dep>"`. Multiple matches → npm did not
   hoist; the installPhase must merge per-workspace `node_modules/`.
2. Inspect the built output:
   `ls $out/lib/<pname>/node_modules/@scope/`. An empty scope
   directory is the canonical signature of the bug — the cleanup
   loop removed the workspace-source symlinks but nothing replaced
   them with the actual deps.
3. Reproduce upstream layout: `npm ci --workspaces --ignore-scripts`
   on a fresh checkout, then
   `find node_modules -maxdepth 2 -type l -exec sh -c 'printf "%s -> %s\n" "$1" "$(readlink "$1")"' _ {} \;`.
   Workspace-source symlinks at root point to `../../src/<ws>`;
   they are correctly dangling after we trim to one workspace, but
   the per-workspace deps under `src/<ws>/node_modules/` are real
   directories and must be copied.
