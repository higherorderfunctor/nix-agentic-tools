# Agent-Primitive Labs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> `superpowers:subagent-driven-development` to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking. Do **not** use
> `superpowers:executing-plans`.

**Goal:** Stand up `labs/<name>/lab.nix` definitions plus a `lab:*` task family
that materializes each lab into an isolated clean-room directory outside
`$HOME`, with a home-manager-generated fake user-global config root and a
devenv-generated project scope, for manual experimentation with agentic
primitives against the real Claude and Kiro CLIs.

**Architecture:** One file per lab declares two optional scopes. `global` feeds
an auto-discovered `homeConfigurations.lab-<name>`; building `config.home-files`
yields the materialized dotfile farm, which is copied (never activated) into the
lab's writable fake home and pointed at via `CLAUDE_CONFIG_DIR`/`KIRO_HOME`.
`project` feeds a generated `devenv.nix` in the lab that imports this repo's
devenv modules **by absolute path** — devenv 2.x imposes no source boundary, so
repo edits invalidate the lab's eval cache live.

**Tech Stack:** Nix flakes, home-manager (new input), devenv 2.1.3, direnv,
bash.

## Global Constraints

- **Where the docs live vs. where the work happens.** This plan and its
  companion spec are canonical in the **main checkout** on
  `refactor/ai-factory-architecture`:
  - plan —
    `/home/caubut/Documents/projects/nix-agentic-tools/docs/plans/agent-primitive-labs-impl-plan.md`
  - spec —
    `/home/caubut/Documents/projects/nix-agentic-tools/docs/plans/agent-primitive-labs-design.md`

  **All code changes happen in the worktree** at
  `/home/caubut/Documents/projects/nix-agentic-tools-worktrees/agent-primitive-labs`
  (branch `refactor/agent-primitive-labs`). Do not copy the docs into the
  worktree — they are read from the absolute paths above and updated in place
  there. Step-tick updates and any spec corrections go to the main-checkout
  copies.

- **Companion spec:** read it before starting. Every empirical claim below is
  verified there; do not re-derive.
- **All shell scripts use full strict mode.** Never the abbreviated form:
  ```bash
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  ```
  This applies to task `exec` bodies, generated `.envrc` files, and heredocs in
  Nix.
- **Labs materialize under `/var/tmp/nat-labs/`.** Load-bearing: anything under
  `$HOME` inherits `~/.claude/CLAUDE.md` via Claude's ancestor walk, which no
  env var suppresses without also killing the lab's own `CLAUDE.md`.
  `$XDG_STATE_HOME` resolves under `$HOME` and is **not** acceptable.
- **Never set `XDG_DATA_HOME` or `HOME`** in lab environments — both destroy
  Kiro's auth DB (`~/.local/share/kiro-cli/data.sqlite3`).
- **Copy home-files with `cp -rL … && chmod -R u+w`.** `--no-preserve=mode`
  silently strips the exec bit off `.claude/hooks/*`.
- **Alphabetical ordering** within categorical groups — flake inputs, task
  attrsets, option declarations.
- **Conventional Commits**, lowercase imperative, no trailing period. Scope
  `labs` for this workstream.
- **Do not touch** `packages/claude-code/lib/mkClaude.nix:659` or the
  `devenvModules.default` doc bug during Tasks 1-6 — they are parked as P1 and
  P3 below. Labs work around them. Anything else out-of-scope you discover
  mid-task gets **parked**, not chased: append it to the Parked items section
  with evidence and keep going.
- **`statix` W20 fires at 3+ keys sharing a top-level prefix in one attrset.**
  Three flat `ai.*` entries fail the pre-commit hook; nest them under a single
  `ai = { … };`. Two flat entries are fine.
- **Do not add assertions, golden files, or `checks/` entries.** A regression
  layer is an explicit non-goal (spec §1).
- **`nix flake check` must stay green** after every task.

---

## REVISED SCOPE — 2026-07-21 (governs everything below)

A prior-art survey (nmt, nix-unit, NixOS VM tests, throwaway-`$HOME` activation)
plus a re-read of the stated goal produced a **TRIM**. This section is
authoritative where it conflicts with the task text below.

**Why.** Three different goals were bundled into one plan, and they have
different cheapest tools:

| Goal                                                    | Cheapest adequate tool                               |
| ------------------------------------------------------- | ---------------------------------------------------- |
| Learn how the CLIs resolve precedence                   | **Already answered** — `strace` results in spec §2.2 |
| Verify the factory emits the right bytes                | **nmt** — parked as P11, not this plan               |
| Clean room for skill / model / effort / hook primitives | **The labs** — no substitute exists                  |

The sharpest finding: **a home-manager fixture is epistemically inert for
precedence.** Precedence is resolved by the CLI reading files off disk; whether
the fake global came from `home-files`, `mkdir -p`, or `printf`, the CLI's
answer is byte-identical. The HM machinery earns its keep for _emission
fidelity_, not for precedence.

