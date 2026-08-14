# `ai.*` normalized-interface rework, then semble #858 on top

> **Last verified:** 2026-08-14 against `main` at `c5475438`, by a twelve-agent
> verification pass over the preceding design session's working notes. Every
> `file:line` below was re-read at that commit unless the row says otherwise.
> Four items the previous draft listed as DECIDED or RESOLVED were refuted by
> that pass and are marked **REFUTED** in place — do not re-derive them from the
> older wording.

Sequencing: the `ai.*` rework lands first, in several PRs; semble #858 is
re-implemented on top. No back-compat requirement — a single consumer, who will
wait for the whole stack.

`docs/plan.md` is the tracked backlog and is out of scope for this document.

## Tree-qualification rule for citations

The previous draft cited `packages/semble/**` at two different tree versions
while declaring itself written against `main`, which is how a citation to a
132-line file at line 227 survived review. Every semble citation below is
tagged:

- **(main)** — resolves at `c5475438`.
- **(wt)** — resolves only in the uncommitted `feat/semble-content-routing`
  worktree, archived at `archive/semble-content-routing-pre-relocation`.

## Status

### Decided and still standing

The tenet (A0); `ai.programs.*` namespacing (A1); a factory over per-package
declaration (A1); deleting all four semble `runtimes` selectors; reversing the
pool guard so per-runtime overrides root (A2); the settings split (A4); the
whole of Part B's upstream re-scope and gate swap.

Negation shape: no `enable` field and no type promotion. Every pool becomes
`attrsOf (nullOr <valueType>)`, and `null` at the per-runtime level drops the
entry (B10). `attrsOf (nullOr path)` keeps `ai.skills.foo = ./dir` working, so
it widens rather than breaks, and `nullOr` has no fields to half-fill.

Merge operator: `//` is correct. Pool entries are atomic across levels (B3), so
shallow replace is the intended semantic rather than a limitation.

Two packages claiming one key: fail, at both root and per-runtime (B8/B9).
Level-versus-level replaces; package-versus-package fails.

`semble.mcp.content` default stays `["code"]` — upstream's own default, emits no
argument, and at 0.5.5 a per-call `content` builds a separate cached index per
content set, so defaulting broad multiplies indexes.

Version targeting: semble options are tied to the overlay, so the design targets
0.5.5 rather than the pinned 0.5.4. This makes the semble work depend on the
0.5.5 bump landing.

Decided 2026-08-14, after the verification pass:

- **The factory gates per-pool-per-runtime**, not per-runtime. Detail in A1a.
- **The "every artifact lands in a per-runtime option" rule is a follow-up PR**,
  folding only two cheap items into this rework. Detail in A5a.
- **The pre-relocation semble working tree is discarded**, preserved only as an
  archive ref. Detail in B7.

### Refuted by the 2026-08-14 verification pass

**R1 — "Absorb `lib/fragments.nix`'s existing `priority`; only the DEFAULT is
new." REFUTED on three independent legs.** `priority` is an untyped function
argument (`priority ? 0`, `lib/fragments.nix:29` and `:46`) read by exactly one
function, `compose` (`:48`) — and `compose` is never called from `lib/ai/` or
from any `packages/*/lib/mk*.nix`. The two pipelines share only `mkRenderer`,
whose frontmatter arguments (`lib/fragments.nix:186-193`) never see `priority`.
`ruleModule` (`lib/ai/ai-common.nix:221`) has no such field and no
`freeformType` to hold one. This is a new typed option, a new sort, and a new
provenance mechanism — not an absorption. See A3 for what replaces it.

**R2 — "The steeringFiles generalization is a prerequisite because B10 and B7″
both depend on the option existing." REFUTED, and its motivating example is
wrong.** B10 needs only null-filtering after `merged = topPool // cliPool`
(`lib/ai/ai-common.nix:418`), because every emitter maps over the merged pool.
Separately, the exemplar was backwards: Codex's derived `mcp_servers` does not
pass through `ai.codex.settings` at all. It is a let-binding at
`packages/chatgpt-codex/lib/mkCodex.nix:1015-1018`, and the option is **asserted
mutually exclusive** with it at `:1038`. Claude's `.mcp.json`, the other
exemplar, does pass through an option — upstream's
`programs.claude-code.mcpServers`.

**R3 — "Retiring `instructions` is safe; all four harnesses inject always-on
content." REFUTED for a fifth runtime.** The migration audit covered Claude,
Codex, Copilot and Kiro. Kimchi reads `mergedInstructions` and ignores
`mergedRules` entirely, so retiring `instructions` in favour of keyed `rules`
would leave Kimchi with **no always-on content at all**. See A3a.

**R4 — The A5 derived-versus-authored guard is listed as DECIDED and also as
deleted.** The previous draft decided that guard in its status block and deleted
it as row B7 further down. Row B7″ is the current position. A5 is rewritten
below to match, and its "fail on collision" arm is withdrawn.

