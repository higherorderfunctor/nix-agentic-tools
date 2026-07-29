# AI instructions ⨯ context: compose fix (factory)

**Status:** DESIGN APPROVED (incl. all §9 decisions + Kiro unnamed→dedicated
steering file, 2026-07-20). Root cause confirmed by code-read (not guessed).
Full code-grounding pass done — see **§10 Grounding delta** for three
corrections/expansions to the original design (Copilot is a split-brain, not a
hard collision; devenv-Claude context-drop repaired by the same change; ~3
existing module-eval tests must be rewritten). **Next: TDD (§6) — write the
failing Claude fixture first.** **Branch:** `refactor/ai-factory-architecture`
**Scope:** FACTORY fix (`lib/ai/*` + per-app `mk*.nix`). This is **beyond S1's
SWS revert** — S1 only _exposed_ a pre-existing latent design flaw.
**Execution:** systematic-debugging Phase 4 (failing test FIRST) →
supervisor-worker-verifier. No `nix flake check` locally (OOM rule); per-check
`nix build .#checks.x86_64-linux.<name> --max-jobs 1`.

---

## 1. Symptom

`scripts/activate --no-nix-conf` in nixos-config fails:

```
error: Failed assertions:
- Conflicting managed target files: .claude/CLAUDE.md
```

Trigger conditions (all now true): nix-agentic-tools pin = `afd98e2e` (S1),
`stacked-workflows.enable = true`, and
`claude.context = ./claude-config/global-instructions.md` set.

## 2. Root cause (confirmed)

`~/.claude/CLAUDE.md` has **two independent home-manager writers**:

- **Writer A** — `packages/claude-code/lib/mkClaude.nix:354` sets
  `programs.claude-code.context = effectiveContext`; upstream renders the
  operator's `global-instructions.md` to `home.file.".claude/CLAUDE.md"`.
- **Writer B** — the generic `lib/ai/app/hmTransform.nix:166` writes
  `home.file.".claude/CLAUDE.md".text = renderedInstructions`, guarded by
  `cfg.enable && hasInstructions`.

Before S1 the operator had **zero** Claude `ai.instructions` at HM scope, so
Writer B was dormant → only Writer A wrote the file → no conflict. S1 re-added
the **stacked-workflows router** (`packages/stacked-workflows/router.nix`, a
`name = "stacked-workflows"` `ai.instructions` entry) → `hasInstructions = true`
→ Writer B fires → two `home.file` entries on one path → assertion.

**This is by design, not an oversight.** `mkCopilot.nix:277-280` states it:

> "Global context → `<configDir>/<contextFilename>`. … **Conflicts with the
> baseline instructions-concat when both are set — eval-time error signals the
> user to pick one pathway.**"

The factory deliberately forces **context XOR always-on instructions** for the
single aggregate file. That assumption breaks the moment a _package_ contributes
an always-on instruction (the router) while the consumer _also_ sets a personal
`context` — both are legitimate, independent needs.

**Secondary latent bug:** `renderedInstructions` (Writer B) never includes the
context, so even absent the file collision, one file could never hold _both_
context and instructions. This manifests differently per backend (confirmed
§10): **HM** Claude has Writer A (upstream `programs.claude-code.context`) so
context isn't lost — the two writers _collide_. **devenv** Claude has **no**
context writer at all (`mkClaude.nix` devenv block never writes context), so the
aggregate is its _only_ `CLAUDE.md` source and context is silently **dropped**.
Retiring the aggregate therefore _requires_ adding a devenv-Claude compose
writer, which also fixes the drop.

## 3. Blast radius

| CLI         | Aggregate model                                                                                                            | Status                                                                                                                                                         |
| ----------- | -------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Claude**  | one file `CLAUDE.md`; upstream `programs.claude-code.context` (HM) + generic aggregate → **same path** `.claude/CLAUDE.md` | 💥 **hard collision, erroring now** (HM). devenv: context silently dropped (§2).                                                                               |
| **Copilot** | one file; context writer path ≠ aggregate `outputPath` (see below) — **different paths**                                   | ⚠️ **split-brain, NOT a hard collision** (corrected §10): duplicate content in two files, no eval error                                                        |
| **Kiro**    | **directory** of steering files; context and each named instruction get their _own_ file (`mkKiro.nix:496,521`)            | ✅ no context/instruction collision — only a **stale `outputPath = ".config/kiro/steering/"`** (trailing-slash dir) that makes the generic render emit a stray |