**User intent, clarified 2026-07-21:** the goal is **both** — test CLI behaviour
in order to write good modules, then verify those modules work. That is a
pipeline: labs answer the CLI half empirically; nmt (P11) verifies the emission
half. It does not resurrect the cut tasks.

### Revised execution order

| Order   | Task                                               | Status                          |
| ------- | -------------------------------------------------- | ------------------------------- |
| —       | Task 1 — HM input + `homeConfigurations` discovery | **DONE** (`df6a3392..96b72778`) |
| **1st** | Task 6 — Kiro `KIRO_HOME`/`hooks/` HITL probe      | **RUN FIRST**                   |
| 2nd     | Task 2 — `lab:up`, descoped                        | KEEP                            |
| 3rd     | Task 5 — skill-trigger lab                         | KEEP, promoted                  |
| —       | Task 3 — generated devenv project scope            | **CUT**                         |
| —       | Task 4 — `lab:down`/`ls`/`reset`                   | **CUT** to a single `reset`     |

**Task 6 runs first** because it does not depend on Tasks 2-4, and it is the
highest-value unknown in the area: if `KIRO_HOME` does not cover `hooks/`, a
Kiro-hook lab silently fires the developer's real global hooks, and the value of
HM-delivered Kiro config changes materially. Its answer should inform the rest.

**Task 2 INTERFACE CHANGE (2026-07-21, forced by a real devenv limitation).**
`lab:up` is NOT a devenv task. It is a standalone script:

```bash
dev/scripts/lab-up.sh <name>
```

_Why:_ `devenv tasks run <task> -- <arg>` has **no positional-argument
channel**. devenv 2.1.3 treats everything after `run` — including after `--` —
as further task names, so `devenv tasks run lab:up -- hello` fails with
`× Task does not exist: hello`. Verified against `--help`, two alternate
invocation shapes, and `strings` on the installed binary: the only parameter
channel is a declared `tasks.<name>.input` consumed via `--input name=hello` →
`$DEVENV_TASK_INPUT` (JSON), which would make the everyday invocation
`devenv tasks run lab:up --input name=hello` and force a `jq` parse in the body.

_Why a script rather than a `devenv scripts.<name>` entry:_ the repo declares
**zero** `scripts.<name>` entries and **eleven** files under `dev/scripts/`.
`dev/scripts/kiro-memory-hitl.sh` is the closest precedent — a user-run script
that builds into a throwaway scratch dir and never touches real config. Match it
rather than introducing a new pattern. Positional args work naturally, and
nothing about materializing a lab needs devenv's task DAG.

**Task 2 descope:** materialize `home-files` into the lab dir and export
`CLAUDE_CONFIG_DIR` / `KIRO_HOME` / `CLAUDE_SECURESTORAGE_CONFIG_DIR=`. That is
the load-bearing part. The activation-snippet replay and trust-gate seeding stay
(they are required for a usable clean room); the generated `.envrc` stays. Skip
anything beyond that.

**Task 4 descope:** one `lab:reset` = `rm -rf "$LAB" && lab:up`. `lab:ls` is
`ls`. Three lifecycle verbs for a directory under `/var/tmp` is ceremony.

**Cut tasks are retained below, not deleted** — marked `[CUT]` with the reason,
so the reasoning survives if a later experiment resurrects them.

**What would resurrect Task 3:** a specific _cross-backend divergence_ concern —
`hmTransform` and `devenvTransform` lowering the same typed input to different
shapes, which only a live CLI reading both scopes at once would reveal. Test
that cheaply first: `printf` a project `.claude/settings.json` next to a
materialized lab and run `claude --debug`. If that surfaces a divergence,
generating the project scope from the real devenv module stops being ceremony
and becomes the point.

---

### Task 1: home-manager input + lab discovery + first `homeConfigurations` entry

**Files:**

- Modify: `flake.nix` (inputs block ~line 17-77; new `homeConfigurations` output
  after `devenvModules`, ~line 139)
- Create: `labs/hello/lab.nix`
- Modify: `devenv.yaml` (regenerated, not hand-edited)
- Modify: `flake.lock` (generated)

**Interfaces:**

- Consumes: nothing.
- Produces: flake output `homeConfigurations.lab-<name>` for every directory
  under `labs/`. Each lab file is an attrset
  `{ description :: str, global :: attrs ? {}, project :: attrs ? {} }`. Task 2
  builds `homeConfigurations.lab-<name>.config.home-files`; Task 3 reads
  `.project`.

- [ ] **Step 1: Add the `home-manager` flake input**

In `flake.nix`, insert **alphabetically between `git-hooks` and `mcp-nixos`**:

```nix
    # home-manager — used ONLY to build `homeConfigurations.lab-*`
    # into a fake user-global config root for labs/ (see
    # docs/plans/agent-primitive-labs-design.md). Never activated.
    # Rev matches the nixos-config pin so the store entry is shared.
    home-manager = {
      url = "github:nix-community/home-manager/a02190edf9a79d8da191da75eced1ce1ae5e2408";
      inputs.nixpkgs.follows = "nixpkgs";
    };
```

- [ ] **Step 2: Create the first lab definition**

Create `labs/hello/lab.nix`:

