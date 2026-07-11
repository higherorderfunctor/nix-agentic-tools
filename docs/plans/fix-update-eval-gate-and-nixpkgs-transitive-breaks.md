# Fix: update-pipeline eval gate + nixpkgs transitive breakages

> **What this document is.** A self-contained implementation plan for an
> autonomous coding agent. It is being used to exercise Kimchi's `/ferment`
> mode: point Kimchi at this file after activating `/ferment`, and it should
> execute the plan end to end. A maintainer will review the resulting commit
> stack afterward. Please keep commits small and reviewable — see
> **Commit discipline** below; that section is the part a prior run got wrong.

---

## Bootstrap prompt (read first)

You are implementing four independent fixes in a Nix flake monorepo
(`nix-agentic-tools`). All four trace back to a single upstream event: a
`nixpkgs` input bump whose transitive effects broke three packages and exposed
a blind spot in the update pipeline's verification gate.

Your working rules for this task, in priority order:

1. **Do not run heavy Nix locally.** This machine OOMs on `nix build`,
   `nix-fast-build`, `nix flake check`, `nix-update`, and full-flake
   `nix eval` (our overlays use import-from-derivation, so even eval realises
   sources). **Make source edits, commit them as a stack, and push — CI does
   all building and verification.** If a step seems to need a local build to
   proceed, stop and leave a note in the commit/PR body instead.
2. **Use the repository's stacked-workflow skills for all commit work**, and
   produce **small, reviewable, atomic commits** — one logical change per
   commit. See **Commit discipline**. Do not hand-roll `git commit` /
   `git rebase` / `git absorb`.
3. **Follow the repo conventions** inlined under **Conventions** below (Bash
   strict mode, alphabetical ordering, DRY, Conventional Commits, `treefmt`
   after edits).
4. **Make exactly the changes specified.** Each task gives the precise file,
   the current code, and the replacement. Do not refactor surrounding code,
   rename things, or "improve" adjacent lines.

Deliverable: a 4-commit stack (optionally submitted as stacked PRs against
`refactor/ai-factory-architecture`) implementing Tasks 1–4, pushed so CI can
verify it.

---

## Context

A recent `nixpkgs` bump (flake input `nixpkgs`, new revision
`0bb7ec54c8483066ec9d7720e780a5caa71f8612`) shipped through the update
pipeline as PR **#350 (`update/nixpkgs`)**. That PR's CI fails on two packages
at build time, a third is held back by the update pipeline, and — separately —
the pipeline _should have withheld the bump_ but did not. The four fixes:

1. **`effect-mcp` fails to evaluate under the new nixpkgs.** New nixpkgs makes
   the default `pnpm` be `pnpm_11`, which dropped support for
   `fetchPnpmDeps { fetcherVersion = 3; }`. `effect-mcp` uses the default
   `pnpm`, so its `pnpmDeps` throws at eval time:
   `fetchPnpmDeps 'fetcherVersion = 3' is no longer supported for 'pnpm_11'`.
   (Its sibling `context7-mcp` already pins `pnpm_10`, so it is unaffected —
   that overlay is the template for the fix.)
2. **`git-revise` throws during `nix-update`.** nixpkgs' `git-revise`
   expression builds `meta.changelog` by interpolating `finalAttrs.src.tag`.
   Our overlay pins `src` to a bare commit `rev` (no tag), so `src.tag` is
   `null` and reading `meta.changelog` throws
   `cannot coerce null to a string`. This holds `git-revise` back from every
   update run.
3. **`kagi-mcp` fails its runtime-deps check under the new nixpkgs.** Upstream
   `kagimcp` pins `pydantic~=2.12.5`; the new nixpkgs ships `pydantic 2.13.4`,
   so `pythonRuntimeDepsCheckHook` fails the build with
   `pydantic~=2.12.5 not satisfied by version 2.13.4`.
4. **The update pipeline's build-verification gate cannot see eval failures.**
   `run_nfb_build` in `dev/scripts/update-common.sh` has three tripwires, all
   keyed on _build_ outcomes. `nix-fast-build` reports eval failures on a
   separate line (`ERROR:nix_fast_build:EVAL: N successes, M failures`) that no
   gate inspects, so the `effect-mcp` eval break above was invisible and the
   `nixpkgs` bump shipped as `UPDATED` instead of `HELD BACK`. Add a fourth
   gate for eval failures.

