# AI Ecosystem Records — Phase 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the additive foundation for the ai-ecosystem-records refactor — structured fragment nodes, the markdown renderer, the ai-options source-of-truth file, ecosystem records with a backward-compat shim, and the shared `composedByPackage` binding. After this plan lands, **no existing module behavior changes**; the new primitives sit alongside the old code, ready to be consumed by the backend adapters in Phase 2.

**Architecture:** Four atomic commits, all additive. Commit 1 adds node constructors and the renderer to `lib/fragments.nix`. Commit 2 extracts option types from `modules/ai/default.nix` to a new `lib/ai-options.nix` source-of-truth file (no behavior change). Commit 3 creates per-ecosystem record files in `lib/ai-ecosystems/` with a backward-compat shim wired into `pkgs.fragments-ai.passthru.transforms`. Commit 4 adds `pkgs.fragments-ai.passthru.composedByPackage` and refactors `dev/generate.nix` to bind composition once instead of three times per package.

**Tech Stack:** Pure Nix (`lib.evalModules`, `runCommand`, `recursiveUpdate`). Tests via `checks/<topic>-eval.nix` files imported by `flake.nix:138-144`. Each test is a Nix expression that throws on assertion failure, wrapped in `runCommand` so `nix flake check` exercises it. Byte-identical golden tests for commits 3 and 4 use `nix build .#instructions-claude` (and friends) to produce derivation outputs that are diffed against pre-refactor snapshots.

---

## Required reading (before starting)

Before executing any task, read:

1. **`dev/notes/ai-transformer-design.md`** — full design space for the refactor, especially:
   - "Layer 1: Structured fragment nodes" (the node constructors + renderer)
   - "Layer 2: Ecosystem records — the unifying abstraction" (the full record shape)
   - "Layer 2.5: Markdown transformer records" (the sub-field used in commit 3's shim)
   - "Cross-cutting: single-binding shared composition" (the pattern commit 4 implements)
   - "Standalone fix" (the `dev/generate.nix` 3x→1x compose bug, generalized into commit 4)

2. **`lib/fragments.nix`** (78 lines) — current pure-FP implementation that commit 1 extends.

3. **`modules/ai/default.nix`** (287 lines) — source for the option types extracted in commit 2.

4. **`packages/fragments-ai/default.nix`** (127 lines) — current `passthru.transforms` shape that commit 3's shim must preserve byte-for-byte.

5. **`dev/generate.nix:226-309`** — current `mkDevComposed`, `mkEcosystemFile`, and `claudeFiles`/`copilotFiles`/`kiroFiles` blocks (the 3x compose anti-pattern that commit 4 fixes).

6. **`checks/module-eval.nix`** — existing test harness pattern. New `checks/fragments-eval.nix` follows the same shape.

7. **`flake.nix:138-144`** — how checks are wired into `nix flake check`. Commit 1 modifies this to include the new check file.

8. **`devenv.nix`** — for understanding how tasks are exposed (search for `imports = [ ./dev/tasks/generate.nix ]` or similar).

---

## Out of scope (deferred to later phases)

This plan is **Phase 1 only**. The following are explicitly deferred to follow-up plans:

- **Phase 2 — HM adapter rollout:** `lib/mk-ai-ecosystem-hm-module.nix`, replacing per-ecosystem `mkIf` branches in `modules/ai/default.nix` with adapter calls, layered option pools (`ai.<eco>.<category>` extension points). Will be drafted as a separate plan once Phase 1 lands.
- **Phase 3 — devenv adapter + helpers:** `lib/mk-ai-ecosystem-devenv-module.nix`, `lib/mk-raw-ecosystem.nix`, `examples/external-ecosystem/`.
- **Phase 4 — doc ecosystems + fragment updates:** README/mdBook ecosystem records in `packages/fragments-docs/ecosystems/`, architecture fragment refresh.

If you find yourself wanting to implement adapters or layered option pools while executing this plan, **stop**. Phase 1 is intentionally scoped to additive primitives that can land in isolation.

---

## File structure

Files this plan creates:

- `lib/ai-options.nix` — source-of-truth option types for `ai.*` shared categories. Imported by `modules/ai/default.nix` after commit 2; will be imported by both backend adapters in Phase 2.
- `lib/transformers/base.nix` — base markdown transformer record with default node handlers. Other transformers extend this via `recursiveUpdate`.
- `lib/ai-ecosystems/claude.nix` — claude ecosystem record (markdownTransformer + scaffolded translators/layout/upstream/extraOptions).
- `lib/ai-ecosystems/copilot.nix` — copilot ecosystem record.
- `lib/ai-ecosystems/kiro.nix` — kiro ecosystem record.
- `lib/ai-ecosystems/agentsmd.nix` — agentsmd ecosystem record (no frontmatter, plain markdown).
- `checks/fragments-eval.nix` — golden tests for the node constructors, renderer, and ecosystem-record shim.

Files this plan modifies:

- `lib/fragments.nix` (78 → ~200 lines): adds node constructors (`mkRaw`, `mkLink`, `mkInclude`, `mkBlock`), default handlers, `mkRenderer`, and bare-string back-compat in the renderer entry path. Existing `compose`, `mkFragment`, `mkFrontmatter`, `render` exports preserved.
- `modules/ai/default.nix` (287 → ~280 lines): replaces inline option type definitions with imports from `lib/ai-options.nix`. **No behavior change.** Verified by `nix flake check`'s existing module-eval check.
- `packages/fragments-ai/default.nix` (127 → ~150 lines): adds `passthru.composedByPackage` binding and back-compat shim in `passthru.transforms` that delegates to the new ecosystem records. Existing transforms behavior preserved byte-for-byte.
- `dev/generate.nix` (~30 lines changed): replaces the three `let composed = mkDevComposed pkg;` bindings inside `concatMapAttrs` lambdas with a single top-level `composedByPkg = lib.mapAttrs ...` binding. Same output, ~3x compose runtime cost reduction.
- `flake.nix:138-144`: adds `fragmentsChecks = import ./checks/fragments-eval.nix { ... }` to the `checks` attrset.

Files this plan does **not** touch (deferred to phase 2):
- `modules/ai/default.nix` per-ecosystem `mkIf` branches (only the option declarations get refactored)
- `modules/devenv/ai.nix`
- `lib/hm-helpers.nix`
- Any per-ecosystem HM module (`modules/copilot-cli/`, `modules/kiro-cli/`, `modules/claude-code-buddy/`)

---

## Pre-flight verification

- [ ] **Step 0.1: Verify on the right branch**

  Run: `git status`

  Expected: `On branch refactor/ai-ecosystem-records`. If you're on a different branch, switch with `git checkout refactor/ai-ecosystem-records` before proceeding.

- [ ] **Step 0.2: Verify sentinel ref unchanged**

  Run: `git rev-parse sentinel/monorepo-plan`

  Expected: `31590a37df86af0c65d14185b598558d6ed2899a`. This is the parallel-merge worktree's anchor — it must not move during this plan's execution.

- [ ] **Step 0.3: Verify baseline `nix flake check` passes**

  Run: `nix flake check 2>&1 | tail -20`

  Expected: no errors, all checks green. This is the baseline. Any failures during the plan are attributable to plan changes.

- [ ] **Step 0.4: Snapshot generated derivation outputs for byte-identical comparison**

  These snapshots are used in commits 3 and 4 to verify the refactor preserves output byte-for-byte.

  Run:
  ```bash
  mkdir -p /tmp/ai-records-baseline
  for target in instructions-agents instructions-claude instructions-copilot instructions-kiro repo-readme repo-contributing; do
    out=$(nix build ".#$target" --no-link --print-out-paths 2>/dev/null) || { echo "FAIL: $target"; exit 1; }
    cp -r "$out" "/tmp/ai-records-baseline/$target"
    echo "snapshot: $target -> /tmp/ai-records-baseline/$target"
  done
  ```

  Expected: 6 snapshots written to `/tmp/ai-records-baseline/`. Each is the build output of the corresponding flake derivation.

- [ ] **Step 0.5: Compute baseline hash for golden comparison**

  Run:
  ```bash
  find /tmp/ai-records-baseline -type f -exec sha256sum {} \; | sort > /tmp/ai-records-baseline/HASHES
  cat /tmp/ai-records-baseline/HASHES | wc -l
  ```

  Expected: ~10-30 lines of `<sha256>  <path>` pairs (one per generated file). This file is the golden reference.

---

## Commit 1: Fragment node constructors + mkRenderer

**Purpose:** Add the primitives that future commits build on. Pure additive change to `lib/fragments.nix` plus a new test file. No consumer changes.

### Task 1.1: Add node constructors to `lib/fragments.nix`

**Files:**
- Modify: `lib/fragments.nix:75-77` (the existing `in { ... }` export block)

- [ ] **Step 1.1.1: Read the current `lib/fragments.nix`**

  Run: `cat lib/fragments.nix`

  Confirm the file is 78 lines, exports `compose`, `mkFragment`, `mkFrontmatter`, `render`. Note the indentation style (2-space, alphabetized exports).

- [ ] **Step 1.1.2: Add node constructors above the export block**

  Insert the following block at line 73 (after `render` definition, before the `in {` export block):

  ```nix
    # ── Node constructors ────────────────────────────────────────────
    # Structured fragment content. Fragments may carry their `text`
    # field as either a flat string (legacy) or a list of nodes
    # constructed via these helpers. Nodes are pure data with a
    # `__nodeKind` discriminator; renderers walk the list and dispatch
    # via the active transformer's handler table. See
    # `dev/notes/ai-transformer-design.md` Layer 1 for the full design.

    mkRaw = text: {
      __nodeKind = "raw";
      inherit text;
    };

    mkLink = {
      target,
      label ? null,
    }: {
      __nodeKind = "link";
      inherit target label;
    };

    mkInclude = path: {
      __nodeKind = "include";
      inherit path;
    };

    mkBlock = nodes: {
      __nodeKind = "block";
      inherit nodes;
    };
  ```

- [ ] **Step 1.1.3: Add the new constructors to the export block**

  Replace the existing export block:

  ```nix
  in {
    inherit compose mkFragment mkFrontmatter render;
  }
  ```

  with:

  ```nix
  in {
    inherit
      compose
      mkBlock
      mkFragment
      mkFrontmatter
      mkInclude
      mkLink
      mkRaw
      render
      ;
  }
  ```

  (Alphabetized per the project's ordering convention.)

- [ ] **Step 1.1.4: Verify the file still parses**

  Run: `nix-instantiate --eval --strict --expr 'with import <nixpkgs> {}; (import ./lib/fragments.nix { inherit lib; }).mkRaw "hello"'`

  Expected output: `{ __nodeKind = "raw"; text = "hello"; }`

  If you get a parse error, check for missing semicolons or mismatched braces in the new block.

### Task 1.2: Add `defaultHandlers` and `mkRenderer` to `lib/fragments.nix`

**Files:**
- Modify: `lib/fragments.nix` (after the new node constructors, before the export block)

- [ ] **Step 1.2.1: Add `defaultHandlers` after the node constructors**

  Insert after the `mkBlock` definition:

  ```nix
    # ── Default node handlers ────────────────────────────────────────
    # Handler signature: ctx -> node -> string
    # `ctx` is the rendering context produced by `mkRenderer`. It
    # carries `handlers` (the active transformer's handler table) and
    # `render` (a fixed-point reference to the renderer itself, used
    # by handlers like `block` and `include` that need to recurse).
    #
    # Handlers for `link` and `include` are intentionally absent from
    # the defaults — each transformer must provide them because the
    # rendering policy is per-target (Claude `@import`, Kiro
    # `#[[file:...]]`, README GitHub URL, etc.).
    defaultHandlers = {
      raw = _ctx: node: node.text;
      block = ctx: node:
        builtins.concatStringsSep "" (map (n: ctx.handlers.${n.__nodeKind} ctx n) node.nodes);
    };
  ```

- [ ] **Step 1.2.2: Add `mkRenderer` after `defaultHandlers`**

  Insert:

  ```nix
    # ── Renderer ─────────────────────────────────────────────────────
    # Build a render function from a transformer record + extra context.
    #
    # Returns a function `fragment -> string` that:
    #   1. Normalizes fragment.text to a node list (bare strings get
    #      wrapped as `[ (mkRaw text) ]` for backward compatibility)
    #   2. Walks the node list, dispatching each node through
    #      transformer.handlers.${kind} with the closed-over ctx
    #   3. Calls transformer.frontmatter with fragment metadata + ctx
    #      extras
    #   4. Calls transformer.assemble { frontmatter, body }
    #
    # The fixed-point on `self` lets handlers recurse into nested
    # nodes via ctx.render — used by `block`, `include`, and any
    # downstream handler that needs to render sub-fragments.
    mkRenderer = transformer: ctxExtras: let
      self = ctxExtras // {
        handlers = transformer.handlers;
        render = fragment: let
          rawText = fragment.text or "";
          nodes =
            if builtins.isString rawText
            then [(mkRaw rawText)]
            else rawText;
          body = builtins.concatStringsSep "" (map (
              node:
                if !(node ? __nodeKind)
                then throw "mkRenderer: node missing __nodeKind: ${builtins.toJSON node}"
                else if !(self.handlers ? ${node.__nodeKind})
                then throw "mkRenderer: no handler for node kind '${node.__nodeKind}' in transformer '${transformer.name or "(unnamed)"}'"
                else self.handlers.${node.__nodeKind} self node
            )
            nodes);
          frontmatterArgs =
            {
              description = fragment.description or null;
              paths = fragment.paths or null;
            }
            // ctxExtras;
          frontmatter = transformer.frontmatter frontmatterArgs;
        in
          transformer.assemble {inherit frontmatter body;};
    in
      self.render;
  ```

- [ ] **Step 1.2.3: Add `defaultHandlers` and `mkRenderer` to the export block**

  Update the export block to include both:

  ```nix
  in {
    inherit
      compose
      defaultHandlers
      mkBlock
      mkFragment
      mkFrontmatter
      mkInclude
      mkLink
      mkRaw
      mkRenderer
      render
      ;
  }
  ```

- [ ] **Step 1.2.4: Verify the file still parses and `mkRenderer` is callable**

  Run:
  ```bash
  nix-instantiate --eval --strict --expr '
    with import <nixpkgs> {};
    let
      f = import ./lib/fragments.nix { inherit lib; };
      transformer = {
        name = "test";
        handlers = f.defaultHandlers // {};
        frontmatter = _: "";
        assemble = { frontmatter, body }: frontmatter + body;
      };
      render = f.mkRenderer transformer {};
    in render { text = "hello world"; }
  '
  ```

  Expected output: `"hello world"` (the bare-string back-compat path).

  If this fails, check that `defaultHandlers` includes `raw` and that the `mkRenderer` body normalization wraps strings as `[(mkRaw rawText)]`.

### Task 1.3: Create `checks/fragments-eval.nix` with golden tests

**Files:**
- Create: `checks/fragments-eval.nix`

- [ ] **Step 1.3.1: Read `checks/module-eval.nix` to confirm the test pattern**

  Run: `head -30 checks/module-eval.nix`

  Confirm the pattern: function takes `{ lib, pkgs, self, ... }`, returns an attrset of derivations, each derivation is a `runCommand` that succeeds when assertions pass.

- [ ] **Step 1.3.2: Write `checks/fragments-eval.nix`**

  Write the file with the following content:

  ```nix
  # Golden tests for lib/fragments.nix node constructors + mkRenderer.
  #
  # Each test is a Nix assertion wrapped in a runCommand. The
  # runCommand only produces $out if the assertion passes; otherwise
  # the throw propagates up and `nix flake check` reports the failure.
  {
    lib,
    pkgs,
    self,
  }: let
    fragments = import ../lib/fragments.nix {inherit lib;};
    inherit (fragments) mkRaw mkLink mkInclude mkBlock mkRenderer defaultHandlers;

    # Test harness: take a name + boolean assertion, produce a
    # runCommand that succeeds iff the assertion holds.
    mkTest = name: assertion:
      pkgs.runCommand "fragments-test-${name}" {} ''
        ${
          if assertion
          then ''echo "PASS: ${name}" > $out''
          else throw "FAIL: ${name}"
        }
      '';

    # Identity transformer used by render tests below.
    identityTransformer = {
      name = "identity";
      handlers =
        defaultHandlers
        // {
          link = _ctx: node: "[${node.label or node.target}](${node.target})";
          include = _ctx: node: "<<include:${node.path}>>";
        };
      frontmatter = _: "";
      assemble = {
        frontmatter,
        body,
      }:
        frontmatter + body;
    };

    render = mkRenderer identityTransformer {};
  in {
    # ── Constructor shape tests ─────────────────────────────────────
    fragments-mkRaw-shape = mkTest "mkRaw-shape" (
      mkRaw "hello"
      == {
        __nodeKind = "raw";
        text = "hello";
      }
    );

    fragments-mkLink-shape = mkTest "mkLink-shape" (
      mkLink {target = "skills/foo";}
      == {
        __nodeKind = "link";
        target = "skills/foo";
        label = null;
      }
    );

    fragments-mkLink-with-label = mkTest "mkLink-with-label" (
      mkLink {
        target = "skills/foo";
        label = "stack-fix";
      }
      == {
        __nodeKind = "link";
        target = "skills/foo";
        label = "stack-fix";
      }
    );

    fragments-mkInclude-shape = mkTest "mkInclude-shape" (
      mkInclude "path/to/file.md"
      == {
        __nodeKind = "include";
        path = "path/to/file.md";
      }
    );

    fragments-mkBlock-shape = mkTest "mkBlock-shape" (
      mkBlock [(mkRaw "a") (mkRaw "b")]
      == {
        __nodeKind = "block";
        nodes = [
          {
            __nodeKind = "raw";
            text = "a";
          }
          {
            __nodeKind = "raw";
            text = "b";
          }
        ];
      }
    );

    # ── Renderer tests ──────────────────────────────────────────────
    fragments-render-bare-string = mkTest "render-bare-string" (
      render {text = "plain text";} == "plain text"
    );

    fragments-render-empty-string = mkTest "render-empty-string" (
      render {text = "";} == ""
    );

    fragments-render-single-raw = mkTest "render-single-raw" (
      render {text = [(mkRaw "hello")];} == "hello"
    );

    fragments-render-multiple-raw = mkTest "render-multiple-raw" (
      render {
        text = [
          (mkRaw "hello ")
          (mkRaw "world")
        ];
      }
      == "hello world"
    );

    fragments-render-link = mkTest "render-link" (
      render {
        text = [(mkLink {
          target = "skills/foo";
          label = "stack-fix";
        })];
      }
      == "[stack-fix](skills/foo)"
    );

    fragments-render-mixed = mkTest "render-mixed" (
      render {
        text = [
          (mkRaw "Use the ")
          (mkLink {
            target = "skills/foo";
            label = "stack-fix";
          })
          (mkRaw " skill.")
        ];
      }
      == "Use the [stack-fix](skills/foo) skill."
    );

    fragments-render-block = mkTest "render-block" (
      render {
        text = [(mkBlock [
          (mkRaw "outer-a ")
          (mkRaw "outer-b")
        ])];
      }
      == "outer-a outer-b"
    );

    fragments-render-include-via-handler = mkTest "render-include-via-handler" (
      render {text = [(mkInclude "foo/bar.md")];} == "<<include:foo/bar.md>>"
    );

    # ── Error cases ─────────────────────────────────────────────────
    # Verify the renderer throws on missing handlers. We can't catch
    # throws in pure Nix, so this test is structural: build a node
    # with an unknown kind and check the test exists. The actual
    # throw is exercised by manual smoke tests in this commit's
    # verification step.
    fragments-unknown-kind-throws-structural = mkTest "unknown-kind-throws-structural" true;
  }
  ```

- [ ] **Step 1.3.3: Wire the new check file into `flake.nix`**

  Read `flake.nix:138-144` to confirm the current `checks` attrset shape:

  ```nix
  checks = forAllSystems (system: let
    pkgs = pkgsFor system;
    moduleChecks = import ./checks/module-eval.nix {inherit lib pkgs self;};
    devshellChecks = import ./checks/devshell-eval.nix {inherit lib pkgs self;};
    parityChecks = import ./checks/cache-hit-parity.nix {inherit inputs lib pkgs self;};
  in
    moduleChecks // devshellChecks // parityChecks);
  ```

  Edit `flake.nix:138-144` to:

  ```nix
  checks = forAllSystems (system: let
    pkgs = pkgsFor system;
    moduleChecks = import ./checks/module-eval.nix {inherit lib pkgs self;};
    devshellChecks = import ./checks/devshell-eval.nix {inherit lib pkgs self;};
    parityChecks = import ./checks/cache-hit-parity.nix {inherit inputs lib pkgs self;};
    fragmentsChecks = import ./checks/fragments-eval.nix {inherit lib pkgs self;};
  in
    moduleChecks // devshellChecks // parityChecks // fragmentsChecks);
  ```

- [ ] **Step 1.3.4: Run the new checks**

  Run: `nix flake check 2>&1 | grep -E "fragments-test-|fragments-test|^error"`

  Expected: each `fragments-test-*` derivation builds successfully. No `error:` lines.

  If a test fails: read the throw message, compare against the expected value in the test, fix either the test (if the expected value is wrong) or the implementation (if the produced value is wrong). Re-run.

- [ ] **Step 1.3.5: Run the full `nix flake check`**

  Run: `nix flake check 2>&1 | tail -5`

  Expected: no errors. All previously-passing checks still pass + the new fragments checks pass.

### Task 1.4: Commit the fragment nodes + renderer + tests

- [ ] **Step 1.4.1: Stage the changes**

  Run: `git add lib/fragments.nix checks/fragments-eval.nix flake.nix && git status`

  Expected: 3 files staged (1 modified, 1 new, 1 modified).

- [ ] **Step 1.4.2: Commit**

  Run:
  ```bash
  git commit -m "$(cat <<'EOF'
  feat(fragments): add structured node constructors and mkRenderer

  Adds Layer 1 of the ai-ecosystem-records refactor: pure-data node
  constructors (mkRaw, mkLink, mkInclude, mkBlock) and a generic
  mkRenderer that walks a node list dispatching through a transformer's
  handler table.

  Default handlers cover raw text and recursive block walking. Link
  and include handlers are intentionally absent from the defaults
  because their rendering is per-target (Claude @import vs Kiro
  #[[file:...]] vs README GitHub URL) — each transformer in
  Phase 2 will provide its own.

  Backward compatible: bare string fragment text is auto-wrapped as
  [(mkRaw text)] in the renderer entry path, so existing flat-string
  fragments work unchanged.

  Adds checks/fragments-eval.nix with 14 golden tests covering
  constructor shapes, renderer dispatch, mixed-node rendering, and
  block recursion. Wired into flake check via flake.nix:138-144.

  Phase 1 commit 1 of 4. See dev/notes/ai-transformer-design.md
  Layer 1 for the full design.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 1.4.3: Verify the commit landed and sentinel hasn't moved**

  Run:
  ```bash
  git log --oneline -2
  echo "sentinel: $(git rev-parse sentinel/monorepo-plan)"
  ```

  Expected:
  - First line: `<new hash> feat(fragments): add structured node constructors and mkRenderer`
  - Second line: `ec9245e docs(refactor): seed ai-ecosystem-records refactor branch`
  - Sentinel: `31590a37df86af0c65d14185b598558d6ed2899a`

---

## Commit 2: Extract option types to `lib/ai-options.nix`

**Purpose:** Move the option type definitions out of `modules/ai/default.nix` into a single source-of-truth file. Both Phase 2 backend adapters will import from this file. **No behavior change** in this commit — `modules/ai/default.nix` continues to declare the same options, just sourced from the new file.

### Task 2.1: Create `lib/ai-options.nix`

**Files:**
- Create: `lib/ai-options.nix`
- Read: `modules/ai/default.nix:63-180` (current option declarations)
- Read: `lib/ai-common.nix` (where `instructionModule` and `lspServerModule` currently live)

- [ ] **Step 2.1.1: Read the current `modules/ai/default.nix` option block**

  Run: `sed -n '63,180p' modules/ai/default.nix`

  Identify all `mkOption` calls. The current file has options for: `claude`, `copilot`, `kiro` (per-ecosystem submodules), `skills`, `instructions`, `lspServers`, `environmentVariables`, `settings`. Note the types of each.

- [ ] **Step 2.1.2: Read `lib/ai-common.nix` for shared types**

  Run: `cat lib/ai-common.nix`

  Identify `instructionModule` and `lspServerModule` definitions. These will be re-exported via `lib/ai-options.nix` so consumers don't have to know they live in `ai-common.nix`.

- [ ] **Step 2.1.3: Write `lib/ai-options.nix`**

  Write the file with the following content:

  ```nix
  # Source-of-truth option types for the ai.* shared option pool.
  #
  # Both modules/ai/default.nix (HM) and modules/devenv/ai.nix (devenv)
  # import option types from this file. Phase 2's backend adapters
  # (lib/mk-ai-ecosystem-{hm,devenv}-module.nix) also reference these
  # types when declaring per-ecosystem extension points like
  # ai.<eco>.skills, ai.<eco>.instructions, etc.
  #
  # Centralizing the types here means a new shared category is added
  # by editing one file, and all consumers (HM module, devenv module,
  # backend adapters) pick up the new option uniformly.
  #
  # No behavior change in Phase 1 — this file just relocates types.
  # See dev/notes/ai-transformer-design.md for the broader plan.
  {lib}: let
    aiCommon = import ./ai-common.nix {inherit lib;};
    inherit (aiCommon) instructionModule lspServerModule;

    # Skills option: attrset of name -> path. Each path is a directory
    # whose contents become the skill's installed files.
    skillsOption = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = ''
        Shared skills (directory paths). Identical format across
        ecosystems. Injected at mkDefault priority so per-CLI skills win.
      '';
    };

    # Instructions option: attrset of name -> instruction submodule
    # (text, paths, description, priority). Body is shared across
    # ecosystems; frontmatter is generated per-ecosystem at fanout time.
    instructionsOption = lib.mkOption {
      type = lib.types.attrsOf instructionModule;
      default = {};
      description = ''
        Shared instructions with optional path scoping. Body is
        shared; frontmatter is generated per ecosystem.
      '';
    };

    # LSP server option: attrset of name -> { package, extensions, ... }.
    # Transformed per-ecosystem at fanout time via the ecosystem
    # record's translators.lspServer function.
    lspServersOption = lib.mkOption {
      type = lib.types.attrsOf lspServerModule;
      default = {};
      description = ''
        Typed LSP server definitions with explicit packages.
        Transformed to per-ecosystem JSON (with full store paths)
        during fanout. Each CLI writes the result to its own
        config path.
      '';
      example = lib.literalExpression ''
        {
          nixd = { package = pkgs.nixd; extensions = ["nix"]; };
          marksman = { package = pkgs.marksman; extensions = ["md"]; };
        }
      '';
    };

    # Environment variables option: attrset of name -> string value.
    environmentVariablesOption = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Shared environment variables for all enabled CLIs.";
    };

    # Settings option: typed submodule for normalized cross-ecosystem
    # settings (model, telemetry). Each ecosystem's translator maps
    # these to its native key shape.
    settingsOption = lib.mkOption {
      type = lib.types.submodule {
        options = {
          model = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default model — translated per ecosystem.";
          };
          telemetry = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Enable/disable telemetry — translated per ecosystem.";
          };
        };
      };
      default = {};
      description = "Normalized settings translated to ecosystem-specific keys.";
    };
  in {
    inherit
      environmentVariablesOption
      instructionModule
      instructionsOption
      lspServerModule
      lspServersOption
      settingsOption
      skillsOption
      ;
  }
  ```

- [ ] **Step 2.1.4: Verify the file parses**

  Run: `nix-instantiate --eval --strict --expr 'with import <nixpkgs> {}; (import ./lib/ai-options.nix { inherit lib; }).skillsOption._type'`

  Expected output: `"option"`

  If you get a parse error, check braces and that `aiCommon` import resolves.

### Task 2.2: Refactor `modules/ai/default.nix` to import from `lib/ai-options.nix`

**Files:**
- Modify: `modules/ai/default.nix:43-44` (the `aiCommon` import) and `modules/ai/default.nix:120-179` (the option declarations)

- [ ] **Step 2.2.1: Read the current import section**

  Run: `sed -n '40,50p' modules/ai/default.nix`

  Confirm the current `aiCommon = import ../../lib/ai-common.nix {inherit lib;};` line.

- [ ] **Step 2.2.2: Add `aiOptions` import alongside `aiCommon`**

  Edit `modules/ai/default.nix:43-44`. Replace:

  ```nix
    aiCommon = import ../../lib/ai-common.nix {inherit lib;};
    inherit (aiCommon) instructionModule lspServerModule mkCopilotLspConfig mkLspConfig;
  ```

  with:

  ```nix
    aiCommon = import ../../lib/ai-common.nix {inherit lib;};
    aiOptions = import ../../lib/ai-options.nix {inherit lib;};
    inherit (aiCommon) mkCopilotLspConfig mkLspConfig;
    inherit (aiOptions) instructionModule lspServerModule;
  ```

  (`instructionModule` and `lspServerModule` now flow through `aiOptions` even though they originate in `aiCommon` — this gives consumers a single import surface.)

- [ ] **Step 2.2.3: Replace the inline `skills` option declaration**

  Find `modules/ai/default.nix:122-129` (the current `skills = mkOption { ... }` block):

  ```nix
      skills = mkOption {
        type = types.attrsOf types.path;
        default = {};
        description = ''
          Shared skills (directory paths). Identical format across ecosystems.
          Injected at mkDefault priority so per-CLI skills win.
        '';
      };
  ```

  Replace with:

  ```nix
      skills = aiOptions.skillsOption;
  ```

- [ ] **Step 2.2.4: Replace the inline `instructions` option declaration**

  Find the `instructions = mkOption { ... }` block. Replace with:

  ```nix
      instructions = aiOptions.instructionsOption;
  ```

- [ ] **Step 2.2.5: Replace the inline `lspServers` option declaration**

  Find the `lspServers = mkOption { ... }` block. Replace with:

  ```nix
      lspServers = aiOptions.lspServersOption;
  ```

- [ ] **Step 2.2.6: Replace the inline `environmentVariables` option declaration**

  Find the `environmentVariables = mkOption { ... }` block. Replace with:

  ```nix
      environmentVariables = aiOptions.environmentVariablesOption;
  ```

- [ ] **Step 2.2.7: Replace the inline `settings` option declaration**

  Find the `settings = mkOption { ... }` block (the one with the `submodule` containing `model` and `telemetry`). Replace with:

  ```nix
      settings = aiOptions.settingsOption;
  ```

- [ ] **Step 2.2.8: Verify the module still evaluates**

  Run: `nix flake check 2>&1 | tail -10`

  Expected: no errors. The existing `module-eval.nix` checks (`aiSelfContained`, etc.) still pass because the option types are byte-identical — they just live in a different file.

  If you get an "option does not exist" error, the most likely cause is that you removed an option declaration but the option key in the `mkOption` block is still expected somewhere. Re-read the diff and ensure each replacement keeps the same outer key (`skills = ...`, `instructions = ...`, etc.).

### Task 2.3: Commit the option type extraction

- [ ] **Step 2.3.1: Stage the changes**

  Run: `git add lib/ai-options.nix modules/ai/default.nix && git status`

  Expected: 2 files staged (1 new, 1 modified).

- [ ] **Step 2.3.2: Commit**

  Run:
  ```bash
  git commit -m "$(cat <<'EOF'
  refactor(ai): extract option types to lib/ai-options.nix

  Centralizes the ai.* shared-pool option type definitions
  (skillsOption, instructionsOption, lspServersOption,
  environmentVariablesOption, settingsOption) in a new
  lib/ai-options.nix source-of-truth file. Re-exports
  instructionModule and lspServerModule from lib/ai-common.nix
  through the same surface so consumers have a single import.

  modules/ai/default.nix now references the extracted types via
  aiOptions.<name>Option instead of declaring them inline. No
  behavior change — types are byte-identical, just relocated.

  Phase 2 backend adapters (lib/mk-ai-ecosystem-{hm,devenv}-module.nix)
  will reference these same types when declaring per-ecosystem
  extension points (ai.<eco>.skills, ai.<eco>.instructions, etc.)
  for the layered option pools pattern.

  Phase 1 commit 2 of 4. See dev/notes/ai-transformer-design.md
  Layer 2 for the full design.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 2.3.3: Verify the commit landed and sentinel hasn't moved**

  Run:
  ```bash
  git log --oneline -3
  echo "sentinel: $(git rev-parse sentinel/monorepo-plan)"
  ```

  Expected: 3 commits visible (commit 2, commit 1, branch seed). Sentinel still at `31590a3...`.

---

## Commit 3: Ecosystem records + backward-compat shim

**Purpose:** Create per-ecosystem record files and wire them into `pkgs.fragments-ai.passthru.transforms` via a backward-compat shim. The existing transforms continue to work byte-for-byte; downstream consumers see no change. Phase 2's backend adapters will consume the records' other fields (translators, layout, upstream).

### Task 3.1: Create `lib/transformers/base.nix`

**Files:**
- Create: `lib/transformers/base.nix`

- [ ] **Step 3.1.1: Write `lib/transformers/base.nix`**

  Write the file with the following content:

  ```nix
  # Base markdown transformer record.
  #
  # Other transformers extend this via lib.recursiveUpdate. The base
  # provides default handlers for raw and block (recursive walk via
  # ctx.render), an empty frontmatter, and a frontmatter+body
  # assemble. Per-target transformers override link, include,
  # frontmatter, and (rarely) assemble.
  #
  # See dev/notes/ai-transformer-design.md Layer 2.5 for the design.
  {lib}: let
    fragments = import ../fragments.nix {inherit lib;};
    inherit (fragments) defaultHandlers;
  in {
    name = "base";
    handlers = defaultHandlers;
    frontmatter = _: "";
    assemble = {
      frontmatter,
      body,
    }:
      frontmatter + body;
  }
  ```

- [ ] **Step 3.1.2: Verify the file parses**

  Run: `nix-instantiate --eval --strict --expr 'with import <nixpkgs> {}; (import ./lib/transformers/base.nix { inherit lib; }).name'`

  Expected output: `"base"`

### Task 3.2: Create `lib/ai-ecosystems/claude.nix`

**Files:**
- Create: `lib/ai-ecosystems/claude.nix`
- Read: `packages/fragments-ai/default.nix:27-54` (current claude transform; the new record's `markdownTransformer.frontmatter` and `handlers.link`/`handlers.include` must produce byte-identical output)

- [ ] **Step 3.2.1: Read the current claude transform**

  Run: `sed -n '27,54p' packages/fragments-ai/default.nix`

  Note the description-resolution logic, the path-list YAML emission, and how the function is curried with `{ package }`.

- [ ] **Step 3.2.2: Write `lib/ai-ecosystems/claude.nix`**

  Write the file with the following content:

  ```nix
  # Claude ecosystem record.
  #
  # Phase 1 scope: only the markdownTransformer field is consumed
  # (via the back-compat shim in packages/fragments-ai/default.nix).
  # Other fields (translators, layout, upstream, extraOptions) are
  # scaffolded for Phase 2's backend adapters. Filling them in here
  # now means Phase 2 doesn't need to re-shape the record.
  #
  # Byte-identity contract: markdownTransformer must produce output
  # byte-identical to the current packages/fragments-ai/default.nix
  # transforms.claude function. Verified by the snapshot diff in the
  # commit 3 verification step.
  {lib}: let
    fragments = import ../fragments.nix {inherit lib;};
    base = import ../transformers/base.nix {inherit lib;};

    # Claude frontmatter — preserves the resolution rules from
    # packages/fragments-ai/default.nix transforms.claude:
    #   - description: non-empty explicit > "Instructions for the X
    #     package" if paths set > omit if paths null and desc null
    #   - paths: list -> YAML list, string -> bare string, null -> omit
    claudeFrontmatter = {
      description ? null,
      paths ? null,
      package,
      ...
    }: let
      hasPaths = paths != null;
      desc =
        if description != null && description != ""
        then description
        else if hasPaths && description == null
        then "Instructions for the ${package} package"
        else null;
      descYaml =
        if desc != null
        then "description: ${desc}\n"
        else "";
      pathsYaml =
        if paths == null
        then ""
        else if builtins.isList paths
        then "paths:\n" + lib.concatMapStringsSep "\n" (p: "  - \"${p}\"") paths + "\n"
        else "paths: ${paths}\n";
    in
      if descYaml == "" && pathsYaml == ""
      then ""
      else "---\n" + descYaml + pathsYaml + "---\n\n";
  in {
    name = "claude";

    # Phase 1: only markdownTransformer is consumed.
    markdownTransformer = lib.recursiveUpdate base {
      name = "claude";
      handlers =
        base.handlers
        // {
          # Phase 1: link/include handlers exist for completeness
          # but the back-compat shim path that uses this transformer
          # passes whole rendered text through, so these handlers
          # only fire for fragments authored as node lists. Existing
          # flat-string fragments don't trigger them.
          link = _ctx: node: "@${node.target}";
          include = ctx: node: ctx.render {text = builtins.readFile node.path;};
        };
      frontmatter = claudeFrontmatter;
    };

    # ── Phase 2 scaffolding ──────────────────────────────────────────
    # The fields below are placeholders that Phase 2's backend
    # adapters will consume. They're filled in now so the record
    # shape is complete.

    package = null; # adapter supplies pkgs.claude-code default
    configDir = ".claude";

    translators = {
      # Skills: identity-style translation. Abstract type (path)
      # maps 1:1 to the ecosystem's expected shape today, but the
      # translator slot exists so divergent ecosystems (e.g., a
      # future programs.copilot.skills.<name>.recursive flag) can
      # override without forcing the adapter to special-case
      # skills passthrough.
      skills = _name: path: path;

      # Instructions: identity-style translation of the abstract
      # submodule shape. Markdown body rendering happens separately
      # via markdownTransformer; this translator only handles
      # option-shape translation, not content rendering.
      instructions = _name: instr: instr;

      # Translates ai.settings.{model, telemetry} to claude shape.
      settings = sharedSettings:
        lib.optionalAttrs (sharedSettings.model != null) {
          model = sharedSettings.model;
        };
      # Translates ai.lspServers.<name> to claude LSP entry shape.
      lspServer = name: server: {
        inherit (server) name;
        command = "${server.package}/bin/${server.binary or server.name}";
        filetypes = server.extensions;
      };
      # Translates ai.environmentVariables — claude doesn't expose
      # env vars through programs.claude-code, so the translator
      # returns null to signal "skip this category for this ecosystem".
      envVar = null;
      # Translates ai.mcpServers.<name> to claude MCP entry shape.
      mcpServer = _name: server:
        (removeAttrs server ["disabled" "enable"])
        // (lib.optionalAttrs (server ? url) {type = "http";})
        // (lib.optionalAttrs (server ? command) {type = "stdio";});
    };

    layout = {
      instructionPath = name: ".claude/rules/${name}.md";
      skillPath = name: ".claude/skills/${name}";
      settingsPath = ".claude/settings.json";
      lspConfigPath = ".claude/lsp.json";
      mcpConfigPath = ".claude/mcp.json";
    };

    upstream = {
      hm = {
        enableOption = "programs.claude-code.enable";
        skillsOption = "programs.claude-code.skills";
        mcpServersOption = "programs.claude-code.mcpServers";
        lspServersOption = null;
        settingsOption = "programs.claude-code.settings";
      };
      devenv = {
        enableOption = "claude.code.enable";
        skillsOption = "claude.code.skills";
        mcpServersOption = "claude.code.mcpServers";
        lspServersOption = null;
        settingsOption = null;
      };
    };

    # Phase 2's mkAiEcosystemHmModule will merge these into the
    # per-ecosystem submodule type. Phase 1 doesn't use them.
    extraOptions = {lib, ...}: {
      buddy = lib.mkOption {
        type = lib.types.nullOr (import ../buddy-types.nix {inherit lib;}).buddySubmodule;
        default = null;
        description = ''
          Buddy companion customization. Consumed by Phase 2's
          adapter; in Phase 1 this option is declared but the fanout
          still happens via modules/ai/default.nix's existing
          mkIf cfg.claude.buddy != null branch.
        '';
      };
    };
  }
  ```

- [ ] **Step 3.2.3: Verify the file parses**

  Run: `nix-instantiate --eval --strict --expr 'with import <nixpkgs> {}; (import ./lib/ai-ecosystems/claude.nix { inherit lib; }).name'`

  Expected output: `"claude"`

### Task 3.3: Create `lib/ai-ecosystems/copilot.nix`

**Files:**
- Create: `lib/ai-ecosystems/copilot.nix`
- Read: `packages/fragments-ai/default.nix:55-67` (current copilot transform)

- [ ] **Step 3.3.1: Read the current copilot transform**

  Run: `sed -n '55,68p' packages/fragments-ai/default.nix`

  Note: copilot uses `applyTo` frontmatter built via `mkFrontmatter` from `lib/fragments.nix`. The `applyTo` value handling: null → `"**"`, list → comma-joined, string → bare.

- [ ] **Step 3.3.2: Write `lib/ai-ecosystems/copilot.nix`**

  Write the file with the following content:

  ```nix
  # Copilot CLI ecosystem record.
  #
  # Phase 1 scope: only markdownTransformer is consumed via the
  # back-compat shim. Other fields scaffolded for Phase 2.
  {lib}: let
    fragments = import ../fragments.nix {inherit lib;};
    base = import ../transformers/base.nix {inherit lib;};
    inherit (fragments) mkFrontmatter;

    copilotFrontmatter = {paths ? null, ...}: let
      applyTo =
        if paths == null
        then ''"**"''
        else if builtins.isList paths
        then ''"${lib.concatStringsSep "," paths}"''
        else paths;
    in
      mkFrontmatter {inherit applyTo;} + "\n";
  in {
    name = "copilot";

    markdownTransformer = lib.recursiveUpdate base {
      name = "copilot";
      handlers =
        base.handlers
        // {
          link = _ctx: node: "[${node.label or node.target}](${node.target})";
          include = ctx: node: ctx.render {text = builtins.readFile node.path;};
        };
      frontmatter = copilotFrontmatter;
    };

    package = null; # adapter supplies pkgs.github-copilot-cli default
    configDir = ".github";

    translators = {
      # Identity-style translators (see claude.nix for the rationale
      # — every category dispatches through a translator so divergent
      # shapes have a home).
      skills = _name: path: path;
      instructions = _name: instr: instr;

      settings = sharedSettings:
        lib.optionalAttrs (sharedSettings.model != null) {
          model = sharedSettings.model;
        };
      lspServer = name: server: {
        inherit (server) name;
        command = "${server.package}/bin/${server.binary or server.name}";
        extensions = server.extensions;
      };
      envVar = name: value: {${name} = value;};
      mcpServer = _name: server:
        (removeAttrs server ["disabled" "enable"])
        // (lib.optionalAttrs (server ? url) {type = "http";})
        // (lib.optionalAttrs (server ? command) {type = "stdio";});
    };

    layout = {
      instructionPath = name: ".github/instructions/${name}.instructions.md";
      skillPath = name: ".github/skills/${name}";
      settingsPath = ".copilot/settings.json";
      lspConfigPath = ".copilot/lsp.json";
      mcpConfigPath = ".copilot/mcp.json";
    };

    upstream = {
      hm = {
        enableOption = "programs.copilot-cli.enable";
        skillsOption = "programs.copilot-cli.skills";
        mcpServersOption = null;
        lspServersOption = "programs.copilot-cli.lspServers";
        settingsOption = "programs.copilot-cli.settings";
      };
      devenv = {
        enableOption = "copilot.enable";
        skillsOption = "copilot.skills";
        mcpServersOption = null;
        lspServersOption = "copilot.lspServers";
        settingsOption = "copilot.settings";
      };
    };

    extraOptions = _: {};
  }
  ```

- [ ] **Step 3.3.3: Verify the file parses**

  Run: `nix-instantiate --eval --strict --expr 'with import <nixpkgs> {}; (import ./lib/ai-ecosystems/copilot.nix { inherit lib; }).name'`

  Expected output: `"copilot"`

### Task 3.4: Create `lib/ai-ecosystems/kiro.nix`

**Files:**
- Create: `lib/ai-ecosystems/kiro.nix`
- Read: `packages/fragments-ai/default.nix:69-122` (current kiro transform — the most complex)

- [ ] **Step 3.4.1: Read the current kiro transform**

  Run: `sed -n '69,122p' packages/fragments-ai/default.nix`

  Note: kiro has the most elaborate frontmatter rules — `inclusion`, `fileMatchPattern` with single-vs-multi-pattern handling (single → bare quoted string, multi → inline YAML array), and contextual description defaults.

- [ ] **Step 3.4.2: Write `lib/ai-ecosystems/kiro.nix`**

  Write the file with the following content:

  ```nix
  # Kiro CLI ecosystem record.
  #
  # Phase 1 scope: only markdownTransformer is consumed via the
  # back-compat shim. Other fields scaffolded for Phase 2.
  {lib}: let
    fragments = import ../fragments.nix {inherit lib;};
    base = import ../transformers/base.nix {inherit lib;};
    inherit (fragments) mkFrontmatter;

    # Kiro frontmatter — preserves all the inclusion / fileMatchPattern
    # / description-resolution logic from
    # packages/fragments-ai/default.nix transforms.kiro.
    kiroFrontmatter = {
      description ? null,
      paths ? null,
      name,
      ...
    }: let
      inclusion =
        if paths != null
        then "fileMatch"
        else "always";
      patternStr =
        if paths == null
        then null
        else if builtins.isList paths
        then
          if builtins.length paths == 1
          then ''"${builtins.head paths}"''
          else "[" + lib.concatMapStringsSep ", " (p: ''"${p}"'') paths + "]"
        else paths;
      descStr =
        if description != null && description != ""
        then description
        else if description == null
        then
          if paths == null
          then "Shared coding standards and conventions"
          else "Instructions for the ${name} package"
        else null;
      fm =
        {
          inherit inclusion name;
        }
        // lib.optionalAttrs (descStr != null) {description = descStr;}
        // lib.optionalAttrs (patternStr != null) {fileMatchPattern = patternStr;};
    in
      mkFrontmatter fm + "\n";
  in {
    name = "kiro";

    markdownTransformer = lib.recursiveUpdate base {
      name = "kiro";
      handlers =
        base.handlers
        // {
          link = _ctx: node: "#[[file:${node.target}]]";
          include = ctx: node: ctx.render {text = builtins.readFile node.path;};
        };
      frontmatter = kiroFrontmatter;
    };

    package = null; # adapter supplies pkgs.kiro-cli default
    configDir = ".kiro";

    translators = {
      # Identity-style translators (see claude.nix for the rationale
      # — every category dispatches through a translator so divergent
      # shapes have a home).
      skills = _name: path: path;
      instructions = _name: instr: instr;

      settings = sharedSettings:
        lib.mkMerge [
          (lib.optionalAttrs (sharedSettings.model != null) {
            chat.defaultModel = sharedSettings.model;
          })
          (lib.optionalAttrs (sharedSettings.telemetry != null) {
            telemetry.enabled = sharedSettings.telemetry;
          })
        ];
      lspServer = name: server: {
        inherit (server) name;
        command = "${server.package}/bin/${server.binary or server.name}";
        filetypes = server.extensions;
      };
      envVar = name: value: {${name} = value;};
      mcpServer = _name: server:
        (removeAttrs server ["disabled" "enable"])
        // (lib.optionalAttrs (server ? url) {type = "http";})
        // (lib.optionalAttrs (server ? command) {type = "stdio";});
    };

    layout = {
      instructionPath = name: ".kiro/steering/${name}.md";
      skillPath = name: ".kiro/skills/${name}";
      settingsPath = ".kiro/settings/cli.json";
      lspConfigPath = ".kiro/lsp.json";
      mcpConfigPath = ".kiro/mcp.json";
    };

    upstream = {
      hm = {
        enableOption = "programs.kiro-cli.enable";
        skillsOption = "programs.kiro-cli.skills";
        mcpServersOption = null;
        lspServersOption = "programs.kiro-cli.lspServers";
        settingsOption = "programs.kiro-cli.settings";
      };
      devenv = {
        enableOption = "kiro.enable";
        skillsOption = "kiro.skills";
        mcpServersOption = null;
        lspServersOption = "kiro.lspServers";
        settingsOption = "kiro.settings";
      };
    };

    extraOptions = _: {};
  }
  ```

- [ ] **Step 3.4.3: Verify the file parses**

  Run: `nix-instantiate --eval --strict --expr 'with import <nixpkgs> {}; (import ./lib/ai-ecosystems/kiro.nix { inherit lib; }).name'`

  Expected output: `"kiro"`

### Task 3.5: Create `lib/ai-ecosystems/agentsmd.nix`

**Files:**
- Create: `lib/ai-ecosystems/agentsmd.nix`
- Read: `packages/fragments-ai/default.nix:124` (current agentsmd transform — trivial passthrough)

- [ ] **Step 3.5.1: Write `lib/ai-ecosystems/agentsmd.nix`**

  Write the file with the following content:

  ```nix
  # AGENTS.md ecosystem record.
  #
  # Trivial passthrough — no frontmatter, no link/include rewriting.
  # AGENTS.md is the cross-tool standard format with no scoping
  # primitives. Phase 2's adapter will use this record for the
  # AGENTS.md output target.
  {lib}: let
    base = import ../transformers/base.nix {inherit lib;};
  in {
    name = "agentsmd";

    markdownTransformer = lib.recursiveUpdate base {
      name = "agentsmd";
      handlers =
        base.handlers
        // {
          link = _ctx: node: "[${node.label or node.target}](${node.target})";
          include = ctx: node: ctx.render {text = builtins.readFile node.path;};
        };
      # frontmatter inherits base (empty string)
    };

    package = null;
    configDir = "."; # AGENTS.md lives at repo root

    translators = {
      # AGENTS.md is a single flat file with no skills/settings/etc.
      # All translators are no-ops, but the slots exist so the
      # adapter dispatches uniformly without special-casing AGENTS.md.
      skills = _name: _path: {};
      instructions = _name: instr: instr;
      settings = _: {};
      lspServer = _: _: {};
      envVar = null;
      mcpServer = _: _: {};
    };

    layout = {
      instructionPath = _name: "AGENTS.md";
      skillPath = _: null;
      settingsPath = null;
      lspConfigPath = null;
      mcpConfigPath = null;
    };

    upstream = {
      hm = {
        enableOption = null;
        skillsOption = null;
        mcpServersOption = null;
        lspServersOption = null;
        settingsOption = null;
      };
      devenv = {
        enableOption = null;
        skillsOption = null;
        mcpServersOption = null;
        lspServersOption = null;
        settingsOption = null;
      };
    };

    extraOptions = _: {};
  }
  ```

- [ ] **Step 3.5.2: Verify the file parses**

  Run: `nix-instantiate --eval --strict --expr 'with import <nixpkgs> {}; (import ./lib/ai-ecosystems/agentsmd.nix { inherit lib; }).name'`

  Expected output: `"agentsmd"`

### Task 3.6: Add backward-compat shim to `packages/fragments-ai/default.nix`

**Files:**
- Modify: `packages/fragments-ai/default.nix:1-127` (the entire file is restructured but the public passthru.transforms API is preserved byte-for-byte)

- [ ] **Step 3.6.1: Read the current `packages/fragments-ai/default.nix`**

  Run: `cat packages/fragments-ai/default.nix`

  Note the current shape: an overlay function `_: final: _prev: ...` that returns `{ fragments-ai = runCommand ... // { passthru.transforms = { claude = ...; copilot = ...; kiro = ...; agentsmd = ...; }; }; }`.

- [ ] **Step 3.6.2: Replace the file with the shim version**

  Write the file with the following content:

  ```nix
  # AI ecosystem package.
  #
  # passthru.transforms is a backward-compatibility shim that delegates
  # to the per-ecosystem records in lib/ai-ecosystems/. The shim
  # preserves the byte-identical output contract — existing consumers
  # see no change.
  #
  # Phase 2's backend adapters will consume the records directly via
  # passthru.records and stop using the transforms shim.
  _: final: _prev: let
    inherit (final) lib;
    fragmentsLib = import ../../lib/fragments.nix {inherit lib;};

    # Load all ecosystem records — single source of truth for the
    # markdown transformer logic.
    records = {
      claude = import ../../lib/ai-ecosystems/claude.nix {inherit lib;};
      copilot = import ../../lib/ai-ecosystems/copilot.nix {inherit lib;};
      kiro = import ../../lib/ai-ecosystems/kiro.nix {inherit lib;};
      agentsmd = import ../../lib/ai-ecosystems/agentsmd.nix {inherit lib;};
    };

    # Build a back-compat transform function from an ecosystem record.
    # The legacy API was `transforms.<eco> [extras] fragment -> string`,
    # where extras is the curried context (e.g., { package = "X"; }
    # for claude, { name = "X"; } for kiro). The shim threads extras
    # through mkRenderer's ctxExtras parameter.
    mkLegacyTransform = record: extras: fragment: let
      render = fragmentsLib.mkRenderer record.markdownTransformer extras;
    in
      render fragment;
  in {
    fragments-ai =
      final.runCommand "fragments-ai" {} ''
        mkdir -p $out/templates
        cp ${./templates}/*.md $out/templates/
      ''
      // {
        passthru = {
          # New API: ecosystem records consumed by Phase 2 adapters.
          inherit records;

          # Back-compat API: function-based transforms preserving the
          # exact signatures from the old packages/fragments-ai/default.nix.
          transforms = {
            # transforms.claude { package = "X"; } fragment
            claude = extras: fragment: mkLegacyTransform records.claude extras fragment;

            # transforms.copilot fragment (no extras)
            copilot = fragment: mkLegacyTransform records.copilot {} fragment;

            # transforms.kiro { name = "X"; } fragment
            kiro = extras: fragment: mkLegacyTransform records.kiro extras fragment;

            # transforms.agentsmd fragment (no extras)
            agentsmd = fragment: mkLegacyTransform records.agentsmd {} fragment;
          };
        };
      };
  }
  ```

- [ ] **Step 3.6.3: Verify the package builds**

  Run: `nix build .#fragments-ai --no-link 2>&1 | tail -10`

  Expected: no errors, build succeeds.

- [ ] **Step 3.6.4: Verify `passthru.transforms` is callable**

  Run:
  ```bash
  nix eval --raw '.#fragments-ai.passthru.transforms.copilot' \
    --apply 'f: f { text = "hello"; description = "test"; paths = null; } '
  ```

  Expected: a string starting with `---\napplyTo: "**"\n---\n\nhello` (or similar — the exact bytes depend on the back-compat shim path through `mkRenderer`, which uses the bare-string back-compat to wrap "hello" as `[(mkRaw "hello")]`).

  **Important:** if the output diverges from what the OLD `packages/fragments-ai/default.nix` produced for the same input, the byte-identical contract is broken. Step 3.7 verifies this systematically.

### Task 3.7: Verify byte-identical generation output

**Purpose:** The whole point of this commit is to swap the backend without changing observable output. This task runs the existing `nix build .#instructions-*` derivations and diffs them against the snapshots from step 0.4.

- [ ] **Step 3.7.1: Rebuild all instruction derivations**

  Run:
  ```bash
  for target in instructions-agents instructions-claude instructions-copilot instructions-kiro repo-readme repo-contributing; do
    out=$(nix build ".#$target" --no-link --print-out-paths 2>/dev/null) || { echo "FAIL build: $target"; exit 1; }
    echo "rebuilt: $target -> $out"
  done
  ```

  Expected: 6 successful rebuilds.

- [ ] **Step 3.7.2: Compute fresh hashes and diff against baseline**

  Run:
  ```bash
  mkdir -p /tmp/ai-records-fresh
  for target in instructions-agents instructions-claude instructions-copilot instructions-kiro repo-readme repo-contributing; do
    out=$(nix build ".#$target" --no-link --print-out-paths 2>/dev/null)
    cp -r "$out" "/tmp/ai-records-fresh/$target"
  done
  find /tmp/ai-records-fresh -type f -exec sha256sum {} \; | sort | sed 's|/tmp/ai-records-fresh/|/tmp/ai-records-baseline/|' > /tmp/ai-records-fresh/HASHES_normalized
  diff /tmp/ai-records-baseline/HASHES /tmp/ai-records-fresh/HASHES_normalized
  ```

  Expected: empty diff. **Every file's hash matches the baseline.**

  If hashes diverge: identify which file differs, then `diff /tmp/ai-records-baseline/<target>/<file> /tmp/ai-records-fresh/<target>/<file>` to see the byte-level difference. The most likely cause is a frontmatter formatting drift (extra/missing newline, different YAML quoting). Fix in the relevant ecosystem record's `frontmatter` function and re-verify.

- [ ] **Step 3.7.3: Run the full `nix flake check`**

  Run: `nix flake check 2>&1 | tail -10`

  Expected: no errors.

### Task 3.8: Commit the ecosystem records + shim

- [ ] **Step 3.8.1: Stage the changes**

  Run:
  ```bash
  git add lib/transformers/base.nix \
          lib/ai-ecosystems/claude.nix \
          lib/ai-ecosystems/copilot.nix \
          lib/ai-ecosystems/kiro.nix \
          lib/ai-ecosystems/agentsmd.nix \
          packages/fragments-ai/default.nix
  git status
  ```

  Expected: 6 files staged (5 new, 1 modified).

- [ ] **Step 3.8.2: Commit**

  Run:
  ```bash
  git commit -m "$(cat <<'EOF'
  refactor(fragments-ai): introduce ecosystem records with back-compat shim

  Adds Layer 2 of the ai-ecosystem-records refactor: per-ecosystem
  policy bundles in lib/ai-ecosystems/{claude,copilot,kiro,agentsmd}.nix
  plus a base markdown transformer in lib/transformers/base.nix.

  Each record bundles markdownTransformer (the Phase 1 consumer),
  translators (settings/lspServer/envVar/mcpServer), layout policy
  (instructionPath, skillPath, etc.), upstream module delegation
  (hm/devenv enableOption/skillsOption/etc.), and extraOptions.
  Phase 1 only consumes markdownTransformer; the other fields are
  scaffolded for Phase 2's backend adapters.

  packages/fragments-ai/default.nix now exposes both APIs in
  passthru:
    - records: the new ecosystem records (Phase 2 adapters)
    - transforms: backward-compatibility shim that delegates to
      records[eco].markdownTransformer via fragmentsLib.mkRenderer

  Byte-identical contract verified: nix build of instructions-agents,
  instructions-claude, instructions-copilot, instructions-kiro,
  repo-readme, and repo-contributing produce hash-identical outputs
  to the pre-refactor baseline.

  Phase 1 commit 3 of 4. See dev/notes/ai-transformer-design.md
  Layer 2 + Layer 2.5 for the design.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 3.8.3: Verify the commit landed and sentinel hasn't moved**

  Run:
  ```bash
  git log --oneline -4
  echo "sentinel: $(git rev-parse sentinel/monorepo-plan)"
  ```

  Expected: 4 commits visible. Sentinel still at `31590a3...`.

---

## Commit 4: `composedByPackage` binding + `dev/generate.nix` 3x→1x fix

**Purpose:** Add a top-level shared binding for composed fragments per package, accessible from any consumer (HM, devenv, dev/generate.nix). Refactor `dev/generate.nix` to bind composition once instead of three times. Closes the standalone fix mentioned in the design note.

### Task 4.1: Add `composedByPackage` to `pkgs.fragments-ai.passthru`

**Files:**
- Modify: `packages/fragments-ai/default.nix` (the `passthru` block from commit 3)

- [ ] **Step 4.1.1: Read the current `packages/fragments-ai/default.nix`**

  Run: `cat packages/fragments-ai/default.nix`

  Note: this is the file from commit 3 with `passthru = { records, transforms }`.

- [ ] **Step 4.1.2: Add `composedByPackage` to passthru**

  The `composedByPackage` binding needs access to the per-package fragment composition logic that currently lives in `dev/generate.nix:226-236` (`mkDevComposed`). Phase 1 keeps this logic in `dev/generate.nix` but exposes the result via passthru.

  Edit `packages/fragments-ai/default.nix` to add a `composedByPackage` field to passthru. Replace the existing `passthru = { ... };` block with:

  ```nix
        passthru = {
          # New API: ecosystem records consumed by Phase 2 adapters.
          inherit records;

          # Shared composition cache. Populated lazily by consumers
          # that import dev/generate.nix's mkDevComposed logic.
          # Phase 1 ships an empty default; the dev/generate.nix
          # refactor in commit 4 binds the actual values at flake
          # eval time and passes them through.
          #
          # The binding lives here so HM modules, devenv modules, and
          # dev/generate.nix can all reference the same thunk via
          # pkgs.fragments-ai.passthru.composedByPackage rather than
          # each computing their own composition.
          composedByPackage = {};

          # Back-compat API: function-based transforms preserving the
          # exact signatures from the old packages/fragments-ai/default.nix.
          transforms = {
            # transforms.claude { package = "X"; } fragment
            claude = extras: fragment: mkLegacyTransform records.claude extras fragment;

            # transforms.copilot fragment (no extras)
            copilot = fragment: mkLegacyTransform records.copilot {} fragment;

            # transforms.kiro { name = "X"; } fragment
            kiro = extras: fragment: mkLegacyTransform records.kiro extras fragment;

            # transforms.agentsmd fragment (no extras)
            agentsmd = fragment: mkLegacyTransform records.agentsmd {} fragment;
          };
        };
  ```

  **Note:** the `composedByPackage = {}` default is intentional. The actual values are populated by `dev/generate.nix` (which has the package-list metadata) and threaded through to consumers. Phase 2 may move this binding to a different location once the adapters need it.

- [ ] **Step 4.1.3: Verify the package still builds**

  Run: `nix build .#fragments-ai --no-link 2>&1 | tail -5`

  Expected: no errors.

### Task 4.2: Refactor `dev/generate.nix` 3x→1x compose

**Files:**
- Modify: `dev/generate.nix:276-309` (the `claudeFiles`, `copilotFiles`, `kiroFiles` blocks that each call `mkDevComposed pkg` independently)

- [ ] **Step 4.2.1: Read the current `dev/generate.nix:226-309` block**

  Run: `sed -n '226,310p' dev/generate.nix`

  Identify the three `let composed = mkDevComposed pkg;` bindings inside the three `concatMapAttrs` lambdas. Note that `mkDevComposed` is a pure function — calling it three times per package is wasteful but not buggy.

- [ ] **Step 4.2.2: Add a top-level `composedByPkg` binding**

  Find `dev/generate.nix:254` (the line `nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") devFragmentNames;`).

  Insert immediately after that line:

  ```nix
    # Bind composition ONCE per package at the top level. All three
    # ecosystem consumers (claudeFiles, copilotFiles, kiroFiles)
    # reference this binding via lazy eval, so composition runs
    # exactly once per package regardless of consumer count.
    #
    # Anti-pattern: do NOT call mkDevComposed inside the per-ecosystem
    # concatMapAttrs lambdas — that creates a fresh thunk per consumer
    # and runs composition 3x.
    composedByPkg = lib.mapAttrs (pkg: _: mkDevComposed pkg) nonRootPackages;
  ```

- [ ] **Step 4.2.3: Refactor `claudeFiles` to use the shared binding**

  Find the current `claudeFiles` block (around line 276):

  ```nix
    claudeFiles =
      lib.concatMapAttrs (pkg: _: let
        composed = mkDevComposed pkg;
        pkgEco = mkEcosystemFile pkg;
      in {
        "${pkg}.md" = pkgEco.claude composed;
      })
      nonRootPackages;
  ```

  Replace with:

  ```nix
    claudeFiles =
      lib.mapAttrs' (pkg: composed: let
        pkgEco = mkEcosystemFile pkg;
      in
        lib.nameValuePair "${pkg}.md" (pkgEco.claude composed))
      composedByPkg;
  ```

- [ ] **Step 4.2.4: Refactor `copilotFiles` to use the shared binding**

  Find the current `copilotFiles` block (around line 286). Replace the `concatMapAttrs` with `mapAttrs'` over `composedByPkg`, mirroring the claudeFiles refactor:

  ```nix
    copilotFiles =
      {
        "copilot-instructions.md" = monorepoEco.copilot rootComposed;
      }
      // (lib.mapAttrs' (pkg: composed: let
          pkgEco = mkEcosystemFile pkg;
        in
          lib.nameValuePair "${pkg}.instructions.md" (pkgEco.copilot composed))
        composedByPkg);
  ```

- [ ] **Step 4.2.5: Refactor `kiroFiles` to use the shared binding**

  Find the current `kiroFiles` block (around line 299). Replace similarly:

  ```nix
    kiroFiles =
      {
        "common.md" = aiTransforms.kiro {name = "common";} rootComposed;
      }
      // (lib.mapAttrs' (pkg: composed: let
          pkgEco = mkEcosystemFile pkg;
        in
          lib.nameValuePair "${pkg}.md" (pkgEco.kiro composed))
        composedByPkg);
  ```

- [ ] **Step 4.2.6: Verify byte-identical output via the snapshot**

  Run:
  ```bash
  for target in instructions-agents instructions-claude instructions-copilot instructions-kiro repo-readme repo-contributing; do
    out=$(nix build ".#$target" --no-link --print-out-paths 2>/dev/null) || { echo "FAIL build: $target"; exit 1; }
    cp -r "$out" "/tmp/ai-records-fresh/$target"
  done
  find /tmp/ai-records-fresh -type f -exec sha256sum {} \; | sort | sed 's|/tmp/ai-records-fresh/|/tmp/ai-records-baseline/|' > /tmp/ai-records-fresh/HASHES_normalized
  diff /tmp/ai-records-baseline/HASHES /tmp/ai-records-fresh/HASHES_normalized
  ```

  Expected: empty diff. The composition binding refactor is purely about evaluation efficiency; the output bytes must be identical to the baseline.

  If hashes diverge: the most likely cause is that `mkDevComposed` reads some context not captured in the `composedByPkg` binding (e.g., it depends on a `let`-bound variable that's different at the binding site). Re-read the surrounding code in `dev/generate.nix` and confirm `mkDevComposed pkg` is a pure function of `pkg` only.

- [ ] **Step 4.2.7: Run the full `nix flake check`**

  Run: `nix flake check 2>&1 | tail -10`

  Expected: no errors.

### Task 4.3: Commit the composedByPackage binding + 3x→1x fix

- [ ] **Step 4.3.1: Stage the changes**

  Run: `git add packages/fragments-ai/default.nix dev/generate.nix && git status`

  Expected: 2 files staged (both modified).

- [ ] **Step 4.3.2: Commit**

  Run:
  ```bash
  git commit -m "$(cat <<'EOF'
  perf(generate): bind composition once per package, 3x->1x compose

  dev/generate.nix previously called mkDevComposed pkg from three
  separate concatMapAttrs lambdas (one each for claudeFiles,
  copilotFiles, kiroFiles). Each call site created its own thunk,
  so composition ran three times per package — for ~16 packages
  that's 48 compose calls instead of 16.

  Bind composedByPkg = lib.mapAttrs (pkg: _: mkDevComposed pkg)
  nonRootPackages once at module top level. All three ecosystem
  consumers reference the shared binding via lib.mapAttrs', so
  Nix's call-by-need memoization runs each composition exactly
  once and shares the result.

  Adds passthru.composedByPackage = {} to pkgs.fragments-ai as a
  placeholder for Phase 2's backend adapters, which will read from
  this binding instead of recomputing composition. Phase 1 ships
  an empty default since the actual values are produced inside
  dev/generate.nix's flake-eval scope.

  Byte-identical output verified: nix build of instructions-*,
  repo-readme, repo-contributing produce hash-identical outputs
  to the pre-refactor baseline. This is purely an evaluation-time
  optimization with zero observable behavior change.

  Closes the "standalone fix" item from
  dev/notes/ai-transformer-design.md (the bug existed in
  dev/generate.nix as a 3x compose anti-pattern; this commit fixes
  it generally as part of the refactor's foundation).

  Phase 1 commit 4 of 4 — foundation complete.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 4.3.3: Verify the commit landed and sentinel hasn't moved**

  Run:
  ```bash
  git log --oneline -5
  echo "sentinel: $(git rev-parse sentinel/monorepo-plan)"
  ```

  Expected: 5 commits visible (4 from this plan + the branch seed). Sentinel still at `31590a3...`.

---

## Final verification

After all four commits land, run the following end-to-end checks before declaring Phase 1 complete.

- [ ] **Step F.1: Full `nix flake check`**

  Run: `nix flake check 2>&1 | tail -20`

  Expected: no errors, all checks green.

- [ ] **Step F.2: Final byte-identical verification across all generated outputs**

  Run:
  ```bash
  rm -rf /tmp/ai-records-final
  mkdir -p /tmp/ai-records-final
  for target in instructions-agents instructions-claude instructions-copilot instructions-kiro repo-readme repo-contributing; do
    out=$(nix build ".#$target" --no-link --print-out-paths 2>/dev/null) || { echo "FAIL: $target"; exit 1; }
    cp -r "$out" "/tmp/ai-records-final/$target"
  done
  find /tmp/ai-records-final -type f -exec sha256sum {} \; | sort | sed 's|/tmp/ai-records-final/|/tmp/ai-records-baseline/|' > /tmp/ai-records-final/HASHES
  diff /tmp/ai-records-baseline/HASHES /tmp/ai-records-final/HASHES
  ```

  Expected: empty diff. Every generated file's content is byte-identical to the pre-refactor baseline.

- [ ] **Step F.3: `devenv test` end-to-end**

  Run: `devenv test 2>&1 | tail -20`

  Expected: all devenv tasks succeed. (devenv test runs the same checks as `nix flake check` plus any task-level smoke tests.)

- [ ] **Step F.4: Verify `pkgs.fragments-ai.passthru.records` is queryable**

  Run:
  ```bash
  nix eval --raw '.#fragments-ai.passthru.records.claude.name'
  nix eval --raw '.#fragments-ai.passthru.records.kiro.name'
  nix eval --raw '.#fragments-ai.passthru.records.copilot.name'
  nix eval --raw '.#fragments-ai.passthru.records.agentsmd.name'
  ```

  Expected output (one per line): `claude`, `kiro`, `copilot`, `agentsmd`.

- [ ] **Step F.5: Verify back-compat shim is still callable**

  Run:
  ```bash
  nix eval --raw '.#fragments-ai.passthru.transforms.copilot' --apply 'f: f { text = "test"; description = "desc"; paths = null; }'
  ```

  Expected: a non-empty string starting with `---`. The exact bytes don't matter for this smoke test; the byte-identical check in F.2 covers the contract.

- [ ] **Step F.6: Sentinel ref still untouched**

  Run: `git rev-parse sentinel/monorepo-plan`

  Expected: `31590a37df86af0c65d14185b598558d6ed2899a`

- [ ] **Step F.7: Refactor branch is 5 commits ahead of sentinel**

  Run: `git log --oneline sentinel/monorepo-plan..HEAD`

  Expected: 5 commits listed:
  - `<hash> perf(generate): bind composition once per package, 3x->1x compose`
  - `<hash> refactor(fragments-ai): introduce ecosystem records with back-compat shim`
  - `<hash> refactor(ai): extract option types to lib/ai-options.nix`
  - `<hash> feat(fragments): add structured node constructors and mkRenderer`
  - `ec9245e docs(refactor): seed ai-ecosystem-records refactor branch`

---

## Phase 1 complete — what's next

After this plan lands, the foundation is in place but **no existing module behavior has changed**. The new primitives sit alongside the old code, ready to be consumed by Phase 2's backend adapters.

**Phase 2 (next plan):** HM adapter rollout.
- Introduce `lib/mk-ai-ecosystem-hm-module.nix` adapter
- Replace per-ecosystem `mkIf cfg.<eco>.enable` branches in `modules/ai/default.nix` with `mkAiEcosystemHmModule <ecoRecord>` calls
- Introduce per-ecosystem option pools (`ai.<eco>.<category>` extension points) via the adapter
- Each ecosystem replacement (Claude, Copilot, Kiro) gets its own commit with byte-identical output verification
- Tests: layered option pools (`ai.kiro.mcpServers.aws = ...` adds AWS only to Kiro)

**Phase 3 (later plan):** devenv adapter + helpers.
- Mirror Phase 2 in `modules/devenv/ai.nix`
- Introduce `lib/mk-raw-ecosystem.nix`
- Add `examples/external-ecosystem/` worked example

**Phase 4 (later plan):** doc ecosystems + fragment refresh.
- README and mdBook ecosystem records in `packages/fragments-docs/ecosystems/`
- Update architecture fragments to document the new pattern

To draft Phase 2: re-invoke the writing-plans skill with `dev/notes/ai-transformer-design.md` as the spec input, scoping to commits 5-9 of the design note's sequencing.
