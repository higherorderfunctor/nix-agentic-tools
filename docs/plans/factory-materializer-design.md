# Factory materializer — design v2 (P2 of converge-agentic-foundations)

Status: DRAFT v2.1, CONVERGED, awaiting HITL decision. v1 was adversarially
reviewed by three judges (module-system / runtime-lifecycle / test-surface);
a convergence verifier then re-checked every blocking finding against v2 and
its four PARTIAL gaps (devenv dangling-task edge, non-regular target row,
devenv N->0 ungating, temp-sweep infix) are folded into this revision, all
marked `[B*]`. HM checkLinkTargets ordering and the devenv task names were
VERIFIED against the machine's HM source and the pinned devenv rev. Key correction the review
produced: **the "collisions error today" premise was false** — `home.file.*.text`
is `nullOr lines`, whose merge CONCATENATES colliding definitions silently
(verified by eval); only the module-eval stub (`attrsOf anything`) errors.
This design deliberately UPGRADES collision handling, it does not "preserve"
it.

## 1. Shape — strategy as data on a derived attrset

```nix
ai.kiro.steeringFiles = lib.mkOption {
  type = types.attrsOf (types.submodule {
    options = {
      text     = mkOption { type = types.nullOr types.str; default = null; };
      source   = mkOption { type = types.nullOr types.path; default = null; };
      strategy = mkOption { type = types.enum ["copy" "symlink"]; };
    };
  });
  default = {};
  internal = true;   # populated by the factory; readable by tests/consumers
};
ai.kiro.steeringStrategy = lib.mkOption {
  type = types.enum ["copy" "symlink"];
  default = "copy";  # the per-surface escape hatch (e.g. upstream fixes Kiro#9787)
};
```

- **[B1] `text` is `nullOr types.str`, NOT `lines`**: `str` merges via
  mergeEqualOption, so two emitters defining the same key with DIFFERENT
  content is a hard eval error ("conflicting definition values"), and equal
  content dedupes. This is a deliberate behavior CHANGE: today production
  silently concatenates (e.g. a rule named `AGENTS` + `contextFilename =
"AGENTS.md"` yields one doubled file); the change makes the collision loud,
  which is what `.claude/rules/ai-module.md` requires. Equal-value dedupe
  (vs today's silent doubling) is also a change, chosen consciously.
- **[B2] `strategy` has NO submodule default** (the shared options block is
  inert data with no `config` access — a `cfg.*` default there cannot eval).
  Every emitter populates `strategy = cfg.steeringStrategy` explicitly.
  Colliding emitters therefore always agree on strategy; collisions surface
  on `text`, where they error.
- Exactly-one-of `text`/`source` per entry enforced by assertion; shape-pin
  tests additionally assert `entry.source == null` (attr-absence checks are
  meaningless on a submodule — every entry has the attr).
- The four steering emitters per backend (named-instr / unnamed-instr /
  rules / context; 4×HM + 4×devenv, verified) keep their mkMerge element
  boundaries and mkIf gates, and consolidate the 4×-duplicated
  fragments/transformer imports into one binding per backend.

## 2. Writers — one shared `lib/ai/materialize.nix`

Emits per backend from `{ files, targetDir, stateSlug }`.

**symlink** → exactly today's shapes (HM `home.file`, devenv `files.*`).

**copy — HM**: TWO dag entries **[B4]**:

- **Phase A (pre-link prune)** — `entryBefore ["checkLinkTargets"]`: for
  every name in the PREVIOUS manifest that is NOT in the current copy-set
  (covers: entry removed, entry flipped to symlink, surface emptied): apply
  the clobber guard (§3), then delete. Running before checkLinkTargets means
  a copy→symlink flip leaves a clean path for HM to link — no "Existing file
  … is in the way" abort, no `force = true` (constraint 1), and no
  linkNewGen "identical – don't do anything" adoption trap.
- **Phase B (write)** — `entryAfter ["linkGeneration"]` (constraint 5):
  heredoc-embedded writes (constraint 7; `source` normalized at eval via
  `builtins.readFile`) + manifest rewrite (once, at end, mktemp+mv).
- **[B4] Phase A prune-set is `previousManifest ∖ currentCopySet`** — NOT
  "∖ all declared names": a flipped-to-symlink name MUST be pruned in phase A
  precisely so link generation can take the path over cleanly.
- **The activation entries exist whenever the module is enabled** — NOT
  gated on `steeringFiles != {}` **[B6-partial]** — so emptying the set
  prunes everything (N→0 works). The mkIf gates stay on the _emitters_ only.

**copy — devenv**: one task `"ai:<app>:materialize-<surface>"`,
`after = ["devenv:files:cleanup"]`, `before = ["devenv:enterShell"]
++ lib.optional (config.files != {}) "devenv:files"` **[B4]**: the
`devenv:files` edge orders the prune before devenv creates `files.*`
symlinks (so a flipped name's real file never triggers createFileScript's
silent "Conflicting file" skip) — but it MUST be conditional, because on the
pinned devenv `tasks."devenv:files"` is `optionalAttrs (config.files != {})`
and the task runner HARD-ERRORS (`TasksNotFound`) on a dangling before/after
ref; an all-copy consumer with no other `files.*` usage (this design's own
end-state) has no `devenv:files` task at all. The unconditional
`devenv:enterShell` edge alone then guarantees write-before-shell. **The
task exists whenever the module is enabled** (mirror of the HM bullet), so
N→0 prunes on devenv too. Anchored `cd "$DEVENV_ROOT"`. (Task names
`devenv:files`/`devenv:files:cleanup` verified against the pinned devenv
rev; they are undocumented internals — pin-bump reviews must re-check.)

**Script hardening (shared core)**: atomic `mktemp`+`mv` per file — temp
name carries a RESERVED INFIX: `.<name>.nat-tmp.XXXXXX` in the target dir
(same-fs atomicity); the **stale-temp sweep** at start removes ONLY
dot-prefixed files containing the literal `.nat-tmp.` **[B8]** — the infix,
not the name regex, is the safety proof: a bare `.<name>.*` pattern would
eat user dotfiles like a vim `.foo.md.swp` or a `.a.md.notes`, whereas no
managed name (regex bars dots at start) and essentially no user file
carries `.nat-tmp.`; the infix is documented reserved. Temps are the ONE
declared non-manifest deletion class (see the §3 table row) — Kiro slurping
a stranded partial temp forever was the hazard; `cmp -s` skip-guard from
**diffutils**;
`[ -L "$target" ]` force-write before cmp (constraint 9); `sha256sum` et al
by absolute `${pkgs.coreutils}` path; manifest greps `|| :`-guarded (first
run has no manifest); per-script unique heredoc EOF marker;
`lib.escapeShellArg` on names; no `exit` (HM activation rule); `$HOME`
anchoring on HM; written files land **mode 0444** (D3 guardrail — see §8;
temp is chmod 444 before the mv).

**Consumer backstop [B7]**: the devenv backend also emits an `enterTest`
fragment asserting every copy-entry exists as a real file
(`[ -f … ] && [ ! -L … ]`) — the real-file gate ships WITH the module to
every consumer instead of living only in this repo's devenv.nix. (A failed
materialize task still only warns at shell entry; the gate makes it fail
`devenv test`/CI.)