None of these four appeared in the previous draft's own "asserted then refuted"
list. That list was not the safety net it looked like; this section replaces it.

### Open, with evidence now in hand

1. **The 0.5.5 bump must land first, and its CI is red for a reason that is
   itself a design decision.** Detail in B0.
2. **The runtime registry does not exist yet** and the factory must introduce
   it. Detail in A1a.
3. **#920 must land before A3.** Detail in A3b.

## Part A — the `ai.*` normalized interface

### A0. The tenet

Root `ai.*` is a normalized interface that fans out to `ai.<runtime>.*`.
Implementation happens at the runtime level. Granted exceptions: the CLI install
itself, and MCP services.

Verified: the root-to-per-app merge happens inside the per-runtime transform
(`lib/ai/app/mkBackendTransform.nix:53-67`), so root pools are read _by_ each
runtime rather than processed at root. Census: 10 of 16 root options are pure
fanout, 4 are reshape-only, 2 are genuine root implementation.

The one real drift is `ai.gitSshConfigWorkaround` plus `_sandboxSafeSshCommand`:
it builds a derivation at root (`lib/ai/sharedOptions.nix:28`), sniffs the host
module system (`:21`), hardcodes the runtime registry (`:19`), and emits into
`programs.git.settings.core.sshCommand` (`:391`) with no runtime transform. Two
fragments contradict each other about it — `layered-fanout.md:96` says "Never
emit from L1/L2/L2b" unqualified, while `ai-module-fanout.md:172-190` sanctions
exactly that emission.

### A1. Namespace

`ai.programs.<pkg>` for defaults, `ai.<runtime>.programs.<pkg>` for override and
negation, then `ai.<runtime>.<pool>` for the real work. Mirrors home-manager and
avoids `ai.<pkg>` colliding with `ai.<runtime>`.

**Load-bearing:** `ai.programs.*` must never write to a root pool. Root pools
are additive and cannot be retracted per runtime, so a root write makes
per-runtime negation silently fail to negate.

A structural check enforces it as a backstop: no file under
`packages/*/modules/**` may assign a root `ai.<pool>` outside an `ai.${runtime}`
path. Runtime provenance guards leak — an inline module reports
`<unknown-file>`, indistinguishable from a consumer's inline config — so prefer
a factory that generates both levels from one spec and makes the fanout
structural.

**Scope hazard, previously unassessed:** the decision to also move
`stacked-workflows` and `living-workflow` onto `ai.programs.*` collides with
this rule. `mkSkillPackageModule.nix:56-57` writes root pools today, which A1
bans. That migration is therefore not a rename; budget it as real work or defer
it out of this rework.

### A1a. There is no runtime registry to generate against

The factory needs a list of runtimes, and the repo does not have one.
`lib/ai/apps/default.nix` is an empty stub filled by a barrel fold, and the only
literal five-element list in the tree is a **test fixture**
(`checks/module-eval.nix:644`). So the factory must introduce the registry
itself, and that registry becomes the substrate #921 wants for capability
declaration.

**Generating for all five runtimes produces dead options for four of them**, so
the gate is **per-pool-per-runtime**, not a per-runtime allow-list — decided
2026-08-14. The factory generates for every runtime, but each **pool** is
declared only where that runtime actually consumes it.

Two consequences worth stating, because they are the reason this option was
chosen over the cheaper ones:

- It **removes** today's declared-and-dead `ai.kimchi.rules` / `rulesDir` rather
  than adding more of the same. That is a live bug fixed as a side effect, not
  new surface.
- It **is** the capability substrate #921 asks for. The same per-pool-per-
  runtime data that decides whether to declare an option can drive #921's
  degradation report and the native-landing-key declaration A5 needs. Building
  it once serves three consumers.

Kimchi census, which the previous draft omitted entirely:

| pool                    | kimchi      |
| ----------------------- | ----------- |
| `mcpServers`            | consumed    |
| `skills`                | consumed    |
| `instructions`          | consumed    |
| `context`               | consumed    |
| `environmentVariables`  | consumed    |
| `rules`                 | **ignored** |
| `agents`                | **ignored** |
| `lspServers`            | **ignored** |
| `hooks`                 | **ignored** |
| `settings` (normalized) | **ignored** |
| `shell`                 | **ignored** |

Two traps fall out of that table:

- `ai.kimchi.rules` and `ai.kimchi.rulesDir` are **already declared and dead
  today**, via the shared baseline at
  `lib/ai/app/mkBackendTransform.nix:286-303` — and they can hard-fail a build
  through the unconditional collision assertion. That is a live instance of
  exactly what #921 exists to stop, already in the tree.
- **Semble targeting kimchi would be an evaluation error**, not a degradation:
  no `ai.kimchi.agents` option exists to write to.