```nix
# Smoke lab — proves the harness works end to end. Not a real experiment.
{
  description = "Smoke test: does a lab materialize a usable fake global?";

  global = {
    ai = {
      claude.enable = true;
      context = "You are running inside the nix-agentic-tools `hello` lab.";
      # Non-empty settings is REQUIRED for settings.json to be emitted at all.
      # Upstream home-manager gates the file behind
      #   cfg.settings != {} || cfg.marketplaces != {} || disabledMcpServerNames != []
      # (home-manager modules/programs/claude-code/default.nix:235), so a lab with
      # no settings produces .claude/CLAUDE.md and nothing else. Task 2 Step 5
      # asserts settings.json exists, and every real lab sets effort or model
      # anyway — so the smoke lab carries one too.
      # Valid values (overlays/claude-code-extracted.json): low medium high xhigh.
      claude.settings.effortLevel = "high";
    };
  };

  project = {
    ai.claude.enable = true;
  };
}
```

**Nesting is mandatory, not stylistic.** This repo's `statix` pre-commit hook
raises W20 ("repeated keys") once an attrset has **3 or more** entries sharing a
top-level prefix, so three flat `ai.*` keys fail the commit. Two are fine —
which is why `project` above stays flat. Any lab or snippet that stacks 3+
`ai.*` keys must use the nested form. Verified semantically identical: same
`nix eval` result and an unchanged `home-manager-files` store path before and
after.

- [ ] **Step 3: Add lab discovery and the `homeConfigurations` output**

In `flake.nix`, add to the `let` block alongside `packagesBarrel` (~line 99):

```nix
    # ── Labs ────────────────────────────────────────────────────────────
    # Auto-discovered from labs/. Adding a lab is adding a directory —
    # no flake edit. See docs/plans/agent-primitive-labs-design.md.
    labNames = lib.attrNames (
      lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./labs)
    );
    labDef = name: import (./labs + "/${name}/lab.nix");
```

Then add a new top-level output immediately after the `devenvModules` block:

```nix
    # Fake user-global config roots for labs/. Build
    # `.config.home-files` (0.9s) — NOT `.activationPackage`, which drags
    # in a 1.5 GiB closure including the claude CLI itself.
    homeConfigurations = lib.genAttrs (map (n: "lab-${n}") labNames) (
      attrName: let
        name = lib.removePrefix "lab-" attrName;
        def = labDef name;
      in
        inputs.home-manager.lib.homeManagerConfiguration {
          pkgs = pkgsFor "x86_64-linux";
          modules = [
            self.homeManagerModules.default
            (def.global or {})
            {
              home = {
                username = "lab";
                homeDirectory = "/home/lab";
                stateVersion = "24.11";
              };
              programs.home-manager.enable = false;
              # Drops the 1.3 GiB home-manager-path tail. The lab uses the
              # developer's own claude/kiro binaries, not HM-installed ones.
              programs.claude-code.package = lib.mkForce null;
            }
          ];
        }
    );
```

- [ ] **Step 4: Regenerate `devenv.yaml` and update the lock**

```bash
nix flake lock
nix eval --raw --impure --expr 'import ./config/generate-devenv-yaml.nix {}' >devenv.yaml
```

Expected: `flake.lock` gains a `home-manager` node; `devenv.yaml` gains a
`home-manager:` entry with `follows: nixpkgs`. The generator emits every root
input — there is no exclusion mechanism and we are not adding one.

**Do not run `devenv tasks run generate:devenv-yaml` — that task does not
exist.** The generated `devenv.yaml` header and
`config/generate-devenv-yaml.nix:3` both name it, but `dev/tasks/generate.nix`
never defined it. The `nix eval` line above is the real mechanism, copied from
`dev/scripts/update-input.sh:42`. (Discovered during Task 1 execution; the stale
comment is logged as a follow-up below and is deliberately NOT fixed here — out
of scope.)

- [ ] **Step 5: Verify the fake global builds**

```bash
nix build .#homeConfigurations.lab-hello.config.home-files --max-jobs 1 --no-link --print-out-paths
```

Expected: a single `/nix/store/…-home-manager-files` path, roughly 1s after the
first eval. Then:

```bash
ls -R "$(nix build .#homeConfigurations.lab-hello.config.home-files --no-link --print-out-paths)" | head -30
```

Expected: a `.claude/` directory containing at minimum `CLAUDE.md` and
`settings.json`.

- [ ] **Step 6: Verify nothing else regressed**

```bash
nix flake check --max-jobs 1
```

Expected: passes. If `checks.formatting` fails on `labs/hello/lab.nix`, run
`nix fmt labs/hello/lab.nix` and re-run.

- [ ] **Step 7: Commit**

```bash
git add flake.nix flake.lock devenv.yaml labs/hello/lab.nix
git commit -m "feat(labs): add home-manager input and lab homeConfigurations discovery"
```

---

### Task 2: `lab:up` — materialize the fake global

**Files:**

- Create: `dev/tasks/lab.nix`
- Modify: `devenv.nix:339-343` (tasks `let` block)

