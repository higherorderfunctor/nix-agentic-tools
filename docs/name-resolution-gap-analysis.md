# Name-resolution gap analysis

> **Status:** read-only enumeration to inform slice-nav design.
> No code changes proposed in this doc — see `monorepo-restructure-assessment.md`
> §11 for the slice-nav plan and `docs/plan.md` for active backlog.
>
> **Scope:** every place in the repo that takes a name (package name,
> input name, slice name, etc.) and resolves it to a file or content
> via string-search, hardcoded list, central registry, or filesystem
> convention. Catalogues each smell, scores merge-up suitability,
> flags whether slice-nav naturally addresses it.
>
> **Origin:** investigation of PR #91 (kiro-gateway / `update-pkg.sh`
> grep collision) suggested the bug class extends beyond one script.
> User asked: do a tight gap analysis before slice-nav so the pilot
> can absorb everything in one design pass.

## TL;DR — by the numbers

- **14 smell sites** identified.
- **8 high-suitability for merge-up** — slice owns the data, shared infra reads merged namespace.
- **3 medium-suitability** — could merge-up but cost/benefit marginal.
- **3 low-suitability** — explicit-static-list is genuinely the right shape.
- **9 of 14** would be naturally subsumed by the slice-nav move; **5** are independent.

Two cross-cutting observations land at the bottom (§ "Patterns" and § "Risks").

## Sites

### 1. `update-pkg.sh:34-35` — substring grep for target overlay file

```bash
repo_name=$(echo "$git_url" | sed 's|\.git$||' | grep -oP '[^/]+$')
target_file=$(grep -rl "$repo_name" "$wt/overlays" --include='*.nix' | head -1)
```

**What it does:** given a git URL from `update-matrix.nix`, finds which overlay file to sed against by grepping for the URL's basename and picking alphabetical-first hit.