### A1b. Fail versus degrade — RATIFIED 2026-08-14

#921 carries a line no human ratified: "an unsupported _capability the user
explicitly asked for_ fails; an unsupported _portable default fanning out_
degrades." Working it against the per-pool-per-runtime gate decided in A1a shows
most of it dissolving.

**The "explicitly asked for" arm collapses into the module system.** Once a pool
is declared only where the runtime consumes it, writing
`ai.claude.programs.semble.mcp.rootExposure` on a runtime that cannot isolate is
not a policy failure — the option does not exist, and Nix raises its own
unknown-option error. That is already loud, already free, and needs no rule.

So the only surface where a rule is still needed is the **root** one, and there
"degrade" is not uniformly safe. The discriminator is not explicit-versus-
default; it is **what direction the drop moves you**:

| root value dropped at a runtime             | effect of dropping it                         | safe to degrade?                    |
| ------------------------------------------- | --------------------------------------------- | ----------------------------------- |
| `ai.skills.<k>` on a runtime with no skills | the skill is absent                           | yes — reduces capability            |
| `ai.agents.<k>.tools` on Codex              | the agent runs **unrestricted**               | **no** — more permissive than asked |
| `rootExposure = false` on Claude            | the server **is** exposed to the root session | **no** — inverts the intent         |

Both of #921's and #919's motivating cases are the same shape: a **restriction**
that, when dropped, yields a **more permissive** result. That is why the two
issues looked like opposite policies — they are not; they are one rule seen from
two sides.

Making those two cases hard failures is not workable either, because a root
`ai.agents.<k>.tools` that fails on Codex means no portable agent can ever carry
a tool allowlist across a runtime set including Codex, which defeats the
portable surface. The workable axis is the **signal level**, not fatality:

- drop **reduces** capability → silent; visible in #921's opt-in report;
- drop **increases** permissiveness → surfaced by default, because silence there
  is a security-shaped surprise, not a convenience;
- combination is **incoherent across pools** (e.g. `rootExposure = false` with
  no MCP-backed agent to claim the server) → assertion, genuine failure. This is
  the one case option-level filtering structurally cannot express, because the
  option exists and the value is legal.

The ratified rule: **drop silently only when dropping removes capability;
surface by default when dropping makes the result more permissive than asked;
fail only on relational constraints across pools.**

Ratified 2026-08-14 and written into #921, replacing the LLM-authored line. The
old wording — "an unsupported capability the user explicitly asked for fails; an
unsupported portable default fanning out degrades" — is retired; do not
implement it.

### A2. Negation and per-runtime override

`mergeWithCollisionCheck` already does `merged = topPool // cliPool`
(`lib/ai/ai-common.nix:418`), so per-runtime already wins in the data and the
assertion is a pure veto on top. "Reverse it" means delete the assertion and
keep the merge.

Per-runtime negation is **not** universally absent today. Two places already do
it: `ai.settings.reasoningEffort` fans into `ai.<runtime>.settings.effortLevel`
at `mkDefault`, and `ai.kiro.steeringFiles`
(`packages/kiro-cli/lib/mkKiro.nix:1179-1191`) is a real per-runtime override
surface that root `ai.rules`, `ai.instructions` and `ai.context` round-trip
through (`:663`, `:676`, `:684`, `:698`). It is `internal = true` and
undocumented, so it is load-bearing by accident rather than by contract.

What is genuinely missing is per-key deletion anywhere, and any per-runtime
surface at all for `mcpServers`, `skills`, `agents`, `lspServers` and
`environmentVariables`.

Corroborating that the pool guard is by design: closed issue #864 says of the
`ai.shell` work that "`shell` wants the opposite: per-runtime silently overrides
root. So this is a new merge semantic for a nullable scalar, **not another row
in that table**." Pool semantics were deliberately left fanout-only; negating
them is a new decision, not a bug fix.

**B8/B9 need a net-new check.** Package-versus-package collision is not what the
deleted assertion provided (`lib/ai/ai-common.nix:405`), so "fail on two
packages claiming one key" is new code, not a retained behaviour.

### A2a. Boundary table — the authoritative merge contract

**This table is the contract and it is expected to churn.** Any change to merge
or fanout logic must update it in the same commit, and the final PR must carry
that rule as a fragment instruction so it survives past this session.

Provenance: **M** measured from code or a probe · **H** human-decided with
stated reasoning · **H?** human-picked among options without a strong basis ·
**L** LLM-proposed, human-accepted without independent grading.