**Interfaces:**

- Consumes: `homeConfigurations.lab-<name>.config.home-files` from Task 1.
- Produces: `/var/tmp/nat-labs/<name>/home/` — a writable fake user-global root
  — and `/var/tmp/nat-labs/<name>/.envrc` exporting the isolation contract. Task
  3 adds the project scope alongside; Task 4 adds the sibling lifecycle tasks
  into the same `tasks` attrset in this file.

- [ ] **Step 1: Discover the activation-entry option path**

The three activation snippets (`claudeUnpinLaunchEffort`,
`copilotSettingsMerge`, `kiroSettingsMerge`) are **not** in `home-files` — they
only run at activation time. We replay them. First confirm the attribute that
carries the script body, because home-manager's `home.activation` is a DAG type
whose entries expose `.data`, not `.text`:

```bash
nix eval --json .#homeConfigurations.lab-hello.config.home.activation.claudeUnpinLaunchEffort 2>&1 | head -c 400
```

Expected: a JSON object with keys including `after`, `before`, and **`data`**.
Use whichever key holds the shell body in the next step. If the entry does not
exist for `lab-hello`, that is fine — it is only emitted when the relevant app
is enabled; the task must tolerate absence.

- [ ] **Step 2: Create the lab task file**

Create `dev/tasks/lab.nix`:

```nix
# dev/tasks/lab.nix — agent-primitive lab lifecycle.
# See docs/plans/agent-primitive-labs-design.md.
#
# Labs materialize OUTSIDE $HOME. This is load-bearing: Claude walks every
# ancestor directory for CLAUDE.md up to and including /home, so a lab under
# $HOME silently inherits ~/.claude/CLAUDE.md regardless of CLAUDE_CONFIG_DIR.
_: let
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';

  log = ''log() { echo "==> $*" >&2; }'';

  labRoot = "/var/tmp/nat-labs";

  # Resolve $1 into $name, erroring with the list of defined labs.
  requireName = ''
    name="''${1:-}"
    if [ -z "$name" ]; then
      log "usage: devenv tasks run lab:<verb> -- <name>"
      log "defined labs:"
      ls -1 labs/ >&2
      exit 2
    fi
    if [ ! -f "labs/$name/lab.nix" ]; then
      log "no such lab: $name (expected labs/$name/lab.nix)"
      exit 2
    fi
  '';
in {
  tasks = {
    "lab:up" = {
      description = "Materialize a lab into ${labRoot}/<name>/ (fake global + project scope)";
      exec = ''
        ${bashPreamble}
        ${log}
        ${requireName}

        lab="${labRoot}/$name"
        repo="$PWD"

        log "building fake user-global for '$name'"
        hf=$(nix build ".#homeConfigurations.lab-$name.config.home-files" \
              --max-jobs 1 --no-link --print-out-paths)

        log "materializing $lab"
        mkdir -p "$lab/home" "$lab/work"

        # -L dereferences store symlinks so the copy is self-contained and
        # writable. chmod -R u+w AFTER the copy: --no-preserve=mode would
        # strip the exec bit off .claude/hooks/*.
        cp -rL "$hf/." "$lab/home/"
        chmod -R u+w "$lab/home"

        # Replay activation-only writes. These jq merges never appear in
        # home-files. They are $HOME-parameterised and reference absolute
        # store paths, so they run standalone with HOME repointed.
        for entry in claudeUnpinLaunchEffort copilotSettingsMerge kiroSettingsMerge; do
          body=$(nix eval --raw \
            ".#homeConfigurations.lab-$name.config.home.activation.$entry.data" \
            2>/dev/null || true)
          if [ -z "$body" ]; then
            log "activation '$entry' not present — skipping"
            continue
          fi
          log "replaying activation '$entry'"
          # Stubs for the home-manager activation harness helpers that the
          # snippets may reference outside a real activation run.
          HOME="$lab/home" bash -c "
            ${bashPreamble}
            _iNote() { :; }
            _iWarn() { :; }
            run() { \"\$@\"; }
            VERBOSE_ARG=\"\"
            DRY_RUN_CMD=\"\"
            $body
          "
        done

        # Seed the trust gate. Without hasTrustDialogAccepted a
        # devenv-materialized .claude/settings.json is inert in a fresh dir.
        cj="$lab/home/.claude.json"
        [ -f "$cj" ] || echo '{}' >"$cj"
        tmp=$(mktemp)
        jq '.hasTrustDialogAccepted = true' "$cj" >"$tmp"
        mv "$tmp" "$cj"

        log "writing $lab/.envrc"
        cat >"$lab/.envrc" <<ENVRC
        #!/usr/bin/env bash
        # Generated by 'devenv tasks run lab:up -- $name'. Do not edit;
        # regenerate instead. Source of truth: labs/$name/lab.nix.

        # Clean-room user scope. HOME and XDG_DATA_HOME are deliberately
        # NOT set: both relocate Kiro's auth DB and destroy session state.
        export CLAUDE_CONFIG_DIR="$lab/home/.claude"
        export KIRO_HOME="$lab/home/.kiro"
        # Set-but-empty pins credentials and the keychain service name back
        # to the real ~/.claude, so auth survives the config redirect.
        export CLAUDE_SECURESTORAGE_CONFIG_DIR=""
        export NAT_LAB="$name"
        export NAT_LAB_REPO="$repo"
        ENVRC
        sed -i 's/^        //' "$lab/.envrc"

        log "lab '$name' ready:"
        echo "$lab/work"
      '';
    };
  };
}
```