**Copilot path detail (§10 correction).** The context writer targets
`<configDir|projectDir>/<contextFilename>` — HM
`.copilot/copilot-instructions.md` (`configDir = .copilot`), devenv
`.github/copilot-instructions.md` (`projectDir = .github`) — while the generic
aggregate targets
`defaults.outputPath = .config/github-copilot/copilot-instructions.md`. Those
are **different paths**, so Copilot never raised the "pick one pathway" eval
error the `mkCopilot.nix:277-280` comment claims. Only **Claude** hard-collides
(aggregate `.claude/CLAUDE.md` == upstream context path). The compose fix still
applies to Copilot (collapses the split into one native file).

**Project-scope parallel:** `lib/ai/app/devenvTransform.nix:145`
(`files.${outputPath}.text = renderedInstructions`) is the same mechanism at the
devenv scope — the fix must cover it too (DRY).

Kiro is the tell: it already does what we want (many always-on files, composed
at _load_ time). The aggregate CLIs force one file and then forbid mixing.

## 4. Why CI is green but activation fails

`checks/module-eval.nix` fixtures **never set `context` together with an
`ai.instructions` entry** for an aggregate CLI. That missing fixture is the
blind spot. Adding it is step 1 (TDD).

## 5. Design — "compose, don't force a choice"

**Principle:** the aggregate file = **context baseline + any _unnamed_ always-on
instructions**, produced by **one** writer. **Named** instructions live _only_
in their own auto-loaded per-name files.

### Layer 1 — named instructions leave the aggregate

The generic aggregate render includes only **unnamed** instructions. Named ones
already emit to auto-loaded per-name files in every app:

- Claude → `.claude/rules/<name>.md` (`mkClaude.nix:404`)
- Copilot → `.github/instructions/<name>.instructions.md` (`mkCopilot.nix:255`)
- Kiro → `.kiro/steering/<name>.md` (`mkKiro.nix:496`)

Dropping named entries from the aggregate loses nothing (they're still emitted +
auto-loaded) and **removes the operator's collision outright** — the router is
named, so the aggregate write disappears and `context` owns `CLAUDE.md` alone.
This retires the previously-accepted _double-emit_ (see §8).

### Layer 2 — compose context + unnamed instructions, one writer

Single-file apps (Claude, Copilot) write **one** file =
`[context baseline]\n\n[rendered unnamed instructions]` via the shared compose
helper. The separate per-app context writer no longer races the aggregate.

- **Claude:** HM → `programs.claude-code.context = compose(...)` (upstream owns
  the single writer). devenv → `files.".claude/CLAUDE.md".text = compose(...)`
  (**new** — devenv Claude had no context writer; this also fixes the §2 drop).
- **Copilot:** HM →
  `home.file."<configDir>/<contextFilename>".text = compose(...)`; devenv →
  `files."<projectDir>/<contextFilename>".text = compose(...)`. The emit gate
  widens from `hasContext` to `hasContext || hasUnnamed`.
- **Kiro** (directory model — **decision 2026-07-20**): does **not** compose.
  `context` stays its own standalone `<configDir>/steering/<contextFilename>`
  (AGENTS.md, unchanged); named → own steering files (unchanged); unnamed
  instructions (rare) → a **dedicated** `<configDir>/steering/instructions.md`
  (rendered unnamed only, no context). The shared compose helper is used by
  Claude + Copilot only.
- **Retire the generic aggregate entirely.** Once Writer B is gone from both
  transforms, `defaults.outputPath` is vestigial for every app (precedent:
  `mkKimchi.nix` already sets `outputPath = null`). Remove/neutralize it and the
  now-dead `renderedInstructions`/`hasInstructions`/`hasOutputPath` bindings;
  update the stale "nameless entries fall through to the baseline aggregate
  render at `defaults.outputPath`" comments in `mkCopilot.nix` / `mkKiro.nix`
  (they become lies).
- **Helper signature (final):**
  `composeInstructionsFile { effectiveContext ? null, unnamedInstructions ? [], render }`
  → markdown string. `render` is the app's `lib.ai.transformers.<x>.render`.
  **Short-circuits** to `effectiveContext` unchanged when
  `unnamedInstructions == []` — so a path context stays a path (`{source = …}`)
  and the operator's actual case (context path + only a _named_ router, zero
  unnamed) is byte-for-byte unchanged except the colliding aggregate write
  disappears. With unnamed present it `readFile`s a path context and
  concatenates `[context]\n\n[rendered]`, dropping empty parts.

### Implementation approach — **(B) per-app composes via a shared helper** (recommended)

