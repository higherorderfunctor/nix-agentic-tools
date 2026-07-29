# Prune the Claude plugin + memory surface

> **Doc type:** ASSESSMENT HANDOFF (not yet a living plan). Next session
> converts this into a living plan via
> `docs/plans/living-workflow/living-plan-bootstrap.md`, then we execute.
> **Baseline pin:** written against `58536a4c` on branch
> `refactor/ai-factory-architecture` (2026-07-13). Re-verify counts/paths if
> HEAD has moved a lot before executing.
>
> **Standing constraints (carry verbatim into the living plan):**
>
> - This is a working doc — **do not commit** unless the user asks (repo rule:
>   review/analysis/plan docs stay untracked).
> - Plugin _enablement_ lives in the user's separate **nixos-config** repo; this
>   repo only ships the HM/devenv _module_. **Never edit nixos-config without
>   explicit HITL approval.** The deliverable here is either a module-level
>   default change (in THIS repo) or a handed-over nixos-config diff — user's
>   call.
> - **Verify-before-delete** (never-drop-features discipline): before any
>   `rm -rf .remember`, grep the archive for sole-record content. Belief is
>   "fully duplicated"; that is not yet proven.
> - Config parity: any cut must stay aligned across lib / HM module / devenv
>   module (a gap between the three is a bug).

---

## 0. Why this exists

The user asked which enabled Claude plugins are dead weight, whether `remember`
earns its keep, and whether superpowers conflicts with their own workflow. This
doc records the assessment (evidence-backed) so the next session can turn it
into an executable living plan instead of re-investigating.

## 1. Ground truth (what is actually enabled)

18 skill-providing plugins are materialized in `~/.claude/skills/` via the
`claude-code-home-manager` HM module. Enablement is driven from nixos-config,
NOT from `~/.claude.json` (`enabledPlugins` is empty there).

**Four overlapping memory systems run at once** — this is the real headline:

| System                     | Where                                                         | Role                                              | Keep?                  |
| -------------------------- | ------------------------------------------------------------- | ------------------------------------------------- | ---------------------- |
| `remember` plugin          | `.remember/` (project-local)                                  | hook-driven auto-journal + SessionStart injection | **Retire**             |
| Native auto-memory         | `~/.claude/projects/.../memory/` (MEMORY.md + ~80 fact files) | curated facts, injected into system prompt        | **Keep — SSOT**        |
| openmemory MCP             | daemon                                                        | semantic recall                                   | **Keep**               |
| kiro auto-memory distiller | this repo's active workstream                                 | auto-distill into systems you read                | **Keep — active work** |

## 2. The `remember` verdict (the user's real question)

**Q: does it inject anything _useful_, i.e. do the memories help sessions?**

Evidence gathered:

- `remember` IS actively firing: `now.md` written 17:58 today; PostToolUse hook
  writes a save-log **on every tool call** (16 logs today, 71 on Apr 15);
  `.remember/` is **5.6 MB / 909 files**, gitignored (disk + context cost, not
  repo bloat). `.done.md` dailies accumulate back to Apr 16 with no cleanup.
- SessionStart hook dumps ~2–3 KB of timestamped activity into context every
  session.
- **The useful content is real but non-additive.** Example: `now.md`'s "daemon
  bootstrap race → needs ExecStartPre fix" is a genuine open thread — but the
  identical thread is already in native memory
  (`project_openmemory_http_daemon.md`) and the plan SSOT
  (`kiro-cli-auto-memory.md`). Everything decision-relevant in the remember
  injection is duplicated at equal-or-better curation in systems the session
  already reads.
- Its ONE genuine edge: **auto-capture without user curation** — a safety net if
  a session dies before a native memory is written. That role is exactly what
  the kiro distiller + `kiro-memory-recall` read-path (S5b, just built) is
  designed to own, into systems you actually read on cold start.

**Verdict:** retiring `remember` is defensible. It is a stopgap for a job your
own tooling is about to do better. Sequence with the distiller so the
auto-capture safety-net role is covered (or accept a small gap window).

## 3. Proposed cuts (assessment — to be ratified in the living plan)

| Plugin                                                                          | Verdict               | Rationale                                                                                                                                                                                      |
| ------------------------------------------------------------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **searchfit-seo**                                                               | **Cut**               | SEO-for-websites (keyword-clustering, schema-markup, on-page-seo, …). Zero fit for nix/CLI/agentic tooling. ~11 skill-description lines of pure context noise + misfire surface every session. |
| **remember**                                                                    | **Cut**               | See §2. Redundant with 3 other memory systems; actively noisy.                                                                                                                                 |
| **ralph-loop**                                                                  | **Cut**               | Autonomous loop — superseded by `/loop` + Workflow + the living-workflow bootstrap.                                                                                                            |
| **pr-review-toolkit**                                                           | **Cut**               | Overlaps `/code-review` + repo auto-review-on-PR-open.                                                                                                                                         |
| **frontend-design**                                                             | **Cut (likely)**      | Backend/nix/CLI focus; only visual work is pptx decks, which this doesn't touch.                                                                                                               |
| **superpowers**                                                                 | **Trim, not cut**     | Keep `systematic-debugging` (user-confirmed good), maybe `test-driven-development`. Drop the SessionStart force-inject + the planning half the living-workflow replaces. See §4.               |
| **hookify**                                                                     | **Marginal**          | User hand-writes hooks in nix; rule-DSL adds little. Keep only if actually used.                                                                                                               |
| **feature-dev**                                                                 | **Marginal**          | Overlaps brainstorming + own planning.                                                                                                                                                         |
| skill-creator / plugin-dev / mcp-server-dev                                     | **Keep**              | User actively builds these.                                                                                                                                                                    |
| code-review / code-simplifier                                                   | **Keep**              | Used.                                                                                                                                                                                          |
| claude-md-management / gh-repo-settings / security-guidance / claude-code-setup | **Keep (occasional)** | Low cost, real use.                                                                                                                                                                            |