- [ ] **Step 3: Wire the task file into devenv**

In `devenv.nix`, extend the `tasks` `let` block (currently lines 339-343) so the
bindings stay alphabetical:

```nix
  tasks = let
    checkTasks = (import ./dev/tasks/check.nix {}).tasks;
    generateTasks = (import ./dev/tasks/generate.nix {inherit lib;}).tasks;
    labTasks = (import ./dev/tasks/lab.nix {}).tasks;
```

Then add `labTasks` to the union expression that follows (match the existing
`//` chain, keeping alphabetical order).

- [ ] **Step 4: Run it**

```bash
devenv tasks run lab:up -- hello
```

Expected: `==>` progress lines ending in `/var/tmp/nat-labs/hello/work`.
Activation entries absent for this lab log `not present — skipping` rather than
failing.

- [ ] **Step 5: Verify the fake global is writable and correct**

```bash
L=/var/tmp/nat-labs/hello
test -f "$L/home/.claude/settings.json" && echo "settings OK"
test -w "$L/home/.claude/settings.json" && echo "writable OK"
jq -e '.hasTrustDialogAccepted == true' "$L/home/.claude.json" >/dev/null && echo "trust OK"
find "$L/home" -xtype l | head          # must print NOTHING
grep -c 'CLAUDE_SECURESTORAGE_CONFIG_DIR=""' "$L/.envrc"
```

Expected: `settings OK`, `writable OK`, `trust OK`, no dangling-symlink output,
and `1`.

If `find … -xtype l` prints anything, a lab used a raw skill source directory.
Those contain relative symlinks (`references/*.md -> ../../../references/*.md`)
that home-manager copies verbatim. Fix the **lab definition** to use
`ai.programs.stacked-workflows.enable = true` (the packaged, dereferenced path)
rather than pointing `ai.skills.*` at a repo source dir. Do not work around it
in the task.

- [ ] **Step 6: Commit**

```bash
git add dev/tasks/lab.nix devenv.nix
git commit -m "feat(labs): add lab:up task materializing the fake user-global"
```

---

### Task 3 [CUT]: project scope — generated devenv importing repo modules by absolute path

> **CUT 2026-07-21.** Existed to observe repo-vs-global interaction, which is
> already answered (spec §2.2). Skill / model / effort / subagent experiments
> are user-scope-only. Retained for the record; see "What would resurrect Task
> 3" in REVISED SCOPE. Until then `mkdir -p .claude && cp` covers any ad-hoc
> project scope a lab needs.

**Files:**

- Modify: `dev/tasks/lab.nix` (extend the `lab:up` exec body)

**Interfaces:**

- Consumes: `labs/<name>/lab.nix` `.project` attrset; `$repo` and `$lab` from
  Task 2's `lab:up`.
- Produces: `/var/tmp/nat-labs/<name>/work/{devenv.nix,devenv.yaml,.envrc}` — a
  devenv project that materializes `.claude/`, `AGENTS.md` etc. in place.

- [ ] **Step 1: Read the devenv rev the repo pins**

```bash
grep -A1 '^  devenv:' devenv.yaml
```

Expected: a `url: github:cachix/devenv/<rev>` line. The lab must pin the
**same** rev so the upstream `claude.code` module schema matches what our
modules feed it. Capture it dynamically rather than hardcoding.

- [ ] **Step 2: Extend `lab:up` to emit the project scope**

Insert this block into the `lab:up` exec body, immediately before the final
`log "lab '$name' ready:"`:

```bash
        # ── Project scope ────────────────────────────────────────────
        # devenv 2.x is NOT in flake mode: no .devenv/flake.nix is
        # generated and the project root stays a raw filesystem path
        # (resolve-lock.nix: outPath = src). So a lab outside the repo can
        # import repo modules by absolute path, and those files land in
        # .devenv/input-paths.txt — meaning repo module edits invalidate
        # the lab's eval cache live. This is why labs do NOT consume the
        # repo as a path: flake input.
        if nix eval --raw --impure \
             --expr "builtins.toString ((import $repo/labs/$name/lab.nix) ? project)" \
             2>/dev/null | grep -q '^1$'; then
          log "generating project scope"

          devenv_url=$(sed -n '/^  devenv:/{n;s/^    url: //p;}' "$repo/devenv.yaml")

          cat >"$lab/work/devenv.yaml" <<YAML
        # Generated by 'devenv tasks run lab:up -- $name'. Do not edit.
        # devenv rev MUST match the repo's so the upstream claude.code
        # module schema matches what our modules feed it.
        allowUnfree: true

        inputs:
          devenv:
            url: $devenv_url
        YAML
          sed -i 's/^        //' "$lab/work/devenv.yaml"

          cat >"$lab/work/devenv.nix" <<NIX
        # Generated by 'devenv tasks run lab:up -- $name'. Do not edit;
        # edit labs/$name/lab.nix and re-run lab:up.
        {lib, ...}: {
          imports = [
            $repo/lib/ai/sharedOptions.nix
            $repo/packages/claude-code/modules/devenv
            $repo/packages/copilot-cli/modules/devenv
            $repo/packages/kiro-cli/modules/devenv
          ];
        }
        // (import $repo/labs/$name/lab.nix).project
        NIX
          sed -i 's/^        //' "$lab/work/devenv.nix"

          printf '%s\n' 'eval "\$(devenv direnvrc)"' 'use devenv' >>"$lab/.envrc"
          ln -sfn "$lab/.envrc" "$lab/work/.envrc"
        fi
```