## 3. Lifecycle — manifest + clobber guard on EVERY destructive path

Manifest: `name<TAB>sha256-of-what-we-wrote` per line, OUTSIDE the scanned
dir (HM → `${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/materialize/<stateSlug>.manifest`;
devenv → `$DEVENV_STATE/nix-agentic-tools/materialize/<stateSlug>.manifest`),
rewritten atomically once per run. `stateSlug` uniqueness per
(backend, targetDir) is asserted at eval. Backups namespace per-slug:
`materialize/<stateSlug>.bak/<name>.<epoch>`.

**Clobber guard — complete state table [B3][B5]** (applies to BOTH the write
path and the prune path; "ours" = disk hash equals manifest hash):

| Target state                           | Write path                                                                                                                                                              | Prune path                                |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| symlink (any)                          | replace with real file (a symlink is never user content; skipping would reinstate the v3 defect)                                                                        | delete (flip/removal of the old delivery) |
| absent                                 | write                                                                                                                                                                   | nothing                                   |
| ours (hash match)                      | overwrite if content changed (cmp)                                                                                                                                      | delete                                    |
| edited (manifest entry, hash differs)  | **backup + WARN + write** (D3 recommended)                                                                                                                              | **backup + WARN + delete**                |
| non-regular non-symlink (dir/fifo/…)   | **loud error, no clobber** (mv onto a dir fails anyway; fail with a clear message)                                                                                      | **loud error, leave in place**            |
| stale `.nat-tmp.` temp (ours by infix) | swept at start — the ONE declared non-manifest deletion (never user content; infix reserved)                                                                            | same sweep                                |
| foreign (no manifest entry, real file) | **backup + WARN + write** — adoption-with-preservation; today's HM errors on this collision, an activation script must not abort, so preservation+warning is the analog | never touched (not in manifest)           |

**[B6] Disable/removal is a declared limitation**: `ai.kiro.enable = false`
(or removing the module) removes the runner itself — nothing can prune the
materialized files, and Kiro keeps loading them. Documented uninstall path:
set the surface empty (or `steeringStrategy = "symlink"`) for one
activation, THEN disable. Called out in module docs + README. (Symlink mode
never had this hole; it is the structural cost of real files, accepted by
the decision doc.)