Retire the generic aggregate render (`hmTransform.nix:165-167` +
`devenvTransform.nix:145`). Each aggregate app composes in its own
`customConfig` using a new shared helper, honoring its _native_ file mechanism:

- Claude → `programs.claude-code.context = compose(...)` (keep upstream
  integration; single writer).
- Copilot →
  `home.file."<configDir>/copilot-instructions.md".text = compose(...)`.
- Kiro → no aggregate; unnamed-only steering file if needed.

New helper `lib/ai/composeInstructionsFile.nix`:
`{ effectiveContext, unnamedInstructions, transformer } -> composed markdown`
(readFile a path context, render+concat unnamed instructions, context first).
Consumed by both backends and all aggregate apps → single source of truth (DRY).

> **Alternative (A) considered + rejected:** make the _generic_ transform own
> the composed aggregate for all file-output apps. Rejected because it would
> pull per-CLI context resolution + each app's native writer (upstream vs
> home.file) into the generic layer, whereas (B) localizes each app's mechanism
> and simply removes the double-writer. Open to override.

## 6. TDD — failing tests FIRST (systematic-debugging Phase 4)

### 6a. New fixtures (must FAIL today, PASS after fix)

Add to `checks/module-eval.nix`:

1. **Claude HM**: `context` + one **named** + one **unnamed** instruction.
   Assert: (a) **no** `home.file.".claude/CLAUDE.md"` (generic aggregate gone);
   (b) `programs.claude-code.context` contains **both** the context baseline AND
   the unnamed text; (c) the named instruction is in `.claude/rules/<name>.md`
   and its body is **not** in `programs.claude-code.context`. _(Fails today: the
   aggregate writes `home.file` AND duplicates the named entry; context is
   separate.)_
2. **Claude devenv**: same shape → assert `files.".claude/CLAUDE.md".text` holds
   context + unnamed (this is the drop-repair), named only in
   `.claude/rules/<name>.md`.
3. **Copilot HM + devenv**: `context` + unnamed → assert the **single** native
   context file (`.copilot/…` HM, `.github/…` devenv) holds context + unnamed,
   and **no** `.config/github-copilot/copilot-instructions.md` aggregate write;
   named → `.github/instructions/<name>.instructions.md`.
4. **Kiro HM + devenv**: `context` + one named + one unnamed → assert
   `<configDir>/steering/AGENTS.md` = context only, `<name>.md` = named,
   `instructions.md` = unnamed, and **no** `.config/kiro/steering/` stray.

### 6b. Existing tests that encode the OLD behavior (rewrite — they "flip")

These currently pass by asserting the retired aggregate; after the fix they
assert the new routing (this is the TDD "watch it flip" signal):

- `module-claude-instructions-rendered-to-home-file` (unnamed → **was**
  `home.file.".claude/CLAUDE.md"`; **now** `programs.claude-code.context`).
- `module-claude-per-app-instructions-rendered` (same reroute).
- `module-kiro-instructions-rendered` (**was** the stray
  `home.file.".config/kiro/steering/"`; **now**
  `.kiro/steering/instructions.md`).
- `module-claude-no-instructions-no-file` — still passes (aggregate stays gone);
  keep as a regression guard, refresh its comment.

Context-only tests (`module-{copilot,kiro}-{hm,devenv}-…-context…`,
precedence/fallback/filename-override) are unaffected — the helper's
short-circuit preserves the `{source=…}`/`{text=…}` context behavior when no
unnamed instructions are present.

## 7. Adversarial verifications (operator-requested)

- **Load-bearing — CONFIRMED 2026-07-20 (Claude Code memory docs):** Claude Code
  natively auto-discovers `.claude/rules/*.md` (recursively; project
  `.claude/rules/` + user `~/.claude/rules/`) with **no `CLAUDE.md` reference**.
  `paths:` present ⇒ conditional (loads only when Claude touches matching
  files); **`paths:` absent ⇒ always-on, "same priority as
  `.claude/CLAUDE.md`".** The stacked-workflows router carries no `paths:`, so
  its `.claude/rules/` file is always-on — Layer 1 is SAFE, the aggregate copy
  was pure redundancy. (Local proof: dev rule files `stacked-workflows.md`
  `paths:["packages/stacked-workflows/**"]`
  - `nix-standards.md` `paths:["**/*.nix"]` loaded this session by matching my
    reads; `CLAUDE.md` only `@AGENTS.md`, never @-imports rules.) Source:
    code.claude.com/docs/en/memory — "Organize rules with `.claude/rules/`"
  - "Path-specific rules".