- [ ] **Step 3: Re-materialize and verify the project scope**

```bash
devenv tasks run lab:up -- hello
cd /var/tmp/nat-labs/hello/work && devenv shell -- true
```

Expected: devenv evaluates and exits 0.

```bash
test -L /var/tmp/nat-labs/hello/work/.claude/settings.json && echo "project settings OK"
readlink /var/tmp/nat-labs/hello/work/.claude/settings.json
```

Expected: `project settings OK`, and a `/nix/store/…-claude-settings.json`
target.

- [ ] **Step 4: Verify live invalidation of repo module edits**

This is the property that justifies absolute-path imports over a flake input.
Confirm it holds:

```bash
cd /var/tmp/nat-labs/hello/work
grep -c "$OLDPWD" .devenv/input-paths.txt 2>/dev/null || \
  grep -c 'nix-agentic-tools' .devenv/input-paths.txt
```

Expected: a non-zero count — the repo's module files are registered as tracked
eval inputs.

- [ ] **Step 5: Commit**

```bash
cd "$NAT_LAB_REPO" 2>/dev/null || cd -
git add dev/tasks/lab.nix
git commit -m "feat(labs): generate lab project scope from absolute-path module imports"
```

---

### Task 4 [CUT to one verb]: `lab:down`, `lab:reset`, `lab:ls`

> **DESCOPED 2026-07-21.** Keep only `lab:reset` = `rm -rf "$LAB" && lab:up`.
> `lab:ls` is `ls`; `lab:down` is `rm -rf`. Three lifecycle verbs for a
> `/var/tmp` directory is ceremony. Full text retained below for reference.

**Files:**

- Modify: `dev/tasks/lab.nix` (add three sibling tasks to the `tasks` attrset)

**Interfaces:**

- Consumes: `labRoot`, `bashPreamble`, `log`, `requireName` from Task 2.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Add the three tasks**

Add to the `tasks` attrset in `dev/tasks/lab.nix`, keeping keys alphabetical
(`lab:down`, `lab:ls`, `lab:reset`, `lab:up`):

```nix
    "lab:down" = {
      description = "Remove a materialized lab from ${labRoot} (tracked source untouched)";
      exec = ''
        ${bashPreamble}
        ${log}
        ${requireName}

        lab="${labRoot}/$name"
        if [ ! -d "$lab" ]; then
          log "lab '$name' is not materialized — nothing to do"
          exit 0
        fi
        log "removing $lab"
        chmod -R u+w "$lab"
        rm -rf "$lab"
      '';
    };

    "lab:ls" = {
      description = "List defined labs and whether each is materialized";
      exec = ''
        ${bashPreamble}
        for d in labs/*/; do
          n=$(basename "$d")
          if [ -d "${labRoot}/$n" ]; then
            state="materialized  ${labRoot}/$n/work"
          else
            state="defined"
          fi
          printf '%-24s %s\n' "$n" "$state"
        done
      '';
    };

    "lab:reset" = {
      description = "Tear a lab down and bring it back up — discards session state";
      exec = ''
        ${bashPreamble}
        ${log}
        ${requireName}
        log "resetting '$name'"
        devenv tasks run lab:down -- "$name"
        devenv tasks run lab:up -- "$name"
      '';
    };
```

- [ ] **Step 2: Verify the full lifecycle**

```bash
devenv tasks run lab:ls
devenv tasks run lab:reset -- hello
devenv tasks run lab:ls
devenv tasks run lab:down -- hello
test ! -d /var/tmp/nat-labs/hello && echo "down OK"
devenv tasks run lab:down -- hello
```

Expected: `lab:ls` shows `hello` as `defined` then `materialized` then
`defined`; `down OK`; and the second `lab:down` exits 0 with
`is not materialized — nothing to do` (idempotent, not an error).

- [ ] **Step 3: Commit**

```bash
git add dev/tasks/lab.nix
git commit -m "feat(labs): add lab:down, lab:ls and lab:reset lifecycle tasks"
```

---

### Task 5: First real lab — skill-trigger isolation

**Files:**

- Create: `labs/skill-trigger/lab.nix`
- Create: `labs/skill-trigger/skills/needle/SKILL.md`
- Create: `labs/skill-trigger/README.md`