Cutting searchfit-seo + remember + ralph-loop + pr-review-toolkit +
frontend-design removes ~25–30 skill descriptions from the system prompt and
their misfire surface — which directly addresses the "superpowers triggers are
hit or miss" feeling (half of that is too many skills competing for one intent).

## 4. Superpowers — the conflict has a precise mechanism

Superpowers ships a **SessionStart hook** (`hooks/session-start`) that
force-injects the entire `using-superpowers` SKILL.md wrapped in
`<EXTREMELY_IMPORTANT>` — the "if there's even a 1% chance a skill applies you
MUST invoke it" mandate + "before entering plan mode, invoke brainstorming
first."

That injection, every session, overrides:

- Claude Code native plan mode
- The user's `living-plan-bootstrap.md` (own scale-the-machinery + greedy
  scheduler + HITL open-items register + WAL journal + adversarial-peer stance)
- The user's own recorded rule: _"Avoid superpowers:executing-plans; default to
  supervisor-worker-verifier with per-task HITL."_

The living-workflow bootstrap is functionally a hand-authored replacement for
superpowers' **entire planning/execution half** (writing-plans + executing-plans

- brainstorming + subagent-driven-development) — more disciplined and
  HITL-aware. So that half is superseded, not merely overlapping.

**Options for the living plan to choose between (HITL):**

- (A) Cherry-pick `systematic-debugging` (+ TDD) as standalone skills, drop the
  superpowers plugin entirely → kills the force-inject AND the trigger-noise.
- (B) Keep the plugin but strip its SessionStart hook (injection is separable
  from the skills).
- (C) Keep as-is (status quo — rejected by the user's stated experience).
  Recommendation leans (A).

## 5. Open decisions register (resolve during living-plan conversion)

- **[HITL@P1] Test-fixture question.** This repo IS a plugin-marketplace
  generator. Are `searchfit-seo` / `ralph-loop` enabled deliberately to dogfood
  the fanout machinery? If yes → move to a _test_ profile, don't delete the
  capability. If accidental → cut outright.
- **[HITL@P1] Delivery surface.** Module-level default change in THIS repo, or a
  handed-over nixos-config diff? (Never edit nixos-config unprompted.)
- **[HITL@P1] Superpowers disposition.** Option A / B / C from §4.
- **[HITL@P2] `remember` data deletion.** After retiring the plugin:
  `rm -rf .remember` (5.6 MB) — gated on the verify-before-delete grep pass.
  Also decide whether other projects' `.remember/` dirs get the same treatment.
- **[HITL@P2] Distiller sequencing.** Confirm kiro distiller read-path covers
  the auto-capture safety-net role before/at remember retirement, or accept the
  gap.
- **[AI-OWNED] Config-parity sweep.** Whatever is cut, keep lib / HM / devenv
  aligned and update any README feature matrix / structural checks in the same
  change (change-propagation rule).

## 6. Phase sketch (greedy — living plan finalizes ordering)

Highest fan-out / cheapest-to-revise first:

1. **P1 — Decide + scope (HITL opening).** Resolve the §5 P1 items in one
   batched agenda. Output: ratified cut list + delivery surface + superpowers
   option.
2. **P2 — Retire `remember`.** Disable hook/skill in the chosen surface; verify
   a session runs clean on native memory alone; then verify-before-delete the
   data.
3. **P3 — Cut dead-weight plugins** (searchfit-seo, ralph-loop,
   pr-review-toolkit, frontend-design per P1 outcome). One testable increment:
   rebuild, confirm the skill list shrinks, run structural checks.
4. **P4 — Superpowers trim** per §4 option. Extract keep-skills as standalone if
   (A); rebuild; confirm no SessionStart force-inject remains.
5. **P5 — Parity + docs.** lib/HM/devenv alignment, README/feature-matrix, any
   fragment that references the removed plugins.

## 7. Evidence appendix (so next session doesn't re-investigate)

- Enabled skills dir: `~/.claude/skills/` (18 entries; searchfit-seo,
  superpowers, ralph-loop, remember, hookify, security-guidance,
  pr-review-toolkit, frontend-design, feature-dev, code-review, code-simplifier,
  skill-creator, plugin-dev, mcp-server-dev, claude-md-management,
  claude-code-setup, gh-repo-settings, claude-code-home-manager).
- `remember` active store path: `/nix/store/…-claude-remember-31626fd/`
  (hooks.json → SessionStart + PostToolUse). Simpler older variant `…-f1a0038`
  also in store.
- superpowers force-inject: `…-superpowers-d884ae0/hooks/session-start` +
  `hooks/hooks.json` (SessionStart matcher `startup|clear|compact`).
- `.remember/`: 5.6 MB / 909 files, gitignored; `now.md` / `recent.md` /
  `today-*.md` / `archive.md` (no `core-memories.md` in this project despite the
  SessionStart header describing one).
- Marketplace source: `anthropics/claude-plugins-official` (note: `remember` and
  `superpowers` are NOT in that marketplace's plugin list — they come from the
  user's own `claude-code-home-manager` marketplace / this nix repo).

## 8. Next-session kickoff

Read this handoff in full, then run the living-plan-bootstrap prompt
(`docs/plans/living-workflow/living-plan-bootstrap.md`) against THIS doc as the
source. Scale to LITE or FULL per Step 0 (likely LITE→FULL boundary: it's
multi-session and side-effecting on config, but low-risk and reversible). Open
with the §5 [HITL@P1] batch — do not start cutting before those are answered.