The four fixes touch disjoint files and have no ordering dependency on each
other, which is exactly why they must be **four separate commits**.

### Out of scope (do not attempt here)

- **`git-absorb`.** PR #350's CI did _not_ flag it, so it is presumed to build
  under the new nixpkgs — do not touch it. (An earlier consumer-side report
  suspected it, but that traced to a stale evaluation state, not a real break.)
- **Resolving the `effect-mcp` `pnpmDeps` hash yourself by building.** See
  Task 1 — keep the existing hash; CI reports the correct one if it changed,
  and the correction is absorbed into the Task 1 commit.

---

## Conventions (load-bearing; inlined so you need not read anything else)

- **Bash strict mode** — every shell script begins with, and this repo's
  scripts already use:
  ```bash
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  ```
- **Ordering** — keep entries alphabetically sorted within their group.
- **DRY** — no duplicated logic; mirror existing patterns rather than
  inventing new ones.
- **Conventional Commits** — `type(scope): description`, lowercase, imperative,
  no trailing period. Types: `feat fix refactor docs chore build ci style perf
test`.
- **Formatting** — after editing any file, it must be `treefmt`-clean
  (`treefmt` orchestrates alejandra for Nix, prettier for Markdown, shfmt +
  shellcheck + shellharden for shell). `treefmt <file>` on a single file is
  lightweight and safe to run locally; it is not a Nix build.
- **Maintainer conventions & memory** (optional deeper context; the
  load-bearing pieces are already inlined above):
  `/home/caubut/Documents/projects/nixos-config/home/caubut/features/cli/code/ai/claude-config/projects/-home-caubut-Documents-projects-nix-agentic-tools`

---

## Repo invariants you will not see auto-loaded

Most of this repo's architecture rules live in **path-scoped** files
(`.claude/rules/*.md` with `paths:` frontmatter, Copilot `.github/instructions/*`
with `applyTo:`, Kiro `.kiro/steering/*` with `inclusion: fileMatch`). Claude
Code auto-loads the matching rule when you open a file; **Kimchi and other
flat-orientation harnesses do not — they read only `AGENTS.md`.** Every task
edit below is given verbatim, so you do not strictly need these; honor them if
you touch anything adjacent, and do not "clean up" or refactor around them.

- **`ourPkgs`, never `final`/`prev`, for build inputs.** Each compiled overlay
  instantiates `ourPkgs = import inputs.nixpkgs { inherit (final.stdenv.hostPlatform) system; ... }`
  and routes ALL build inputs through `ourPkgs`; `final`/`prev` are read only
  for `final.system`. Using them for build inputs binds to the consumer's
  nixpkgs → cachix cache miss. (The three overlay files here already do this —
  leave it intact.)
- **Do not "fix" the overlay lambda signature `_: final: _prev:`** (three args,
  first discarded). It is deliberate and required by the flake's overlay
  composition; reviewers flag it as atypical — decline.
- **`overrideAttrs` / `overridePythonAttrs`: preserve `passthru`.** Merge, never
  replace: `passthru = (old.passthru or {}) // { ... };`. (Task 2 adds only a
  `meta` key, which is safe — just never replace `passthru`.)
- **Never modify `/nix/store` paths** (no `chmod`/`sed`/`cp` over store files);
  format the working-tree copy instead.
- **pnpm fetcher parity** (Task 1): a package's `fetchPnpmDeps` `pnpm` MUST be
  the same interpreter its build phase uses, or the build fails offline.
  `checks/pnpm-fetcher-parity.nix` gates it and lists `effect-mcp`.
- **Flake source visibility:** Nix only sees git-tracked files — if a step
  creates a file a build must see, `git add` it first. (Not expected here.)

---

## Commit discipline (the part a prior `/ferment` run got wrong)

**Use the repository's stacked-workflow skills — not raw git.** They are
mandated by `AGENTS.md` § "Skill Routing — MANDATORY":

| Operation                                        | Skill          |
| ------------------------------------------------ | -------------- |
| Plan / build a stack of atomic commits           | `stack-plan`   |
| Route a correction into an existing stack commit | `stack-fix`    |
| Push the stack (and open stacked PRs)            | `stack-submit` |