**Interfaces:**

- Consumes: the whole harness from Tasks 1-4.
- Produces: the reference shape every later lab copies.

This lab answers the question the clean room exists for: **does a skill trigger
on its description alone, with nothing else competing?**

- [ ] **Step 1: Write the skill under test**

Create `labs/skill-trigger/skills/needle/SKILL.md`:

```markdown
---
name: needle
description: Use when the user asks to convert a duration into fortnights.
---

# Needle

Announce "NEEDLE-SKILL-FIRED" as the first line of your response, then convert
the duration the user gave into fortnights (1 fortnight = 14 days).
```

The sentinel string exists so triggering is observable without interpreting
prose.

- [ ] **Step 2: Write the lab definition**

Create `labs/skill-trigger/lab.nix`:

```nix
# Does a skill trigger on its description alone, in a clean room?
#
# The sentinel NEEDLE-SKILL-FIRED makes triggering observable. Run the lab,
# ask "how many fortnights is 100 days", and check whether the sentinel
# appears. Vary ONLY the description in skills/needle/SKILL.md between runs.
{
  description = "Skill triggering on description alone, zero competing skills";

  global = {
    ai.claude.enable = true;
    ai.skills.needle = ./skills/needle;
  };
}
```

Note the deliberate absence of `project` — skill triggering is a user-scope
concern, and omitting the project scope keeps the lab minimal.

- [ ] **Step 3: Write the lab README**

Create `labs/skill-trigger/README.md`:

```markdown
# skill-trigger

**Question:** does a skill trigger on its `description` alone, with no competing
skills, no global CLAUDE.md, and no MCP servers?

**Run:**

    devenv tasks run lab:up -- skill-trigger
    cd /var/tmp/nat-labs/skill-trigger/work
    claude

**Probe:** ask `how many fortnights is 100 days`.

**Observable:** the response begins with `NEEDLE-SKILL-FIRED` iff the skill
triggered.

**Vary:** edit `skills/needle/SKILL.md` — the lab source is symlinked into the
materialized dir, so edits apply on the next `claude` launch. Change only the
`description` frontmatter between runs; changing the body changes what firing
looks like, not whether it fires.

**Reset session state:** `devenv tasks run lab:reset -- skill-trigger`.
```

- [ ] **Step 4: Materialize and verify the skill landed in the fake global**

```bash
devenv tasks run lab:up -- skill-trigger
test -f /var/tmp/nat-labs/skill-trigger/home/.claude/skills/needle/SKILL.md && echo "skill OK"
grep -c 'NEEDLE-SKILL-FIRED' /var/tmp/nat-labs/skill-trigger/home/.claude/skills/needle/SKILL.md
```

Expected: `skill OK` and `1`.

- [ ] **Step 5: Verify the clean room is actually clean**

This is the assertion the entire design exists to satisfy.

```bash
L=/var/tmp/nat-labs/skill-trigger
ls "$L/home/.claude/skills/"          # expect: needle, and nothing else
test ! -e "$L/home/.claude/rules/stacked-workflows.md" && echo "no sws leak"
```

Expected: `needle` alone, and `no sws leak`. If other skills appear, the lab's
`global` is pulling in a package module it should not — fix the lab definition.

- [ ] **Step 6: Commit**

```bash
git add labs/skill-trigger
git commit -m "feat(labs): add skill-trigger lab probing description-only triggering"
```

---

### Task 6: Kiro `KIRO_HOME` hooks coverage — HITL probe

**Files:**

- Modify: the spec's §5 open items — record the outcome. **Absolute path, main
  checkout:**
  `/home/caubut/Documents/projects/nix-agentic-tools/docs/plans/agent-primitive-labs-design.md`
  (it is deliberately not present in the worktree)
- Modify: `dev/tasks/lab.nix` **only if** the probe shows `KIRO_HOME` does not
  cover `hooks/`

**Interfaces:**

- Consumes: a materialized lab from Task 2.
- Produces: a CONFIRMED or REFUTED answer replacing the UNVERIFIED entry in the
  spec.

**Why this is a separate task:** whether `KIRO_HOME` relocates `hooks/` is the
one load-bearing unknown left in the design. It is absent from Kiro's in-binary
2.3.0 changelog list, and `$KIRO_HOME/hooks` was never opened during a
non-interactive run — consistent with the recorded finding that v3 hooks fire
only in the TUI, and with Kiro 2.13.0 having added global `~/.kiro/hooks/`
firing in every workspace. **If `KIRO_HOME` does not cover `hooks/`, then any
Kiro-hook lab silently fires the developer's real global hooks and the clean
room is broken for that class of experiment.**

**This task requires a live interactive Kiro session and therefore cannot be
automated.** The implementing agent must walk the user through it synchronously,
one step at a time, waiting for the user's output after each — not batch the
instructions and not run it unattended.

- [ ] **Step 1: Agent — prepare the probe lab**