Documented (nonblocking) limitations: HM rollback across the conversion
boundary does not restore symlink management (identical content is left as a
real file; differing content aborts the old generation's checkLinkTargets);
an activation that aborts at checkLinkTargets for an UNRELATED collision
after phase A already pruned a flipped file leaves that steering file absent
until the next successful activation (backed up only if it was user-edited);
`devenv gc`/`.devenv` wipe loses prune history (same class as devenv's own
files.json); `builtins.readFile` on a derivation-produced `source` is IFD —
`source` is documented pure-path (fixture/flake files), not drv outputs.

## 4. Name safety — copy-mode entries only

Copy-mode entry names must match the hookNameAssertion regex
(`[A-Za-z0-9][A-Za-z0-9._-]*`) — they are interpolated into shell words,
paths, and the temp-sweep pattern. **This is behavior-changing and loud**: a
nested `contextFilename = "agents/AGENTS.md"` or a spaced rule name works
today via home.file and would now fail eval with a clear message (the judge
was right that "only path-hazardous names" was inaccurate). Symlink-mode
entries keep today's freedom — the regex gates only what the shell scripts
touch.

## 5. Scope (v1 → follow-ups) — unchanged from v1 except as noted

| Surface                            | v1             | Strategy | Why                                                                              |
| ---------------------------------- | -------------- | -------- | -------------------------------------------------------------------------------- |
| Kiro steering (4+4 emitters)       | **CONVERT**    | copy     | v3 drops leaf symlinks; ships to every consumer                                  |
| Kiro skills / agents               | not routed     | symlink  | probe-first (P3); skills are trees — sync_dir generalization comes with the flip |
| Claude (all surfaces)              | untouched      | symlink  | verified symlink-safe; CLAUDE.md/skills upstream-delegated                       |
| Copilot devenv git-tracked outputs | follow-up unit | copy     | new consumer capability; fix `.github/instructions/` hardcode first              |

**Whole-dir symlink, project scope (plan-doc requirement, evaluated here):**
REJECTED for the same reasons as HOME scope — exclusive ownership of
`.kiro/steering/` (consumers could no longer drop a hand-written steering
file into their project) plus a committed symlinked dir is the exact
mode-120000 problem. The register item closes with this design.

Same-commit riders: repo-wide `writeBoundary`→`linkGeneration`;
mkKiro.nix:893-911 citation re-correct + engine qualifier;
`instruction-file-single-mechanism.md:169-171` fix; **devenvStubs `tasks`
stub in checks/module-eval.nix** (without it every evalDevenv test fails);
plan-doc touch-ups (emitter count 4+4; constraint-2 wording — collisions
BECOME errors, they do not "stay" errors).

## 6. Test migration

- Accessor swaps: `home.file/files → ai.kiro.steeringFiles."<n>".text`;
  hasInfix conjuncts carry verbatim.
- Parity test keeps BOTH layers: attrset equality (decidable — verified ==
  works over contexted strings) AND one writer-output byte check per backend
  via the #433 heredoc-extraction + `unsafeDiscardStringContext` idiom, so
  writer divergence stays caught (attrset-only was judged weaker than
  today's test).
- Shape pins: `entry.text != null && entry.source == null && entry.strategy
== "copy"`.
- Vacuous-scan tests (`noDoubledMd`, stray-path negatives) re-pointed at
  `attrNames steeringFiles`.
- New: collision test (two emitters, same key, different text → eval error);
  N→0 prune presence (activation text contains prune loop when set empty);
  enterTest fragment presence on devenv copy-entries.
- Known gap: dag ordering (`entryBefore checkLinkTargets` / `entryAfter
linkGeneration`) unassertable under the stub → nmt (P4) covers; recorded.

## 7. Constraint compliance

1 no-force ✓(§2 phase A replaces force) · 2 collisions-error
✓(§1 [B1] — deliberate upgrade, premise corrected) · 3 manifest-prune-only
✓(§3) · 4 no-silent-clobber ✓(§3 table covers write AND prune AND foreign)
· 5 linkGeneration ✓(§2 phase B + riders) · 6 strategy-as-data ✓(§1) ·
7 heredoc-embed ✓(§2) · 8 Claude-symlink/probe-first ✓(§5) · 9 -L guard
✓(§2, §3 table row 1).

## 8. Decisions (HITL 2026-07-21) — resolved

- **D1+D2 ADOPTED** as specced (v1 scope incl. whole-dir-symlink rejection).
- **D3 RESOLVED — backup+warn+proceed**, with two operator refinements:
  (a) backups must never enter git — structurally satisfied: both backup
  roots (XDG state on HM, `$DEVENV_STATE` on devenv) live outside the
  working tree, and `$DEVENV_STATE` sits under devenv's own gitignored
  `.devenv/`; no `*.orig`-style droppings in the repo. (b) The "user edit"
  threat model here is an LLM edit (the repo is fully agent-driven), so
  copy-mode files are written **mode 0444 (read-only)** as a first-line
  guardrail — `mv`-replacement is unaffected by target-file perms, so our
  own updates and prunes still work, while a casual agent write bounces.
  A REAL write-block guard (hook/trigger that blocks re-enabling write on
  managed paths; a file-watcher is probably the wrong primitive) is a
  BACKLOG item — it leans on this plan's output and is deliberately
  deferred (register: oi-materialized-write-guard).
- **D4 RESOLVED — accept the documented two-step uninstall for this plan's
  main body**; a stronger uninstall/cleanup mechanism is parked as a backlog
  item (register: oi-uninstall-cleanup-mechanism) to be re-decided when the
  plan's main body drains.