- **Minor (non-blocking):** docs document only `paths:` as frontmatter; our
  claude transformer also emits `description:`. Worst case it's ignored — cannot
  break always-on loading (no-paths ⇒ always-on regardless). Optional: drop
  `description` for paths-less named instructions. Verify once on-disk.
- **Ordering:** context first, then unnamed instructions — asserted by test.
- **Copilot** `applyTo:` frontmatter on `.github/instructions/<name>` unchanged.
- **Kiro** `inclusion: always` on named steering files still auto-loads.

## 8. Rollout / decisions

- Reverses the previously-**accepted** double-emit (SWS revert plan §1a). That
  acceptance was in "don't rework rules tooling" context; this is a deliberate,
  operator-approved reversal (2026-07-20).
- Same branch as S1 (velocity mode; larger commits OK) but a **distinct logical
  change** — commit separately from the SWS revert.
- After landing: operator re-pins nixos-config to the fix commit, re-activates
  (HITL walk-through). CI must include the new fixtures.

## 9. Decisions (operator, 2026-07-20)

- ✅ Approach **(B)** over (A).
- ✅ Reverse the double-emit — CONFIRMED safe (§7: paths-less rule = always-on).
- ✅ Separate factory commit on the S1 branch.
- ✅ **Kiro unnamed instructions → dedicated
  `<configDir>/steering/instructions.md`** (not merged into AGENTS.md). Kiro is
  directory-native, so context stays standalone; the compose helper is used by
  **Claude + Copilot only**.
- ✅ **Update this plan doc first** (this pass), then TDD.

All approved. Next: TDD (§6a) — write the failing Claude HM fixture first.

## 10. Grounding delta (full code-read, 2026-07-20)

Confirmed the design against the actual tree before writing any code. Three
corrections/expansions (folded into §2/§3/§5/§6 above):

1. **Copilot is a split-brain, not a hard collision** — context writer path ≠
   aggregate `outputPath` (§3). Only Claude hard-collides.
2. **devenv Claude has no context writer** — the aggregate was its only
   `CLAUDE.md` source and dropped context (§2). Retiring the aggregate
   _requires_ a new devenv-Claude compose writer, which repairs the drop.
3. **~3 existing module-eval tests encode the retired aggregate** and must be
   rewritten (§6b), beyond the new fixtures the original §6 listed.

Also confirmed: retiring Writer B **aligns with** the documented architecture
rule "emission logic lives ONLY at L4 (per-CLI factory)" — the generic
transform's aggregate render was the one L4 violation.

### Concrete change set

- **New** `lib/ai/composeInstructionsFile.nix` (helper, §5 signature) + export
  from `lib/ai/default.nix` as `lib.ai.composeInstructionsFile`.
- **`lib/ai/app/hmTransform.nix` + `devenvTransform.nix`:** delete the
  `home.file.${outputPath}` / `files.${outputPath}` aggregate block and the dead
  `renderedInstructions`/`hasInstructions`/`hasOutputPath`/`outputPath`
  bindings. `mergedInstructions` is still passed to `customConfig` (per-app
  splits named/unnamed itself via `builtins.filter (i: i ? name)`).
- **`packages/claude-code/lib/mkClaude.nix`:** HM
  `context = mkDefault compose(...)`; devenv adds
  `files.".claude/CLAUDE.md".text = compose(...)` (gated
  `hasContext || unnamed != []`). `render = lib.ai.transformers.claude.render`.
- **`packages/copilot-cli/lib/mkCopilot.nix`:** widen both context-writer gates
  to `hasContext || hasUnnamed`; when unnamed present write
  `.text = compose(...)`, else keep `{source|text}`. Drop `defaults.outputPath`
  / update stale comment.
- **`packages/kiro-cli/lib/mkKiro.nix`:** add a
  `<configDir>/steering/instructions.md` writer for unnamed instructions (both
  backends); context writer unchanged; drop
  `defaults.outputPath = ".config/kiro/steering/"` / update stale comment.
- **Tests:** §6a new fixtures + §6b rewrites.
- **Out of scope (follow-up):** stripping `description:` frontmatter from
  paths-less named instructions (§7 minor); kimchi already `outputPath = null`
  and is untouched.

### Banked — commit/push discipline (reaffirmed by operator 2026-07-20)

At the **next natural commit** (not before): `git fetch` + rebase
`refactor/ai-factory-architecture` over the updated remote (operator merged the
package-update PRs / "updated deps"), then commit + push. Do NOT rebase early.
Land the compose fix as a **separate factory commit** on the S1 tip.