**Where they are / fallback (important for non-Claude harnesses).** These
skills are plain markdown at
`packages/stacked-workflows/skills/<name>/SKILL.md` in this repo — e.g.
`packages/stacked-workflows/skills/stack-plan/SKILL.md`,
`.../stack-fix/SKILL.md`, `.../stack-submit/SKILL.md` (also installed at
`~/.claude/skills/<name>/SKILL.md`). **Kimchi does not read `~/.claude/skills`
by default and does not honor path-scoped steering**, so if your harness does
not surface these as invokable skills, **read the `SKILL.md` files directly at
the repo path above and follow their steps** — they are self-contained. Do not
fall back to hand-rolled `git rebase` / `git absorb`.

**Target shape — exactly four atomic commits, in this order:**

1. `fix(effect-mcp): pin pnpm_10 for fetchPnpmDeps under new nixpkgs`
2. `fix(git-revise): repoint meta.changelog at pinned rev`
3. `fix(kagi-mcp): relax pydantic bound for new nixpkgs`
4. `fix(update): gate run_nfb_build on nix-fast-build eval failures`

Each commit is a **small, self-contained, independently reviewable unit** that
stands on its own and needs no later commit to "complete" it.

**Anti-pattern — do NOT repeat this (it is what the last run did):**

> ❌ One large commit containing all of the code, followed by a second
> one-line commit that merely "enables" or "wires up" the new code.

Split commits by **logical change**, never by **"write the code" vs. "turn it
on."** Every fix in this plan is already whole in a single edit — there is no
code-vs-activation seam to split on, and no reason to combine the four fixes
into one commit. **One fix = one commit. Four fixes = four commits.**

**Interaction with the no-local-build rule:** use the stacking skills for
_structure_ only. **Do not run their local build/test/validation phases**
(e.g. `stack-test`, or any `nix flake check` a skill offers) — those trigger
heavy Nix this machine cannot run. Plan and push with the skills; CI is the
verifier.

**Corrections go _into_ the right commit, not on top.** If CI later reports a
changed hash for Task 1 (see below), absorb the corrected hash into the
**Task 1 commit** with `stack-fix` — do **not** add a trailing "fix hash"
commit. This is the discipline in miniature.

---

## Task 1 — `effect-mcp`: pin `pnpm_10` for `fetchPnpmDeps`

**Files:**

- Modify: `overlays/mcp-servers/effect-mcp.nix`

**Why:** under the new nixpkgs the default `pnpm` is `pnpm_11`, which no longer
supports `fetchPnpmDeps { fetcherVersion = 3; }`. Pin `pnpm_10` for both the
dependency fetch and the build so they stay in lockstep (the repo's
`checks/pnpm-fetcher-parity.nix` enforces that the `fetchPnpmDeps` `pnpm` and
the build `pnpm` match). This mirrors `overlays/mcp-servers/context7-mcp.nix`,
which already pins `pnpm_10`.

- [ ] **Step 1 — drop `pnpm` from the `inherit` and bind `pnpm_10`.**

Current (`overlays/mcp-servers/effect-mcp.nix`, line 15):

```nix
  inherit (ourPkgs) bun fetchPnpmDeps makeWrapper nodejs pnpm pnpmConfigHook;
```

Replace with:

```nix
  inherit (ourPkgs) bun fetchPnpmDeps makeWrapper nodejs pnpmConfigHook;
  # New nixpkgs makes the default `pnpm` be pnpm_11, which dropped
  # fetchPnpmDeps `fetcherVersion = 3`. Pin pnpm_10 for BOTH the deps
  # fetch and the build so they stay in lockstep
  # (see checks/pnpm-fetcher-parity.nix). Mirrors context7-mcp.nix.
  pnpm = ourPkgs.pnpm_10;
```

- [ ] **Step 2 — pass the pinned `pnpm` to `fetchPnpmDeps`.**

Current (lines 34–38):

```nix
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = "sha256-BtXGw92T+7Cbvg9tUTvHQNiEy1yIGH12zhJLKRxhEl8=";
    };
```

Replace with (adds `inherit pnpm;`; **keep the existing `hash` verbatim** —
do not blank it and do not try to compute a new one locally):