```bash
devenv tasks run lab:up -- hello
mkdir -p /var/tmp/nat-labs/hello/home/.kiro/hooks
cat >/var/tmp/nat-labs/hello/home/.kiro/hooks/probe.json <<'EOF'
{
  "name": "probe",
  "trigger": "Stop",
  "command": "sh -c 'echo LAB-HOOK-FIRED >> /tmp/nat-lab-hook-probe.log'"
}
EOF
rm -f /tmp/nat-lab-hook-probe.log
```

Adjust the JSON to the real Kiro hook schema first by reading an existing
example under `packages/kiro-cli/`; do not guess the field names.

- [ ] **Step 2: Agent — ask the user to run one command and paste the result**

Ask the user to run exactly:

```bash
cd /var/tmp/nat-labs/hello/work && direnv allow && kiro
```

…send one trivial message, exit, then report back. Wait for their response
before continuing.

- [ ] **Step 3: Agent — check whether the lab hook fired**

```bash
cat /tmp/nat-lab-hook-probe.log 2>/dev/null || echo "NOT FIRED"
```

- `LAB-HOOK-FIRED` present → `KIRO_HOME` **does** cover `hooks/`. CONFIRMED.
- `NOT FIRED` → `KIRO_HOME` does not cover `hooks/`. Ask the user whether any of
  their **real** global hooks fired during that session; if so, the leak is
  confirmed and Kiro-hook labs are unsafe until mitigated.

- [ ] **Step 4: Record the outcome in the spec**

Replace the `KIRO_HOME` bullet under `## 5. Open items` in
`/home/caubut/Documents/projects/nix-agentic-tools/docs/plans/agent-primitive-labs-design.md`
with the verified result, including the Kiro version tested and the method. If
REFUTED, add a `Known blockers` entry stating that Kiro-hook labs are not
isolated, and **stop** — do not invent a mitigation without checking with the
user first, per the standing rule against unilaterally choosing workarounds.

- [ ] **Step 5: Commit the spec update**

The spec is an untracked working doc. Do **not** `git add` it. Report the
outcome to the user instead and let them decide whether it graduates into
tracked docs.

---

## Parked items

**This is a plain design/execute plan.** This section is a **temporary staging
area**, not a permanent tracker.

The working rule during execution:

> **Fix little stuff as you run into it. Backlog anything needing HITL or more
> thought.**
>
> - _Little_ — mechanical, zero behavioral risk (stale comments, dead files,
>   wrong names in docs). Just fix it, in place, and keep going. Do not write it
>   up, do not defer it, do not ask.
> - _Bigger_ — behavioral changes, anything unconfirmed or undiagnosed, anything
>   with a real decision attached. Park it here with evidence and keep going.
>   Never stall the main body of work for either.

> **Exit gate — FIRED 2026-07-21.** Every parked item (P1–P14) was drained into
> `docs/plans/converge-agentic-foundations.md`, and the item bodies were deleted
> from this section per its own must-not-outlive rule. Full bodies remain in git
> history (commit `53526699`, this file pre-drain). New parkings must not use
> the retired register.

---

## Self-review

**Spec coverage.** §2.1 isolation levers → Task 2 Step 2 `.envrc`. §2.2
outside-`$HOME` → global constraint + `labRoot`. §2.3 absolute-path imports →
Task 3. §2.4 `home-files` not `activationPackage`, `cp -rL`+`chmod`,
`mkForce null`, no raw skill dirs → Tasks 1-2 and Task 2 Step 5. §2.5 activation
replay + `CLAUDE_CONFIG_DIR` export → Task 2 Step 2. §3.1 lab schema → Task 1.
§3.3 layout → Tasks 2-3. §3.5 lifecycle → Tasks 2 and 4. §4 blockers → global
constraint (untouched, worked around). §5 Kiro hooks → Task 6; cspell/treefmt →
Task 1 Step 6 handles it at the point it first bites, per the spec's "decide
when the first lab lands".

**Placeholder scan.** No TBD/TODO. Every code step carries complete content.
Task 6 Step 1 deliberately instructs reading the real hook schema rather than
trusting the illustrative JSON — that is a directed action, not a placeholder.

**Type consistency.** `labRoot`, `bashPreamble`, `log`, `requireName` are
defined once in Task 2 and referenced by name in Tasks 3-4. Lab schema
`{description, global?, project?}` is consistent across Tasks 1, 3 and 5.
`homeConfigurations.lab-<name>.config.home-files` is spelled identically in
Tasks 1, 2 and 3.

**Known soft spots** — verify rather than assume during execution:

- Task 2 Step 1 exists precisely because `.data` vs `.text` on activation DAG
  entries was not confirmed. Do not skip it.
- Task 3 Step 2's `? project` existence check via `nix eval --impure` is the
  least-certain construct in the plan. If it misbehaves, substitute a
  `grep -q '^\s*project\s*=' "labs/$name/lab.nix"` guard and note the change.
- Heredoc indent-stripping via `sed -i 's/^        //'` assumes exactly eight
  leading spaces. If the surrounding Nix indentation shifts, the generated files
  gain stray indentation — check the emitted `.envrc` and `devenv.nix` visually
  the first time.