| #   | Boundary                                            | Unit    | Behavior                                                                                                                         | Prov |
| --- | --------------------------------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------- | ---- |
| B1  | root pool ↔ per-runtime pool, SAME key              | entry   | per-runtime replaces root's entry, wholesale                                                                                     | H    |
| B2  | root pool ↔ per-runtime pool, DIFFERENT key         | entry   | additive, both exist                                                                                                             | M    |
| B3  | inside a pool entry (a server record's fields)      | field   | **never merges across levels — entries are atomic**                                                                              | H    |
| B4  | `ai.programs.<pkg>` ↔ `ai.<runtime>.programs.<pkg>` | option  | `resolveOverride` — null inherits, non-null wins                                                                                 | L    |
| B5  | `ai.settings` ↔ `ai.<runtime>.settings`             | field   | `resolveOverride` per field                                                                                                      | H    |
| B6  | normalized → native                                 | —       | not a merge, a translation. Normalized never emits                                                                               | L    |
| B7  | ~~module-derived native keys ↔ user native~~        | ~~key~~ | **superseded by B7″ — do not implement**                                                                                         | H?   |
| B7″ | module-derived native value ↔ user-authored value   | file    | **no custom guard. Module renders at `mkDefault`; standard Nix option merge arbitrates.** Unit is the FILE, not the key — see A5 | H    |
| B8  | two packages → same ROOT key                        | key     | fail                                                                                                                             | H?   |
| B9  | two packages → same PER-RUNTIME key                 | key     | fail (same rule as B8)                                                                                                           | L    |
| B10 | negation                                            | entry   | **`null` at the per-runtime level drops the entry**                                                                              | H    |

B3 is why `//` is correct and `recursiveUpdate` is wrong: pool entries never
field-merge across levels, so shallow replace is the intended semantic.

**Correction to the previous draft:** the prose block that used to follow this
table prescribed a per-pool nullable `enable` field and submodule promotion.
That is stale and contradicts row B10. There is one mechanism —
`attrsOf (nullOr <valueType>)` — for every pool. When table and prose disagree,
check both against code; the previous draft's "prefer the prose" heuristic
picked the wrong survivor here.

**Sequencing constraints, previously unstated:**

- B10 depends on A3, because `ai.instructions` is a list rather than a keyed
  pool (`lib/ai/app/mkBackendTransform.nix:241`) and a list has no key to null
  out.
- B7″ depends on the scope call in A5a.

### A3. Retire `instructions`, keep keyed `rules`

`rules` is already the higher-order renderer: one file per key in the native
rules directory for Claude, Kiro and Copilot, while Codex appends rules
alphabetically to its single `AGENTS.md`. Concat-versus-split is already a
per-ecosystem parameter of one engine.

Migration deltas: none for Kiro (named instructions and rules both land in
`.kiro/steering/<name>.md`); none for Codex (both concat into `AGENTS.md`);
Claude and Copilot are the real change, where one composed always-loaded file
becomes N always-on rule files.

The loading question is settled for four harnesses. No harness makes the model
fetch always-on content; all four push it.

| harness | always-on                                          | path-scoped                                            |
| ------- | -------------------------------------------------- | ------------------------------------------------------ |
| Claude  | injected at session start, same block as CLAUDE.md | auto-appended in full on first matching file touch     |
| Kiro    | injected at prompt assembly, zero model cost       | —                                                      |
| Codex   | CLI reads `AGENTS.md` into the prompt blend        | —                                                      |
| Copilot | only when `applyTo` is universal                   | index row plus a `view` directive; body never injected |

Copilot lands in the injected tier because
`lib/ai/transformers/copilot.nix:19-27` already emits `applyTo: "**"` when
`paths == null`.

**Delete, do not alias — and the choice is mechanical, not a preference.** The
repo has zero uses of `mkRenamedOptionModule`, `mkAliasOptionModule`,
`mkRemovedOptionModule`, `mkChangedOptionModule` or `doRename`, so there is no
house pattern to follow. More decisively, `doRename` declares the old path with
the _new_ option's type, so aliasing `listOf instructionModule` onto
`attrsOf ruleModule` would reject every existing consumer value on day one. The
one primitive that handles a type change, `mkChangedOptionModule`, sets
`config.warnings` unconditionally and would break `checks/factory-eval.nix:417`,
which evaluates `sharedOptions` standalone with no `warnings` option.

Blast radius of the delete: 2 declaration sites erasing 12 option paths, 1 type
(`instructionModule`), 1 file that becomes dead
(`lib/ai/composeInstructionsFile.nix`), 17 consumer files, 32 test and check
assertion points, and 13 markdown files. **There is no green intermediate
state** — two of those assertion points are hard-coded option names in
`checks/options-doc.nix`'s cross-backend parity check — so this cannot be split
across PRs.

**Trap:** `<agent>.instructions` (`lib/ai/agent.nix:19`) is a completely
separate option. It is the agent system prompt and the discriminator in
`isSemantic`. It must not be retired.

#### Ordering, replacing the withdrawn `priority` plan (R1)

Only **one** ecosystem has an ordering this repo controls: Codex's `mkAgentsMd`
(`packages/chatgpt-codex/lib/mkCodex.nix:791-802`), where "alphabetically" is
just `lib.mapAttrsToList` over a Nix attrset. Claude, Copilot and Kiro each emit
one file per rule key with no sort anywhere
(`packages/claude-code/lib/mkClaude.nix:912-919`,
`packages/copilot-cli/lib/mkCopilot.nix:293-300`,
`packages/kiro-cli/lib/mkKiro.nix:684-689`) — order is the harness's business,
not ours.

So `priority` is **Codex-only**, and it **replaces** the key ordering rather
than composing before or after it. That answers the open question directly: the
question assumed a composition that does not exist.

The harder half: reproducing today's root-before-runtime order. The `++` that
guarantees it (`lib/ai/app/mkBackendTransform.nix:241`) covers `instructions`
**only**. Rules go through `topPool // cliPool` (`lib/ai/ai-common.nix:418`),
which **destroys level provenance**. A scalar default therefore provably cannot
reproduce root-before-runtime — **the level must be stamped onto each entry
before that merge**, and the sort reads the stamp. Budget that as part of A3.

### A3a. Kimchi loses its only always-on surface (R3)

Kimchi reads `mergedInstructions` and never reads `mergedRules`. Retiring
`instructions` therefore silently deletes kimchi's only always-on content. This
must be resolved in the same PR, by one of:

1. teach `mkKimchi` to consume `mergedRules` (preferred — it is the same
   concat-into-one-file shape Codex already uses);
2. declare kimchi as not supporting always-on content and drop the option there
   under #921's rule;
3. defer A3 until kimchi's rules support lands.

Option 1 is the only one that does not lose a working feature.

### A3b. #920 must land before A3

Copilot rules and named instructions are **dead on Home Manager**:
`packages/copilot-cli/lib/mkCopilot.nix:281` and `:294` write to
`$HOME/.github/instructions/…`, which copilot-cli never reads. The devenv path
(`:528`, `:539`) is correct. `configDir` defaults to `.copilot` (`:130-134`), so
the fix target is `${cfg.configDir}/instructions/`.

Verified 2026-08-14: still present on `main`, and **four
`checks/module-eval.nix` assertions (`:3584`, `:4826`, `:6112`, `:7805`) lock
the buggy path in**. So the rework will not fix it incidentally — it needs its
own change, and the tests must change with it.

**The sequencing is the point:** A3 landing first would migrate Copilot's Home
Manager content _from a live file into the dead one_, converting a
partly-working surface into a fully-dead one.

### A4. Settings split

Three things share `ai.<runtime>.settings` today: user native passthrough
(freeform); a module-written integration channel (`_integration_writable_roots`,
written with `mkAfter` by glab and semble); and the normalized fanout's landing
spot.

Settles as `ai.settings` (normalized, typed, closed — already is),
`ai.<runtime>.settings` (same normalized type, narrows root — new),
`ai.<runtime>.nativeSettings` (today's freeform passthrough, renamed), and
`_integration_*` moved to an `internal = true` namespace.

Three rules fall out:

- **A third category exists and stays put.** Typed runtime-specific options the
  module models — `ai.claude.plugins`, `ai.kiro.identity`, `ai.codex.profiles`,
  `ai.kiro.mcpWriteMode` — are not freeform passthrough and do not migrate. The
  split is three-way: normalized, typed-native, freeform-native.
- **Normalized layers translate; native layers emit.** The boundary guard sits
  exactly at the translate-to-emit seam.
- The immediate payoff is naming, not capability. Per-runtime suppression
  already works by writing the native key.

### A5. The derived-versus-authored boundary (rewritten — R4)

MCP already works the way the tenet predicts: root and per-runtime pools merge
to `mergedServers`, then each runtime renders via the shared
`lib.ai.renderServer` into its own native destination. That is not a special
case.

The "special treatment" is a guard against the freeform escape hatch, solved two
different ways: Codex asserts (`packages/chatgpt-codex/lib/mkCodex.nix:1039`),
Claude excludes (`separatelyHandledSettingsKeys`,
`packages/claude-code/lib/mkClaude.nix:991`). That inconsistency is the real
smell.

**The previous draft's answer — one shared helper that merges keys and fails on
key collision — is withdrawn.** Row B7″ is the position: render at `mkDefault`
and let the module system arbitrate. But the verification pass established that
this is **not free**, and the previous draft's reason for believing it was free
was wrong.

**Every runtime's native MCP home IS a keyed table** — this refutes OFF-RAMP
item 4 in the design's favour. Copilot writes `${cfg.configDir}/mcp-config.json`
containing a `mcpServers` table keyed by server name
(`packages/copilot-cli/lib/mkCopilot.nix:264-268` for HM, `:511-515` for
devenv), and `--additional-mcp-config` takes an `@`-prefixed **file path**
(`packages/copilot-cli/lib/wrapPackage.nix:67-70`), so "process-wide" describes
the flag, not the file's shape. All five runtimes, kimchi included, build the
same server-name-keyed table.

**But a keyed table is not a keyed OPTION, and B7″ needs the latter.** Only
Claude has one, and it belongs to the upstream module
(`packages/claude-code/lib/mkClaude.nix:860`). Copilot, Kiro and Kimchi
`builtins.toJSON` straight into a file's `.text` with no option in between, and
Codex resolves the conflict with the very assertion B7″ deletes
(`packages/chatgpt-codex/lib/mkCodex.nix:1037-1040`, `:1148-1151`).

**Adjudication — what B7″'s Unit actually is.** `home.file` and `files.*` _are_
options, and `mkForce` on them works normally. So B7″ holds at **file**
granularity today, for every runtime, with no new work. It does **not** hold at
**key** granularity, because `builtins.toJSON` has already collapsed the
structure by the time the module system sees a string. The table's Unit column
now says `file` for B7″ to record this.

That is the whole of A5a's scope question: key-granularity override is what
costs work.

### A5a. Scope call — "every generated artifact lands in a per-runtime option"

**Decided 2026-08-14: follow-up PR, not this rework.** The claimed dependency
was refuted (R2), so nothing in B7″ or B10 blocks on it.

Sizing, measured: **23 new options** under a pragmatic rule (claude 4, codex 5,
copilot 6, kimchi 3, kiro 5), or roughly **40** under the previous draft's
literal rule, spread across 5 factories × 2 backends. Four items resist the
treatment structurally: Kiro `mcp.json`'s activation-time secret substitution,
Codex's leaf-reconciled `config.toml`, Claude devenv's four-writer
`settings.json` deep merge, and Claude HM's plugin-dir-embedded `.mcp.json`.

The real partition is **declarative-versus-script-written**, not the previous
draft's "option-shaped versus file-shaped": declaratively-written artifacts
already have an option handle via `home.file`/`files.*`. Only script-written
artifacts (~8 surfaces) are genuinely blocked, and exactly one — Kiro hooks —
has no handle at all today.

Fold into **this** rework only the two cheap items: de-internalize
`ai.kiro.steeringFiles`, and promote `mkHookEntries` to an `ai.kiro.hookFiles`
option.

Consequence to accept knowingly: until the follow-up lands, **B7″ overrides work
at file granularity only.** A user can `mkForce` a whole `.mcp.json` or
`mcp.json`, but cannot override one server key inside it on Copilot, Kiro or
Kimchi, because `builtins.toJSON` has already collapsed the structure by the
time the module system sees a string. Claude is the exception — it has a real
keyed option, upstream's `programs.claude-code.mcpServers`.

## Part B — semble #858 on top

### B0. The 0.5.5 bump is the prerequisite, and its red CI is a design decision

The bump arrives **transitively** through the `llm-agents.nix` flake input
(#901, `chore: update input llm-agents`), not as a direct semble bump.

Exactly one check is red, and it is a true positive of a deliberate human-review
gate — **not** the mechanical tool-surface gate, which does not exist on `main`
yet:

```
checks/semble-templates.nix:84
error: Semble installer instructions changed; review the derivative and update templateCoverage.nix
```

`instructions.reviewedHash` moves `612e9f99…` → `8305b33d…`. All four template
pins are unchanged and would pass; line 85 is never reached. Three of four
required checks are green.

**The red masks the rest of `nix flake check`.** It throws at evaluation time,
so roughly 19 checks never ran — including `semble-templates-extracted`, the one
that would confirm the bot's snapshot regeneration is byte-correct. Do not treat
the bump as one hash away from green.

The delta the pin is guarding: **both MCP tools gain a per-call `content`
argument**, where 0.5.4 exposed content selection only as a CLI flag.
Corroborated against the live 0.5.4 server, whose `search` schema is
`{query, repo, top_k, max_snippet_lines}` with no `content` field.

### B1. Upstream re-scope

- 0.5.5 adds a per-call `content` to both MCP tools; 0.5.4 has none.
- At both versions the server flag is argparse `nargs="+"`, choices
  `code docs config all`, default `["code"]`. `semble-mcp --content code docs`
  is valid, measured against the pinned binary.
- So content-scoped MCP **instances** are dropped. One server named `semble`.
  `content` becomes a list, with the scalar coerced. MCP routing guidance is
  dropped along with the topology.

**Caveat carried forward:** these upstream measurements and the 0.5.5 cache-key
claim were made by the previous session and were **not** re-audited by the
verification pass, despite four decided items resting on them. Re-measure before
implementing B1.

Validation rules:

| rule                  | reason                                                       |
| --------------------- | ------------------------------------------------------------ |
| reject `[]`           | `nargs="+"` means bare `--content` exits non-zero at runtime |
| reject duplicates     | upstream normalises them away; only argv noise remains       |
| reject `all` + scoped | upstream collapses to all, so the scoped entry is a lie      |

Lowering differs by path and must: the module uses `assertions` (message
testable via `lib.hasInfix`), while `mkSemble` must `throw`, because an
assertions block is silently discarded there — `lib/mcp.nix:25-34` and
`lib/ai/mcpServer/mkMcpServer.nix:20` both return `eval.config`.

Emit `["--content"] ++ sorted content`, not one flag per value. `["code"]` emits
nothing.

### B2. Prompts

Two committed files, not a renderer. Measured overlap is about two sentences of
roughly forty lines, differing even there. Decisive: the CLI text is also the
always-loaded global instruction, while the MCP text is agent-only.

`integrations.nix` must stay argument-free — making it a function breaks the
published `nat.lib.ai.semble.*` shape.

`writeText` is ruled out three ways: IFD on Kiro's `prompt`, silent store-path
leakage on the instruction surfaces, and `mkDefaultRecursive` shredding a
derivation into `{drvPath,outPath,type}`.

### B3. Drift gate swap

Drop `reviewed.instructions` and its hash assert. Add a mechanical MCP
tool-surface guard: a JSON-RPC `tools/list` probe feeding `mcpTools` into the
snapshot, asserted exact against a reviewed surface. Add the provenance assert
that the embedded `semble[mcp]==X.Y.Z` equals `package.version`. Keep
`instructions` in the snapshot so the prose delta stays visible in update PR
diffs.

Precision: would not have fired on 0.5.3 → 0.5.4; does fire on 0.5.4 → 0.5.5.

### B4. Runtime capability matrix

| runtime | own MCP server per agent          | MCP tool allowlist | true isolation         |
| ------- | --------------------------------- | ------------------ | ---------------------- |
| kiro    | yes (freeform tail)               | yes (tags)         | **yes**                |
| codex   | mechanically yes (TOML tail)      | no                 | consumption UNVERIFIED |
| claude  | no (no `freeformType`)            | yes                | no — narrowing only    |
| copilot | no (one process-wide config file) | yes                | no                     |

`tools` has three spellings: Claude and Copilot take `mcp__semble__*`; Kiro
takes capability **tags** (`@semble`); Codex takes none — and the mechanism that
drops it for Codex is `lib/ai/agent.nix:50-56` (`renderCodex`), reached from
`packages/chatgpt-codex/lib/mkCodex.nix:763`, **not**
`lib/ai/sharedOptions.nix:185-186`, which is option-description prose.

**Live pre-existing bug:** `kiroAgent.tools = ["shell" "read"]` with
`includeMcpJson` defaulting false means today's Kiro semble agent cannot call
the semble MCP server at all.

**Codex per-agent `mcp_servers` remains unverified**, and the previous draft
under-stated it: the destination directory `<configDir>/agents/` is _itself_
unverified — no `$CODEX_HOME/agents` literal exists in the binary — so "the file
is written correctly" carries a second untested premise. The file's content
shape is corroborated against codex 0.147.0's agent-role validator.
`ai.codex.profiles` does **not** moot the question: `--profile` layering is
confirmed upstream, but the option is hard-locked by
`assertion = profiles == {}` (`packages/chatgpt-codex/lib/mkCodex.nix:606`) and
fails evaluation if set. The overlay ships a prebuilt binary with no source, so
every Codex upstream-semantics question here is answerable only by `strings`, by
running it, or over the network.

### B5. Kiro execution proof

Measured in a Nix sandbox: `kiro-cli-chat acp --agent <name>` plus `initialize`
and `session/new` reports the agent-scoped server running with two tools, in
about a second, with zero added closure. Negative control discriminates.

- `SSL_CERT_FILE` is required or kiro panics; the blocker was never the network.
- v2 ACP engine only — v3 needs a runtime-downloaded KAS bundle.
- `kiro-cli agent validate` exits 0 on failure; assert on stderr.
- It does **not** prove a model turn called the tool (auth-blocked). #858's
  acceptance criterion must be reworded to what is provable rather than faked.

### B6. Option set under the relocation

`mcp.rootExposure` stays. It is not redundant under A2: negating
`ai.<runtime>.programs.semble.mcp` turns semble's MCP off for that runtime
entirely, agent included, whereas `rootExposure = false` suppresses only the
`mcpServers` pool entry while leaving the agent's own server block intact.

Verified (wt): `rootExposure` writes the **per-runtime** pool
(`packages/semble/modules/common.nix:155`), so it is not the A1 violation it
superficially resembles.

#919 tracks generalizing this — every MCP server should support agent isolation,
not just semble's. `rootExposure` is a package-local shorthand to be retired in
favour of the generalized mechanism.

`instructions.cli.enable` may collapse into "does the keyed rule entry exist for
this runtime" under A3.

### B7. Code written but not yet reworked

**Status 2026-08-14: the working tree was discarded and the branch reset to
`c5475438`.** The branch had zero commits, so all of it was unbacked
working-tree state; it now exists only as the archive ref below, which is pushed
to origin. Recover a file with
`git checkout archive/semble-content-routing-pre-relocation -- <path>`.

`contentScope.nix` and the two prompt markdown files are relocation-independent
and can come back verbatim. `modules/options.nix` and `modules/common.nix` are
the parts that need genuine rework, since they encode the pre-relocation
`semble.*` prefix and the four `runtimes` selectors that A1 deletes.

Archived at `archive/semble-content-routing-pre-relocation` (566 lines across 9
files) so it cannot be lost: `contentScope.nix` (new, unit-verified),
`mkSemble.nix`, `integrations.nix`, `modules/options.nix`, `modules/common.nix`,
the `cli-instructions.md` rename, `mcp-agent-instructions.md`,
`checks/semble-mcp-surface.py`, and the `checks/semble-templates.nix` gate swap.

**Known trap for the tests:** the `checks/module-eval.nix:2655-2668` parity test
does `lib.mapAttrs (_: o: o.type.description)` one level deep. A nested option
group has no `.type` and throws, aborting the whole checks attrset. Make it
recurse with `lib.isOption`. Separately, `checks/module-eval.nix:2661` reads
`options.semble.runtimes`, so deleting that option breaks the parity test
independently of the nesting trap.

### B8. Surfaces that must change with semble

`packages/semble/{modules/options.nix,modules/common.nix,lib/mkSemble.nix,lib/integrations.nix,lib/templateCoverage.nix,cli-instructions.md,docs/semble.md,upstream-templates.json}`,
`checks/{semble-templates.nix,module-eval.nix}`, and `dev/generate.nix`.

Must not be edited directly: `README.md`, `.claude/rules/`,
`.github/instructions/`, `.kiro/steering/`. Regenerate with
`devenv tasks run --mode before generate:all`, then stage the tracked generated
outputs.

## Findings to bank separately

- Fragment-versus-fragment contradiction on root emission:
  `layered-fanout.md:96` versus `ai-module-fanout.md:172-190`.
- Eight files under `lib/ai/` match no architecture category, including
  `lib/ai/dir-helpers.nix` — the file `dir-helpers.md` documents by name.
- `services.mcp-servers` is root-scoped into a vacuum: `mcpConfig` is
  `internal = true` and nothing reads it.
- The credential proxy daemon is emitted per evaluated app record
  (`lib/ai/app/mkBackendTransform.nix:366`, outside `mkIf cfg.enable`),
  surviving only because the five definitions are byte-identical.
- `ai.kiro.steeringFiles` is a real per-runtime override surface but is
  `internal = true` and undocumented.
- `semble.*` is in neither `hmPrefixes` nor `devenvPrefixes`
  (`lib/options-doc.nix:260-268`, `:294-301`) — **confirmed verbatim**. But the
  benefit of fixing it by relocation is overstated: nothing publishes those
  renderings any more (`lib/options-doc.nix:7-9`), the only live consumer is
  `checks/options-doc.nix`, and semble is the **only** uncovered root — adding
  `"semble."` to both lists fixes the coverage without moving anything. Use
  options-doc as a consequence of relocation, never as its justification.
- Relocating under `ai.*` **acquires a constraint**: it enrols semble in
  `checks/options-doc.nix`'s mandatory HM/devenv exact-parity gate (lines 80-98,
  four `startswith("ai.")` sites). Free today because both backends import one
  `options.nix`, but any future HM-only or devenv-only semble option becomes a
  CI failure rather than a design choice.
- The options-doc prefix lists carry four dead entries (`programs.copilot-cli.`,
  `programs.kiro-cli.`, `copilot.`, `kiro.`) matching no declared option —
  evidence the allowlist drifts unchecked.
- `packages/semble/docs/semble.md` is unregistered in
  `config/fragment-categories.nix` and linked from nowhere.
- `semble.*.runtimes` was introduced in `80cc3f84` / PR #701 with no rationale
  recorded in commit, PR, review, issue or fragment.
- The in-repo comment at `packages/gitlab-mcp/modules/mcp-server.nix:323` cites
  `lib/mcp.nix:27-37` when the construct is at `25-34`.

## Citation audit result

52 `file:line` citations were extracted from the previous draft and checked
against `c5475438`: **48 resolve exactly, 3 are imprecise** (block-head or
adjacent-comment rather than the named construct), **1 was wrong** — the
`common.nix:227` case that motivated the tree-qualification rule at the top of
this document.