```nix
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      inherit pnpm;
      fetcherVersion = 3;
      hash = "sha256-BtXGw92T+7Cbvg9tUTvHQNiEy1yIGH12zhJLKRxhEl8=";
    };
```

`nativeBuildInputs` on line 39 already reads `pnpm`, which now resolves to
`pnpm_10` — no change needed there, and parity is preserved.

- [ ] **Step 3 — format.** Run `treefmt overlays/mcp-servers/effect-mcp.nix`.

- [ ] **Step 4 — commit this change alone**, as the first commit of the stack:
      `fix(effect-mcp): pin pnpm_10 for fetchPnpmDeps under new nixpkgs`.

**Verification (deferred to CI):** on push, the `build (x86_64-linux)` job must
build `effect-mcp`, and `effect-mcp` must no longer appear under
`ERROR:nix_fast_build:EVAL: ... failures`. **Hash caveat:** the `pnpmDeps` hash
_may_ change with the pinned pnpm. If CI fails with a hash mismatch
(`error: hash mismatch ... got: sha256-...`), take the `got:` value from the CI
log and absorb it into **this** commit via `stack-fix` — not a new commit. Do
not guess the hash. (If you cannot read CI, leave the existing hash and note in
the PR body that the maintainer should confirm it.)

---

## Task 2 — `git-revise`: repoint `meta.changelog` at the pinned rev

**Files:**

- Modify: `overlays/git-tools/git-revise.nix`

**Why:** nixpkgs' `git-revise` sets
`meta.changelog = ".../blob/${finalAttrs.src.tag}/CHANGELOG.md"`. Our overlay
pins `src` to a bare `rev` with no tag, so `finalAttrs.src.tag` is `null` and
any read of `meta.changelog` (nix-update does one) throws
`cannot coerce null to a string`. Repoint the changelog at the pinned `rev`
(already in scope as `rev`) so the link stays valid — we fix the breakage
without dropping the changelog metadata.

- [ ] **Step 1 — add a `meta` override inside `overridePythonAttrs`.**

Current tail of `overlays/git-tools/git-revise.nix` (lines 29–44):

```nix
  ourPkgs.git-revise.overridePythonAttrs (old: {
    version = vu.mkVersion {
      # pyproject.toml uses dynamic version (hatch); read from __init__.py
      # upstream: readPythonDunderVersion @ gitrevise/__init__.py
      upstream = "0.8.0";
      inherit rev;
    };
    inherit src;
    pyproject = true;
    format = null;
    build-system = [ourPkgs.python3Packages.hatchling];
    # v0.8.0 added test_sshsign which needs openssh (not in nixpkgs' v0.7.0 check deps)
    nativeCheckInputs =
      (old.nativeCheckInputs or [])
      ++ [ourPkgs.openssh];
  })
```

Replace with (adds only the `meta` block; leave everything else byte-for-byte):

```nix
  ourPkgs.git-revise.overridePythonAttrs (old: {
    version = vu.mkVersion {
      # pyproject.toml uses dynamic version (hatch); read from __init__.py
      # upstream: readPythonDunderVersion @ gitrevise/__init__.py
      upstream = "0.8.0";
      inherit rev;
    };
    inherit src;
    pyproject = true;
    format = null;
    build-system = [ourPkgs.python3Packages.hatchling];
    # v0.8.0 added test_sshsign which needs openssh (not in nixpkgs' v0.7.0 check deps)
    nativeCheckInputs =
      (old.nativeCheckInputs or [])
      ++ [ourPkgs.openssh];
    # nixpkgs builds meta.changelog from `finalAttrs.src.tag`. We pin `src`
    # to a bare rev (no tag), so src.tag is null and the base expression
    # throws `cannot coerce null to a string` the moment anything reads
    # meta.changelog (nix-update does). Repoint it at the pinned rev so the
    # changelog link stays valid instead of dropping the metadata.
    meta =
      (old.meta or {})
      // {
        changelog = "https://github.com/mystor/git-revise/blob/${rev}/CHANGELOG.md";
      };
  })
```

- [ ] **Step 2 — format.** Run `treefmt overlays/git-tools/git-revise.nix`.

- [ ] **Step 3 — commit this change alone**, as the second commit of the stack:
      `fix(git-revise): repoint meta.changelog at pinned rev`.