**Bug surface:** any URL whose trailing repo-name appears as a substring in another `.nix` file (PR #91: `servers.git` → `agnix.nix`'s `# git-tools or mcp-servers groupings.` comment matched first).

**Merge-up suitability:** **HIGH.** Each slice (or each per-package dir under it) declares its own update target via `config.update.targets.<name> = { file = ./X.nix; git = "..."; }`. Script reads `nix eval --json .#updateTargets.<name>` — no grep, no matrix.

**Slice-nav addresses naturally:** **YES.** Once the overlay file is co-located with the slice, `./X.nix` is intrinsic to the slice's own declaration.

**Severity:** active bug, broken PRs landing in main.

---

### 2. `config/update-matrix.nix` — central registry decoupled from files

```nix
modelcontextprotocol-all-mcps = {
  flags = "--version skip";
  git = "https://github.com/modelcontextprotocol/servers.git";
};
```

**What it does:** single source of truth for "which packages get updated, with what flags, optionally tracking which upstream HEAD." Declares `excludePatterns` (regex names skipped from auto-update). The file lives separately from the packages themselves.

**Bug surface:** matrix and overlay can drift (matrix knows the package by name, overlay file by directory). When a file moves, matrix must be updated. When a new package lands, two places must be edited.

**Merge-up suitability:** **HIGH.** Slice (or package within slice) declares `config.update.targets.<name> = { … }`. Matrix dissolves.

**Slice-nav addresses naturally:** **YES.** The whole file becomes redundant once each slice owns its update declaration.

**Severity:** structural smell; root of #1.

---

### 3. `generate-update-ninja.nix:38` — hardcoded Rust package list

```nix
rustDeps =
  if builtins.elem name ["agnix" "git-absorb" "git-branchless"]
  then ["update-rust-overlay"]
  else [];
```

**What it does:** identifies which packages need `update-rust-overlay` as a ninja DAG predecessor (because their build needs the rust-overlay input updated first).

**Bug surface:** add a Rust package, forget to update this list, ninja DAG misses a dep edge.

**Merge-up suitability:** **HIGH.** Slice-local `config.update.targets.<name>.dependsOn = ["rust-overlay"];` declaration reads cleaner. Generator merges declared deps from all slices.

**Slice-nav addresses naturally:** **YES** (when paired with site #1's merge-up, this falls out for free).

**Severity:** silent-foot-gun — same class as #1 but only triggers when adding new Rust pkg.

---

### 4. `overlays/default.nix` — explicit per-package import list

```nix
flatDrvs = {
  agnix = import ./agnix.nix { inherit inputs final; };
  claude-code = import ./claude-code.nix { inherit inputs final; };
  …
};
mcpServerDrvs = { … };
gitToolDrvs = { … };
```

**What it does:** the unified overlay that composes 25+ package files into grouped namespaces (`pkgs.ai.*`, `pkgs.ai.mcpServers.*`, `pkgs.gitTools.*`).

**Bug surface:** none active. Adding a package means adding a line here. Hand-maintained list is symmetric with the file system.

**Merge-up suitability:** **MEDIUM.** Could be `readDir` over slice dirs, but explicit-list is honest about ordering and inclusion. Slice-nav §11 keeps the combined-merge published surface — this composition still happens, just from slice files instead of flat overlay files.

**Slice-nav addresses naturally:** **YES** — this file dissolves into per-slice composition that aggregates up to `flake.nix`.

**Severity:** clean today, structural target for slice-nav.

---

### 5. `lib/mcp.nix:22` — convention-based name→file dispatch

```nix
loadServer = name: import ../packages/${name}/modules/mcp-server.nix {inherit lib mcpLib;};
```

**What it does:** given an MCP server name, imports the per-package typed-settings module by filesystem convention.

**Bug surface:** the convention path is hard-baked in `lib/`. After slice-nav (e.g., `slices/mcp-servers/<name>/modules/mcp-server.nix`), this path is wrong. §8 of `monorepo-restructure-assessment.md` already flags this as "Move `lib/mcp.nix:22` inverted dep to a module-system registry."

**Merge-up suitability:** **HIGH.** Each MCP package contributes `config.mcp.serverModules.<name> = ./modules/mcp-server.nix;` (or the module-eval result). `loadServer` reads from the merged namespace. Decouples server declarations from a centralized convention.

**Slice-nav addresses naturally:** **YES** — but ONLY if the merge-up replacement is designed alongside. A naive lift-and-shift to `slices/mcp-servers/<name>/...` just changes the convention path.

**Severity:** latent. Will break loudly when slice-nav moves files.

---

### 6. `dev/data.nix` — repo-wide description registry

```nix
mcpServerMeta = {
  context7-mcp = { description = "Library documentation lookup"; credentials = "None"; };
  …
};
aiCliDescriptions = { … };
gitToolDescriptions = { … };
skillDescriptions = { … };
```

**What it does:** per-name human-readable metadata (descriptions, credential requirements). Consumed by README/CONTRIBUTING/docsite generation.

**Bug surface:** drifts away from the package. Adding a package means editing this file separately. Removing a package means remembering to remove the entry here too.

**Merge-up suitability:** **HIGH.** Each package contributes its own description via `passthru.userDescription` or a dedicated `config.docs.descriptions.<name>` option. Generators iterate the merged set.

**Slice-nav addresses naturally:** **PARTIALLY.** Slice-nav moves files but doesn't directly touch the data registry. But once slices exist, putting per-slice data into the slice is the natural follow-up — bigger lift than just file-moves but the architectural seam is the same.

**Severity:** structural smell, no active bug. Long-term DRY win.

---

### 7. `dev/generate.nix:89` — `packagePaths` glob registry

```nix
packagePaths = {
  ai-clis = [ "packages/ai-clis/**" "packages/copilot-cli/**" "packages/kiro-cli/**" ];
  ai-module = [ "lib/ai/sharedOptions.nix" … ];
  …
};
```

**What it does:** name→path-globs for fragment scoping (which paths trigger loading a given AI rule fragment). Plus `devFragmentNames` which dispatches a name + location key (`"dev"|"package"|"devshell"`) to a markdown file path.

**Bug surface:** category and globs lookup decoupled from the slice that actually owns them. Adding a new slice category means editing this file.

**Merge-up suitability:** **HIGH.** Each slice contributes `config.fragments.scopes.<category> = [ "slices/<name>/**" ];` and `config.fragments.<category>.<fragmentName> = { file = ./fragments/<name>.md; };`. Generator iterates merged scopes.

**Slice-nav addresses naturally:** **YES** with merge-up design. Without merge-up, slice-nav just changes the path strings inside this file.

**Severity:** active churn — every time a fragment moves, this file gets touched. PR-review noise.

---

### 8. `checks/cache-hit-parity.nix:61-120` — three hardcoded package lists

```nix
aiCliPackages = [ "claude-code" "copilot-cli" "kiro-cli" "kiro-gateway" ];
gitToolPackages = [ "git-absorb" "git-branchless" "git-revise" ];
mcpServerPackages = [ "context7-mcp" "effect-mcp" … ];
agnixPackages = [ { name = "agnix"; consumerLookup = p: p.ai.agnix; } … ];
specialPackages = [ { name = "modelcontextprotocol-all-mcps"; consumerLookup = …; } ];
```

**What it does:** check evaluates every overlay package twice (once with each nixpkgs pin) and asserts byte-identical output. Lists must be maintained as packages are added/removed.

**Bug surface:** add a package, forget to add it here, parity drift goes undetected.

**Merge-up suitability:** **HIGH.** Each slice contributes `config.checks.cacheHitParity.<name> = { consumerLookup = …; };`. Check iterates merged set.

**Slice-nav addresses naturally:** **YES** — slice-nav §11.3 explicitly keeps cross-slice checks at repo root reading from merged namespaces. This is the canonical use case.

**Severity:** silent foot-gun. The whole point of the check is to catch drift, but the LIST itself is a drift source.

---

### 9. `flake.nix:391-396` — manual flatten of grouped namespaces

```nix
// builtins.removeAttrs pkgs.ai.mcpServers ["modelContextProtocol"]
// pkgs.ai.lspServers
// pkgs.gitTools
// {
  modelcontextprotocol-all-mcps = pkgs.ai.mcpServers.modelContextProtocol.all-mcps;
  …
}
```

**What it does:** flattens grouped overlay namespaces into top-level `packages.<system>.<name>` for CLI ergonomics (`nix build .#agnix` instead of `.#ai.agnix`).

**Bug surface:** add/rename a sub-namespace, forget to flatten, package no longer reachable from CLI. The `modelcontextprotocol-all-mcps` rename is hand-maintained.

**Merge-up suitability:** **MEDIUM.** Could be `lib.foldl' (acc: ns: acc // pkgs.${ns}) {} groupedNs` — but the special-case mapping (`modelcontextprotocol-all-mcps`) is genuinely a renaming policy that lives somewhere.

**Slice-nav addresses naturally:** **PARTIALLY.** Slice-nav cleans up the `pkgs.ai.<group>.<name>` shape but the flatten-to-top-level decision is a flake.nix concern. Could be replaced by a small registry in flake.nix.

**Severity:** low-friction; rare touch.

---

### 10. `checks/bare-commands.nix:32` — hardcoded scan-scope glob

```bash
for d in lib packages/*/lib; do
  if [ -d "$d" ]; then
    SCAN_DIRS="$SCAN_DIRS $d"
  fi
done
```

**What it does:** the bare-commands lint scopes to `lib/` and `packages/*/lib/`. Slice-nav would change paths to `slices/*/lib/` or similar.

**Bug surface:** path-coupled to current layout. Slice-nav move would silently break the check until updated.

**Merge-up suitability:** **LOW.** The check scope IS conceptually "wherever wrapper-emitting code lives." A merge-up would over-engineer this — better to update the glob when slice-nav lands.

**Slice-nav addresses naturally:** **YES** but mechanically (just path changes), not architecturally.

**Severity:** trivial. One-line glob update at slice-nav time.

---

### 11. `update-matrix.nix` — `excludePatterns` regex registry

```nix
excludePatterns = [
  "^instructions-" "^docs" "^agnix-lsp$" "^agnix-mcp$" "^nixos-mcp$" "^serena-mcp$"
];
```

**What it does:** packages whose names match these patterns are excluded from the update loop. Regex names live separately from the packages themselves.

**Bug surface:** the package's "I'm not auto-updatable" property lives here, not on the package.

**Merge-up suitability:** **MEDIUM.** Each excluded package could carry `passthru.autoUpdate = false;` (or contribute to `config.update.exclude`). Cleaner ownership but minor.

**Slice-nav addresses naturally:** **YES** if merge-up done alongside. Marginal benefit.

**Severity:** structural smell, no active bug.

---

### 12. `update-pkg.sh:80-104` — magic-comment parser

```bash
markers=$(awk '
  match($0, /# upstream: ([A-Za-z]+) @ (.+)$/, arr) { … }
' "$target_file")
```

**What it does:** parses `# upstream: readPackageJsonVersion @ packages/foo/package.json` magic comments inside overlay files; uses the kind+manifest to re-derive version literals at update time. Trade-off accepted in commit `f277053` to eliminate eval-time IFD.

**Bug surface:** comment format drift, line-window heuristic (5-line lookahead). Brittle to overlay author conventions.

**Merge-up suitability:** **HIGH.** Each package declares `config.update.versionDerivers.<name> = [{ kind = "readPackageJsonVersion"; manifest = "package.json"; replaces = "sub-package-foo"; }]`. Update script reads from merged set. No comment-parsing.

**Slice-nav addresses naturally:** **YES** — the modelcontextprotocol/default.nix file with 7 sub-package version markers is the worst offender; co-locating it inside its slice and converting to a typed declaration would clean this up.

**Severity:** working today but fragile. A comment-format drift would silently fail (no rebuild because version unchanged → no error → wrong version stays).

---

### 13. `update-pkg.sh:38-51` — regex-based rev/hash sed

```bash
old_rev=$(grep -oP 'rev = "\K[a-f0-9]{40}' "$target_file" | head -1 || true)
sed -i "s|$old_rev|$new_rev|g" "$target_file"
old_hash=$(grep -oP 'hash = "\Ksha256-[^"]+' "$target_file" | head -1 || true)
sed -i "s|$old_hash|$new_hash|" "$target_file"
```

**What it does:** finds first `rev = "<sha40>"` and first `hash = "sha256-..."` in the overlay file, replaces them. Works because each overlay has exactly one `fetchFromGitHub`.

**Bug surface:** any overlay with multiple `rev =` literals (e.g., a future overlay vendoring two repos) silently picks first hit. Same `head -1` fragility as #1, just at line level instead of file level.

**Merge-up suitability:** **HIGH** if sidecar-JSON pattern (option 4 in earlier discussion). Each package reads `<name>-source.json` containing `{rev, hash}`; updater writes JSON, no sed.

**Slice-nav addresses naturally:** **NO** directly — this is a within-file pattern, slice-nav doesn't change file contents. But slice-nav makes the sidecar-JSON pattern more attractive (sidecar lives next to the file in the slice dir).

**Severity:** latent foot-gun for any future multi-source overlay.

---

### 14. `*-sources.json` sidecars — proof of concept for slice-owned data

```
overlays/claude-code-sources.json
overlays/copilot-cli-sources.json
overlays/kiro-cli-sources.json
```

**What it does:** per-platform binary packages (claude-code, copilot-cli, kiro-cli) externalize version + per-platform `{url, hash}` to a JSON file. `mkUpdateScript` (in `overlays/lib.nix`) automates updates without hand-editing the `.nix` file.

**Bug surface:** none — this is the _good_ pattern. Updater writes JSON, no sed regex. Adding a new platform means adding a JSON entry.

**Merge-up suitability:** **N/A** — already follows the "package owns its data" pattern within the existing layout. Not a smell, a reference point.

**Slice-nav addresses naturally:** **YES** — these JSON files would move into their respective slices. Pattern stays.

**Severity:** none. Listed because it's the precedent for what a fix should look like.

---

## Patterns observed

**Pattern A — central registries decoupled from data.**
Sites #2 (update-matrix), #6 (data.nix), #7 (packagePaths), #8 (cache-hit-parity lists), #11 (excludePatterns).
All have the same shape: a flat top-level file listing per-package metadata that lives separately from the package.
**Slice-nav cure:** module-merge-up — each slice contributes its rows; central code reads merged set.

**Pattern B — convention-based name→file lookup.**
Sites #1 (update-pkg grep), #5 (loadServer convention path).
"Given a name, find the file via grep or hardcoded path template."
**Slice-nav cure:** slice declares its own files explicitly via the same merge-up namespace as A.

**Pattern C — within-file regex/comment parsing.**
Sites #12 (magic comments), #13 (rev/hash sed).
File-internal smell. Slice-nav doesn't directly fix; the cure is sidecar-JSON or typed declarations.

**Pattern D — explicit registries that are fine as-is.**
Sites #4 (overlays/default.nix), #9 (flake.nix flatten), #10 (bare-commands scope).
Hand-maintained but symmetric with the file system; no drift surface beyond "remember to add a line."

## Risks of doing this with slice-nav

1. **Two merge-up namespaces vs one.** The collision-refactor work shipped `lib.ai.<helper>` flat helpers + `ai.<surface>` per-CLI. Slice-nav adds `config.<concern>.<slice>` (transformer registry, update.targets, fragment scopes, etc.). These need a coherent naming policy — `monorepo-restructure-assessment.md` §10 already flags this question. **The gap analysis suggests there are ~5-7 distinct merge-up namespaces** (`update.targets`, `mcp.serverModules`, `fragments.scopes`, `docs.descriptions`, `checks.cacheHitParity`, possibly more). Designing them all together avoids a piecemeal proliferation.

2. **`agnix` and `modelcontextprotocol/` complications.** Both are multi-output single-source. The slice-nav §11.7 calls these out; they affect site #5 (multiple modules per source) and site #12 (multiple version markers per file). The pilot slice (kiro) doesn't exercise either. **Recommendation:** pick a pilot that DOES exercise multi-output — `mcp-servers/` slice would, but is the biggest. Or pilot kiro for transformer pattern, then slice 2 = `mcp-servers/` to validate multi-output + update-pipeline merge-up together.

3. **Pre-commit hook visibility.** Several sites (#7, #8, #11, #14) have pre-commit / CI checks that would change shape. Not strictly a risk but a place to remember during pilot — slice migration must update the cross-slice check expectations in lockstep.

4. **Eval cost of `nix eval --json` in update scripts.** Site #1's recommended fix calls `nix eval` per update target. Each eval is ~1-2s cold. With ~17 packages, that's a 30s overhead per pipeline run. Probably fine but worth measuring if updates start running on tight schedules.

5. **`dev/data.nix` is consumed by docsite generators (`fragments-docs`).** Site #6 cleanup interacts with the docsite pipeline (also flagged at `monorepo-restructure-assessment.md` §11.5 "leave for later review"). Lower-priority cleanup; can defer past slice-nav initial rollout.

## Coverage check vs original assessment

The assessment's §8 recommendations explicitly named:

- ✓ "Move overlay files into owning slice" — sites #1, #4, #14
- ✓ "Move `lib/mcp.nix:22` inverted dep to module-system registry" — site #5
- ✓ "Move sources.json sidecars to owning packages" — site #14

The assessment did **NOT** name:

- Sites #2, #11 (update-matrix dissolution + excludePatterns)
- Site #3 (Rust-package hardcoded list in ninja gen)
- Site #6 (data.nix merge-up)
- Site #7 (packagePaths registry)
- Site #8 (cache-hit-parity hardcoded lists)
- Site #9 (flake.nix flatten)
- Sites #12, #13 (within-file fragility)

This gap analysis adds **8 sites** the assessment didn't enumerate. None of them are surprises — they're all instances of the same "central registry vs slice-local declaration" tension the assessment names abstractly — but having the concrete list lets the pilot's merge-up namespace design absorb them in one pass.

## Suggested input to slice-nav pilot design

Three concrete asks for the pilot:

1. **Pilot slice should exercise both transformer-merge AND update-target-merge.** Kiro-only doesn't exercise update-target-merge (kiro-cli/kiro-gateway use `--use-update-script`, not `git`-URL Phase 0). Either pilot a slice that does (e.g., a thinner first slice carved from `mcp-servers/`) OR explicitly accept that the pilot proves transformer pattern only and update-target merge ships with slice 2.

2. **Design the merge-up namespace shape ONCE.** Sites #2, #5, #6, #7, #8, #11 all want a merge-up namespace. Picking a coherent shape (`config.slices.<name>.<concern>` vs `config.<concern>.<slice>` vs flat `lib.<concern>` with slice-keyed values) before the first slice lands prevents the second slice having to retrofit.

3. **Decide sidecar-JSON adoption explicitly.** Sites #12, #13, #14 collectively suggest extending the sidecar-JSON pattern (already used by binary three) to all main-tracking packages. This is independent of slice-nav but rides naturally with it. Worth deciding in the pilot whether to convert as we go OR defer entirely.

## What this analysis does NOT recommend

- **Fixing PR #91 today.** User confirmed not blocking, defer. Site #1 is the immediate bug; the right time to fix it is when slice-nav (or its update-pipeline merge-up) ships.
- **Closing `monorepo-restructure-assessment.md` open questions.** Those need user decisions, not more analysis.
- **A new top-level refactor doc.** This file is the artifact; next step is design conversation, then plan doc.

## Files cited

- `dev/scripts/update-pkg.sh` (sites 1, 12, 13)
- `dev/scripts/update-input.sh` (no smell — clean)
- `dev/scripts/update-common.sh` (no smell — clean)
- `config/update-matrix.nix` (sites 2, 11)
- `config/generate-update-ninja.nix` (site 3)
- `overlays/default.nix` (site 4)
- `overlays/*-sources.json` (site 14)
- `lib/mcp.nix` (site 5)
- `dev/data.nix` (site 6)
- `dev/generate.nix` (site 7)
- `checks/cache-hit-parity.nix` (site 8)
- `checks/bare-commands.nix` (site 10)
- `flake.nix` (site 9)
- `monorepo-restructure-assessment.md` §11 (slice-nav design — input)