**Verification (deferred to CI):** on push, the `git-revise` package builds,
and the next update run no longer reports `HELD BACK: git-revise`.

---

## Task 3 — `kagi-mcp`: relax the `pydantic` version bound

**Files:**

- Modify: `overlays/mcp-servers/kagi-mcp.nix`

**Why:** upstream `kagimcp` declares `pydantic~=2.12.5`. The new nixpkgs ships
`pydantic 2.13.4`, so `pythonRuntimeDepsCheckHook` fails the build with
`pydantic~=2.12.5 not satisfied by version 2.13.4`. Relax the `pydantic` bound
so the newer point release satisfies it; the MCP-initialize smoke test
(`installCheckPhase`) still gates real runtime compatibility. This is a
metadata relaxation — **no hashes change.**

- [ ] **Step 1 — add `pythonRelaxDeps` for `pydantic`.**

Current (`overlays/mcp-servers/kagi-mcp.nix`, the `dependencies` line inside
`buildPythonApplication`):

```nix
    dependencies = with python313Packages; [fastmcp pydantic python-dateutil typing-extensions urllib3];
```

Immediately **after** that line, insert:

```nix
    # Upstream pins `pydantic~=2.12.5`; the new nixpkgs ships pydantic 2.13.4,
    # which trips pythonRuntimeDepsCheckHook. Relax the pydantic bound — the
    # MCP-initialize smoke test in installCheckPhase still gates real runtime
    # compatibility with the newer point release.
    pythonRelaxDeps = ["pydantic"];
```

- [ ] **Step 2 — format.** Run `treefmt overlays/mcp-servers/kagi-mcp.nix`.

- [ ] **Step 3 — commit this change alone**, as the third commit of the stack:
      `fix(kagi-mcp): relax pydantic bound for new nixpkgs`.

**Verification (deferred to CI):** on push, the `kagi-mcp` build passes
`pythonRuntimeDepsCheck` and the MCP-initialize smoke test. If the smoke test
_fails at runtime_ under pydantic 2.13.4 (i.e. relaxing the bound is not enough
because 2.13 is genuinely incompatible), stop and leave a note — the fallback
is to pin `pydantic` rather than relax it, and the maintainer decides.

---

## Task 4 — `run_nfb_build`: add an eval-failure gate

**Files:**

- Modify: `dev/scripts/update-common.sh`
- Modify (documentation sync): the fragment that documents the gates — grep
  for it (see Step 3).

**Why:** `run_nfb_build` gates build verification on three tripwires (exit
code, JSON result file, and a stderr grep for
`ERROR:nix_fast_build:BUILD: N successes, M failures`). `nix-fast-build`
reports **evaluation** failures on a _different_ line —
`ERROR:nix_fast_build:EVAL: N successes, M failures` — which no gate inspects.
An attribute that throws during evaluation never becomes a build, so it
produces no `success: false` result entry and does not increment the BUILD
failure count: it is invisible to all three current gates. This is exactly how
the `effect-mcp` eval break slipped through and the `nixpkgs` bump shipped as
`UPDATED`. Add a fourth gate mirroring gate 3 but matching the `EVAL:` line.

- [ ] **Step 1 — add the eval gate after gate 3.**

In `dev/scripts/update-common.sh`, gate 3 currently ends here (around
lines 159–163):

```bash
  if grep -qE "ERROR:nix_fast_build:BUILD: [0-9]+ successes, [1-9][0-9]* failures" "$stderr_log"; then
    log_failure "nix-fast-build stderr reports build failures:"
    grep -E "BUILD: [0-9]+ successes|Failed attributes:" "$stderr_log" >&2 || true
    failed=1
  fi
```

Immediately **after** that `fi`, insert:

```bash

  # Gate 4: evaluation failures. nix-fast-build reports eval-time errors on a
  # separate line from build failures. An attribute that throws during
  # evaluation (e.g. an input bump that breaks a package's eval) never becomes
  # a build, so it produces no `success: false` result entry (gate 2) and does
  # not increment the BUILD failure count (gate 3): it is invisible to gates
  # 1-3. nix-fast-build emits a distinct line for it:
  #   ERROR:nix_fast_build:EVAL: N successes, M failures
  # Observed when a nixpkgs bump broke effect-mcp's fetchPnpmDeps eval, yet the
  # nixpkgs update still shipped as UPDATED instead of HELD BACK.
  if grep -qE "ERROR:nix_fast_build:EVAL: [0-9]+ successes, [1-9][0-9]* failures" "$stderr_log"; then
    log_failure "nix-fast-build stderr reports evaluation failures:"
    grep -E "EVAL: [0-9]+ successes|Failed attributes:" "$stderr_log" >&2 || true
    failed=1
  fi
```

- [ ] **Step 2 — update the function's header comment** so the documented gate
      list stays truthful. In the `run_nfb_build` doc comment, the tripwire list
      currently enumerates three gates (search for
      `Defense in depth — fail if ANY of these tripwires fire:`). Add a fourth
      bullet describing the eval gate, matching the style of the existing three,
      e.g.:

  ```bash
  #   4. nix-fast-build's stderr contains
  #      `ERROR:nix_fast_build:EVAL: N successes, M failures` with M > 0 —
  #      eval-time throws are invisible to gates 1-3.
  ```

- [ ] **Step 3 — sync the architecture fragment.** This repo requires that
      docs describing an abstraction are updated in the same commit as the code
      (`AGENTS.md` § "Architecture Fragments" / "Maintenance is mandatory"). The
      update-pipeline fragment describes `run_nfb_build`'s gates and calls them
      "three independent gates." Find it and update the count and description to
      four:

  ```bash
  grep -rIl -e "three independent gates" -e "run_nfb_build" \
    dev/fragments/ packages/*/docs/ 2>/dev/null
  ```

  Edit the matching source fragment (under `dev/fragments/` or
  `packages/<pkg>/docs/`, **not** the generated `.claude/rules/*.md` /
  `.github/instructions/*.md` / `.kiro/steering/*.md` outputs) to describe the
  eval gate as the fourth tripwire. **Do not** run the generator
  (`nix run .#generate` / `devenv tasks run ... generate:*`) — that is a Nix
  build; the maintainer regenerates the outputs.

- [ ] **Step 4 — format.** Run `treefmt` on each edited file
      (`dev/scripts/update-common.sh` and the fragment).

- [ ] **Step 5 — commit this change alone**, as the fourth commit of the stack:
      `fix(update): gate run_nfb_build on nix-fast-build eval failures`.

**Verification (deferred to CI + review):** on push, the shell linters
(`shellcheck -x`, `shfmt`, `shellharden`) and `treefmt-check` must pass. The
gate cannot be exercised end to end without a real `nix-fast-build` eval
failure, so its correctness rests on the exact-match grep pattern above (taken
verbatim from an observed failure) and reviewer inspection. Flag it for the
maintainer's audit.

---

## Submit

- [ ] Push the 4-commit stack with `stack-submit` (stacked PRs against
      `refactor/ai-factory-architecture` are fine; a single branch carrying the 4
      commits is also acceptable). CI (`ci.yml`, `pull_request` event) then builds
      and verifies on both `x86_64-linux` and `aarch64-darwin`.
- [ ] Do **not** merge anything. The maintainer reviews the stack and CI.

## Success criteria

1. A clean stack of **exactly four commits**, one per task, each atomic and
   independently reviewable — **not** one combined commit and **not** a
   code-then-enable split.
2. Each commit is `treefmt`-clean and uses a Conventional-Commit message.
3. No heavy Nix was run locally; verification was left to CI.
4. Any `effect-mcp` hash correction was absorbed **into** the Task 1 commit via
   `stack-fix`, not appended as a separate commit.

## Notes for the reviewer (maintainer)

- Task 1 hash: confirm whether the pinned `pnpm_10` changed the `pnpmDeps`
  hash; if CI surfaced a new value, verify it was absorbed into the Task 1
  commit (not trailing).
- Task 3 kagi-mcp: confirm `pythonRelaxDeps` cleared `pythonRuntimeDepsCheck`
  and the smoke test still passes under pydantic 2.13.4 (a runtime break there
  means pin instead of relax).
- Task 4 eval gate: sanity-check the grep pattern against the observed line
  `ERROR:nix_fast_build:EVAL: 37 successes, 1 failures`.
- `git-absorb` is intentionally excluded — PR #350's CI did not flag it.
