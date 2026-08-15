# `ai.*` normalized-interface rework, then semble #858 on top

> **Last verified:** 2026-08-14 against `main` at `0fe1f1fd`, by two
> verification passes (twelve agents, then seven) over the preceding design
> session's working notes. Every `file:line` below was re-read; 65 of 67 resolve
> exactly and the two imprecise ones are corrected in place. Main moved from
> `c5475438` during the session, but the six intervening commits touch only
> lockfiles and two overlay files, so no citation needed re-anchoring.
>
> **Items previously marked DECIDED or RESOLVED that were refuted: seven.** Four
> by the first pass (R1-R4) and three by the second (R5-R7). Do not re-derive
> them from older wording. The second pass also refuted one of the FIRST pass's
> own findings — see R6 — so treat nothing here as settled because a verifier
> said so; treat it as settled because a quoted line says so.

> **Re-anchor before trusting a citation.** Main moved `0fe1f1fd` → `2fe3ec4a`
> on 2026-08-14. Two cited files changed in that window —
> `packages/semble/agent-instructions.md` (#928) and
> `packages/semble/lib/templateCoverage.nix` (#901). Those are the citations to
> re-read; the rest were spot-checked against untouched files.

> **This document stands alone as the design record.** Every decision below is
> stated here with its evidence; nothing in it depends on a file outside the
> repository.
>
> **Operator-local addendum — useful, not required.** Live working state (merge
> order, in-flight PR status, open questions) is tracked separately in
> `private/ai-rework-open-decisions.md`, which is gitignored (`.gitignore:72`)
> and so exists only in the operator's own checkout. An agent session running
> there should read it for current status. **If that file is absent you are in a
> clone or a worktree, which is expected and fine** — read on, and treat what
> follows as design rationale rather than a status report.

Sequencing: the `ai.*` rework lands first, in several PRs; semble #858 is
re-implemented on top. No back-compat requirement — a single consumer, who will
wait for the whole stack.

`docs/plan.md` is the tracked backlog and is out of scope for this document.

## PR sequence — RE-DERIVED 2026-08-15 from the semble goal

> **This replaces a nine-row sequence, and the reason it was replaced is the
> most useful thing on this page.** The original table was a queue of tasks with
> dependencies and **no per-row statement of why the row served #858**. That
> made it executable without being auditable: a session handed "PR 2" could do
> it perfectly while having no way to notice the row did not serve the goal.
>
> That is exactly what happened. #920 entered as row 2 with a hard "5 must
> follow 2" gate that was never tested against the goal, and an implementation
> session built it faithfully. The work was agreed and it shipped fine (#948) —
> but it gated nothing, and the operator spotted the disconnect before the agent
> did.
>
> **So every row below carries a why. A row that cannot state one in a sentence
> does not belong in this workstream.**

**The goal, stated from the issues rather than from this plan:** ship semble's
#858 features — `content` as a validated list on one server, opt-in CLI
instructions, and a typed named-agent with agent-scoped MCP — under the
consumer-facing options surface the operator designed on 2026-08-14, namely
`ai.programs.semble.*` for defaults and `ai.<runtime>.programs.semble.*` for
per-runtime override, replacing semble's four bespoke `runtimes` selectors.
**The `ai.*` rework is justified only insofar as it makes that surface
expressible.**

| #      | PR                                                                                                                                                                  | Why it serves #858                                                        | Gated by |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | -------- |
| **P0** | ✅ MERGED `74964926` — per-runtime skill pools, `lib/ai/runtimes.nix`, provenance guard                                                                             | Prerequisite for P1's factory; also closed the registry-location question | —        |
| **P1** | `ai.programs.*` factory + semble relocation — **ATOMIC** with the semble `runtimes` deletion, the `checks/module-eval.nix` parity rewrite, and `expectedCodexRoots` | **This IS the operator's designed surface.** Nothing else delivers it     | P0       |
| **P2** | semble #858 itself                                                                                                                                                  | The goal                                                                  | P1       |
| **P3** | Namespace move for `stacked-workflows` / `living-workflow` + `gitPreset` parity fix                                                                                 | Operator: "i do want to move the namespace by the end of this workstream" | P2       |

P1 is atomic because CI is red between any two of its four parts. Do not split
it, and in particular do not delete semble's `runtimes` selectors ahead of the
factory that replaces them.

### Moved OUT — real work, but not this workstream

Each of these failed the "why does it serve #858" test. None is cancelled; they
are unranked backlog until something asks for them.

- **#920 / #948 (Copilot HM path)** — shipped anyway, correctly, and gates
  nothing. See A3b. #920 stays OPEN for the product split, which is vetoed for
  now.
- **Per-pool-per-runtime capability gating** — belongs to #921.
- **Settings split** — this plan's own A4 says the "payoff is naming, not
  capability".
- **Retire `instructions` → keyed `rules` (A3)** — blocked on the Codex
  `AGENTS.md` cardinality measurement AND on the measured `ai.context`
  string+path evaluation failure. Semble is the live path-valued contributor, so
  this needs **re-design, not re-ordering**.
- **Pool negation `attrsOf (nullOr …)` (B10)** — #858 never asks for it. What
  #858 needs is B4 program-level override, which ships inside P1.

### The original sign-off, for the record

Operator, 2026-08-14: "you own order, so signed off on." That ratified the
**ordering**, not the scope — which is the distinction the re-derivation turns
on. The namespace move remains in scope by direct instruction ("deferring
towards end, is fine"), which is why P3 survives while four other rows did not.

| #   | PR                                                                                                                                                                                                      | Gated by |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| 1   | Pool-write fix (`lib/ai/mkSkillPackageModule.nix:56-57`) + unify the three runtime enumerations into one registry; **build** the A1 backstop (shipped as a provenance guard, not the scan A1 described) | —        |
| 2   | #920 Copilot HM path (2 literals + 4 assertions)                                                                                                                                                        | —        |
| 3   | Per-pool-per-runtime capability gating, generalizing `supportsShell`. **Does NOT drop `ai.kimchi.rules`/`rulesDir`** — mark kimchi a rules CONSUMER, because A3a makes it one in PR 5                   | 1        |
| 4   | Settings split — `nativeSettings`, `_integration_*` internal                                                                                                                                            | —        |
| 5   | Retire `instructions` → keyed `rules`, incl. level-stamping for order                                                                                                                                   | 2, 3     |
| 6   | Pool negation `attrsOf (nullOr …)` + net-new package-vs-package check                                                                                                                                   | 5        |
| 7a  | Delete semble `runtimes` (self-contained)                                                                                                                                                               | —        |
| 7b  | `ai.programs.*` factory + semble relocation — ATOMIC with the parity-test rewrite and the `expectedCodexRoots` fixture                                                                                  | 1, 3, 7a |
| 8   | Namespace move: `stacked-workflows` / `living-workflow` + its `gitPreset` parity fix                                                                                                                    | 7b       |
| 9   | semble #858 re-implementation                                                                                                                                                                           | 7b, 8    |

### The three "hard constraints" were audited 2026-08-15. None survived intact.

They are kept here as withdrawn rather than deleted, because each rested on a
real observation and only the dependency was wrong — and because a future
session that finds them missing may re-derive them.

- ~~**5 cannot be split**~~ — **PARTIAL.** Only the DELETION commit is
  unsplittable (`checks/options-doc.nix:42`, `:62` hard-code option names); the
  enabling half is additive and green standalone.
- ~~**5 must follow 2**~~ — **PARTIAL, and it was the row that caused the
  detour.** The live→dead move is only _unnamed_ `ai.instructions` on Copilot
  HM; named instructions and rules were already dead→dead. It never touched the
  devenv arm, which is the github.com reviewer path and the only Copilot surface
  the operator consumes. And it is dischargeable INSIDE A3 by the same
  concat-into-the-live-file treatment §A3a already mandates for kimchi. See A3b.
- ~~**5 must follow 3**~~ — **REFUTED.** §A3a already says resolve kimchi in the
  SAME PR, so there was never a cross-PR dependency to enforce.

All three governed a PR that has since moved out of the workstream, so nothing
downstream depends on them. **Do not reinstate one without re-testing it against
the goal** — that is the failure this section exists to prevent.

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

`semble.mcp.content` default stays `["code"]`. **The decision stands; its stated
rationale was wrong twice and is replaced — see R5.** The correct reason is that
0.5.5 scopes the ON-DISK index directory by content set, and `["code"]` is the
one value that short-circuits to the legacy bare `index` directory, so it shares
an index with ordinary CLI usage instead of building a second copy.

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

**R5 — the `semble.mcp.content = ["code"]` rationale was wrong, twice.** The
decision survives; only the reasoning changes.

The original wording — "a per-call `content` builds a separate cached index per
content set, so defaulting broad multiplies indexes" — is **refuted**, because
the per-call selection REPLACES the server default rather than unioning with it
(`src/semble/mcp.py:44-52` at tag `v0.5.5`). Measured by executing upstream's
own `_resolve_content_selection` and `_compute_cache_key`: a `["code"]` default
and an `["all"]` default both yield exactly **4** distinct in-memory cache keys.
The only default that adds a variant is a MULTI-VALUE non-`all` one
(`["code","docs"]` → 5) — which is precisely the shape this plan's own decision
to make `content` a list newly enables, against a global 10-slot LRU
(`mcp.py:28`, `:287-289`).

The replacement rationale offered by that same pass — "a broad default just
makes the default index bigger" — is true but not decisive. **The decisive fact
is a SECOND cache neither earlier reading looked at.** 0.5.5 scopes the on-disk
index DIRECTORY by content set, where 0.5.4 had a single bare `index`:

```
# src/semble/cache.py @ v0.5.5
def find_index_from_cache_folder(path: str, content: Sequence[ContentType] = (ContentType.CODE,)) -> Path:
    cache_dir = resolve_cache_folder() / cache_key(path)
    scope = "-".join(sorted({content_type.value for content_type in content}))
    return cache_dir / ("index" if scope == ContentType.CODE.value else f"index-{scope}")
```

`["code"]` is the ONE value that resolves to the legacy `index` directory. Every
other value writes a separate `index-<scope>` tree. So the narrow default shares
an on-disk index with ordinary `semble` CLI usage, and any other default builds
and stores a second copy. That is the argument to record.

**R6 — "the runtime registry does not exist yet" is FALSE, and contradicted this
document's own A0.** `lib/ai/sharedOptions.nix:19` is a literal five-element
PRODUCTION list:

```nix
harnessNames = ["claude" "codex" "copilot" "kimchi" "kiro"];
```

A0 already cites that exact line as where the code "hardcodes the runtime
registry" — thirty lines before A1a claimed no registry exists. This is the same
class of self-contradiction this document audits its predecessor for. A third
enumeration lives at `checks/options-doc.nix:114`. The real problem is not
absence but **duplication**: three hardcoded lists, no shared one. See A1a.

**R7 — per-pool-per-runtime gating is NOT new; it already ships.**
`lib/ai/app/mkBackendTransform.nix:199-213` and `:322-332` declare
`ai.<name>.shell` only when the app record sets `supportsShell = true`, and
`dev/fragments/ai-module/shell-option.md` states the identical policy as a
standing house rule: "a surface without a lossless native mapping is an explicit
exclusion, not a silent no-op", with an unsupported runtime giving an "option
does not exist" eval error. That is exactly the mechanism ratified in A1a and
exactly the collapse A1b predicts. Follow `supportsShell`; do not invent a
second pattern.

### Open, with evidence now in hand

1. ~~The 0.5.5 bump must land first~~ — **DISCHARGED 2026-08-14.** #901 merged
   (`5497b5c6`); `reviewedHash` is `8305b33d…` on main; `test` went fully green,
   so the ~19 checks the eval-time throw had been masking all ran, including
   `semble-templates-extracted` — it really was one hash away, now proven rather
   than assumed. B0's prose action (teach the MCP `content` field in
   `packages/semble/agent-instructions.md`) landed as #928 (`2fe3ec4a`). **Read
   B0 below as recorded reasoning, not as outstanding work.**
2. ~~The runtime registry exists three times over and the factory must unify
   them~~ — **DISCHARGED 2026-08-15 by P0 (`74964926`).** `lib/ai/runtimes.nix`
   is now the single source, deliberately PLAIN DATA so it can be imported from
   a module, a derivation string and a test `let` alike; its header records why
   the `cacheHitParityTargets` shape could not be used. All four consumers were
   unified. **This also closed the open "where does the registry live"
   decision.**
3. ~~#920 must land before A3~~ — **REFUTED 2026-08-15.** It was never a gate;
   see A3b and the withdrawn-constraints section above. #920's HM fix shipped
   independently as #948 (`5089774c`).

**Nothing in this list is outstanding.** Every owed decision was either closed
by P0 or belonged to A3, which has moved out of the workstream. **P1 is
unblocked.**

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

A structural check is REQUIRED as a backstop, and **no such check exists today**
— `checks/` contains no root-pool scan and `flake.nix` registers none.

> **AMENDED BY IMPLEMENTATION, PR 1 (operator-approved).** The two paragraphs
> that followed here prescribed a **regex SOURCE SCAN** and constrained its
> patterns. **That is retired — do not build it, and do not re-derive it from
> this section.** The shipped backstop is a PROVENANCE guard
> (`rootPoolViolations` in `checks/module-eval.nix`): it reads each root
> option's `definitionsWithLocations` and fails when a definition originates
> from a file inside this flake, other than the module that DECLARES that
> option.
>
> The scan was built first, then measured to miss whole classes of write —
> including shapes this repo itself uses (`config.ai.<pool> = …`, a value moved
> to the next line, the interpolated `ai.${runtime}.<pool>` form) — and dynamic
> construction is undecidable in a regex, so that hole was permanent.
>
> **A1's one-line rejection of provenance was the error, and it is worth naming
> because it reads as decisive:** "an inline module reports `<unknown-file>`,
> indistinguishable from a consumer's inline config." True, and it points the
> WRONG WAY — `<unknown-file>` IS the consumer, and the consumer is exactly who
> is ALLOWED to write root options.
>
> Two measured facts the original text could not have known: an option's DEFAULT
> is itself a definition attributed to the DECLARING file (so a file allowlist
> masks defaults rather than reshape writes, which is why the rule compares
> against `opt.declarations`), and a definition suppressed by `mkIf false` is
> DROPPED entirely — so the guard sees only code paths its probe config reaches,
> and enabling every runtime in that config is load-bearing rather than
> cosmetic.
>
> A1's own preferred answer — "prefer a factory that … makes the fanout
> structural" — still stands, and PR 7b is what retires this guard for good.

Runtime provenance guards leak — an inline module reports `<unknown-file>`,
indistinguishable from a consumer's inline config — so prefer a factory that
generates both levels from one spec and makes the fanout structural.

**Scope hazard — sized 2026-08-14.** `lib/ai/mkSkillPackageModule.nix:56-57`
writes root `ai.skills` and `ai.instructions`, which A1 bans. Those two lines
are the **only** root-pool assignments anywhere in `packages/` or `lib/`.

The hazard is real but far smaller than the earlier wording implied, and it is
**separable** from the namespace move it was attached to:

- The per-runtime equivalents (`ai.<runtime>.skills`,
  `ai.<runtime>.instructions`) **already exist for all five runtimes with
  byte-identical types**, so fixing the writes declares no new options.
- **But the "2 changed lines" sizing is wrong in kind, not degree.** Once the
  package writes `ai.<runtime>.skills`, a consumer's root `ai.skills.<same-key>`
  stops being an override and becomes a hard `mergeWithCollisionCheck` failure
  (`lib/ai/ai-common.nix:405-419`), because `intersectAttrs` is
  **priority-blind** — stated in prose at `lib/ai/sharedOptions.nix:397-400` and
  already pinned by `checks/module-eval.nix:8735-8748`. That breaks the
  `mkDefault` override promise written at
  `lib/ai/mkSkillPackageModule.nix:42-43`, which must be rewritten to say the
  override key is now `ai.<runtime>.skills.<name>`.
- It also **flips always-loaded instruction ORDER**
  (`lib/ai/app/mkBackendTransform.nix:241` concatenates root-first), and a
  per-runtime write requires that runtime's module to be PRESENT in the eval —
  `devenv.nix:224-238` imports four of five. Gate on
  `lib.hasAttrByPath ["ai" name "skills"] options` (the shape
  `lib/ai/sharedOptions.nix:21` already uses) and add `options` to
  `mkSkillPackageModule`'s formals.
- **A1's proposed backstop check would never catch it.** That check is scoped to
  `packages/*/modules/**`, and the one violation in the tree lives in `lib/ai/`.
  Widen the scope or the check is theatre.
- **The namespace move cannot be a pure rename.** `checks/options-doc.nix` diffs
  every option starting with `ai.` for exact HM/devenv name and type parity, so
  `stacked-workflows.gitPreset` — HM-only today — fails that check the moment it
  moves under `ai.programs.*`. Its emission into `programs.git.settings` would
  also turn A0's "one real drift" into two.
- **Does leaving the writes as-is actually hurt?** Only once per-runtime
  negation ships: with `ai.<runtime>.programs.<pkg>` declared per B4, a root
  write means the negation evaluates clean and does nothing, silently. And
  stacked-workflows' `ai.instructions` stays unretractable per runtime even
  after B10, because B10 needs a key and that pool is a list until A3 lands.

Note also that this document never actually decided the move — it appeared on
one line, inside this hazard note, ending unresolved. **Recommendation for the
operator (not a decision): fold in the 2-line pool fix, defer the namespace
move.**

### A1a. The runtime registry exists three times — unify, do not invent

Corrected 2026-08-14 (R6). The earlier claim that no registry exists was wrong
and contradicted A0. There are **three** hardcoded enumerations:

- `lib/ai/sharedOptions.nix:19` — `harnessNames`, production, the one A0 already
  names as drift;
- `checks/options-doc.nix:114` — a **FOUR**-element list,
  `["claude" "codex" "copilot" "kiro"]`, deliberately WITHOUT kimchi.
  Substituting the five-element registry here adds two new grep assertions for
  `ai\.kimchi\.enable` against the HM and devenv CommonMark renderings. Whether
  those pass is **UNMEASURED** — verify before substituting, and if kimchi is
  excluded on purpose the registry needs a per-consumer filter rather than a raw
  list. "Unify the three" is therefore not a substitution;
- `checks/module-eval.nix:644` — a test fixture.

`lib/ai/apps/default.nix` is an empty stub filled by a barrel fold, so there is
no single canonical list. The factory's job is therefore to **unify these three
into one shared registry**, not to introduce a first one — and folding
`sharedOptions.nix:19` into it also retires half of A0's documented drift.

That registry becomes the substrate #921 wants for capability declaration.

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

**This is not speculative — the repo already does it** (R7). `ai.shell` is
declared only when the app record sets `supportsShell = true`
(`lib/ai/app/mkBackendTransform.nix:199-213`, `:322-332`), and
`dev/fragments/ai-module/shell-option.md` records the identical policy as a
standing house rule:

> Apps that do not opt in get no option at all, so setting one is an "option
> does not exist" eval error rather than a value that evaluates cleanly and is
> dropped. This is the repo's standing rule that a surface without a lossless
> native mapping is an explicit exclusion, not a silent no-op.

So A1a and this section are generalizing an existing, documented mechanism from
one scalar to every pool. Reuse `supportsShell`'s shape rather than designing a
second one, and note its deliberate constraint: the flag is read off the app
RECORD, keeping it a build-time parameter that forces neither `config` nor
`pkgs`, which is what stops it reintroducing the `_module.args` recursion
documented against `proxyIsSupported`.

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
- B7″ does **not** block on A5a (see R2). A5a only decides B7″'s GRANULARITY:
  with the follow-up deferred, B7″ holds at file granularity for every runtime
  today and needs no new work; key-granularity override is what the follow-up
  buys.

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

### A3b. #920's Home Manager path defect — fixed, and NOT a prerequisite

> **Shipped as PR #948 — and NOT as a prerequisite for anything.** This section
> is retained as the record of the defect and its fix; its original claim that
> #920 gates A3 was audited on 2026-08-15 and does not hold (see the sequencing
> note below). The two literals now interpolate `cfg.configDir`, and the four
> `checks/module-eval.nix` accessors moved to `.copilot/instructions/`.
>
> Four refinements the original section did not specify, recorded so they are
> not re-litigated:
>
> 1. **The `configDir` pin is GATED on there being content to lose** — it
>    requires the default only when a named instruction or a rule exists. An
>    unconditional pin would break a consumer using `configDir` purely as the
>    wrapper-aimed MCP root, which still works because `--additional-mcp-config`
>    is handed the path explicitly.
> 2. **Its accepted cost is a false positive**, named here rather than left to
>    be rediscovered: a consumer who sets `COPILOT_HOME` themselves has a real
>    reason to move `configDir`, and Nix cannot see that variable. The escape,
>    if that consumer appears, is to widen the assertion — not to un-gate it.
> 3. **The four existing accessors were not merely re-pointed.** Three now also
>    assert the `$HOME/.github/` key is ABSENT; re-pointing alone would let a
>    regression that wrote BOTH paths pass. A new check,
>    `module-copilot-hm-config-dir-pinned-when-rules-present`, covers the
>    assertion with two passing arms as its positive control, since a
>    failure-asserting test is satisfied for free by a harness that produces no
>    assertions at all.
> 4. **The gate covers THREE artifact classes, not two.** Named instructions,
>    rules, AND the composed context file (`<configDir>/<contextFilename>`,
>    default `copilot-instructions.md`) are all discovered by Copilot walking
>    its own home. An earlier revision of the assertion covered only the first
>    two and described them as "the only artifacts here", which left
>    `ai.context` alone reproducing the very defect being fixed — it is emitted
>    in a different `mkMerge` branch, which is what made it easy to miss.
>
> **The destination was re-measured, and it is live.**
> `$HOME/.copilot/instructions/**/*.instructions.md` is in copilot-cli 1.0.80's
> own discovery enumeration, and a marker file placed there reaches the outgoing
> system prompt. Worth doing rather than assuming: the defect being fixed was a
> write to a path nobody reads, so "the new path is read" is exactly the premise
> that must not be inherited on trust. Evidence and method are in
> `dev/fragments/ai-clis/copilot-config-delivery.md`.

Copilot rules and named instructions are **dead on Home Manager**:
`packages/copilot-cli/lib/mkCopilot.nix:281` and `:294` write to
`$HOME/.github/instructions/…`, which copilot-cli never reads. The devenv path
(`:528`, `:539`) is correct. `configDir` defaults to `.copilot` (`:130-134`), so
the fix target is `${cfg.configDir}/instructions/`.

Verified 2026-08-14: still present on `main`, and **four
`checks/module-eval.nix` assertions (`:3584`, `:4826`, `:6112`, `:7805`) lock
the buggy path in**. So the rework will not fix it incidentally — it needs its
own change, and the tests must change with it.

**The sequencing claim — "5 must follow 2" — was AUDITED 2026-08-15 and does not
hold.** It is recorded here as withdrawn rather than deleted, because the
underlying observation is still true and only the dependency was wrong.

The observation: A3 landing first would migrate Copilot's Home Manager content
_from a live file into a dead one_. What the audit found:

- the live→dead move is only **unnamed** `ai.instructions` (`mkCopilot.nix:307`
  live versus `:281`/`:294` dead) — named instructions and rules were already
  dead→dead, so there was less at stake than the claim implied;
- it does not touch the **devenv** arm, which is the github.com reviewer path
  and the only Copilot surface the maintainer consumes;
- and it is dischargeable **inside** A3 by the same concat-into-the-live-file
  treatment §A3a already mandates for kimchi — so even where it bites, it needs
  no separate PR ahead of A3.

**Consequence:** #920 is ordinary work that stands on its own merits, not a
gate. It shipped as #948 with zero dependents. Do not reintroduce it as a
prerequisite.

#### Sized 2026-08-14 — smaller than this section implied, and it is ONE PR

The HM and devenv emission blocks are **byte-identical** apart from `home.file`
vs `files` and the path prefix, so there is no structural divergence to
reconcile. The fix is **two string literals** in `mkCopilot.nix` (`:281`,
`:294`) plus **four one-line accessor changes** in `checks/module-eval.nix`
(`:3584`, `:4826`, `:6112`, `:7805`).

Two findings change how it should be written:

- **`${cfg.configDir}/instructions/` is only correct while `configDir` is
  `.copilot`.** The option is user-settable, there is no instructions equivalent
  of `--additional-mcp-config`, and the wrapper does not set `COPILOT_HOME`. So
  the fix needs either an assertion pinning `configDir`, or delivery through
  `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` — which was measured working across three
  separate directory layouts.
- **The always-on collapse is NOT user-tier-specific, so A3 is not made lossy by
  it.** Measured against copilot-cli 1.0.79's assembled system prompt: every
  universal-`applyTo` file is concatenated into one undelimited run with its raw
  YAML frontmatter injected as prose — and the project tier this plan called
  "correct" already behaves identically today. Scoped rules keep full per-file
  identity via the `| Pattern | File Path | Description |` index row. **A3b's
  sequencing still holds**, for the simpler reason that a dead file is worse
  than a live one.

`description` already exists on both `instructionModule` and `ruleModule` and is
already forwarded by `mkRenderer`; only the Copilot transformer discards it.
Wiring it is ~5 lines and — verified — does not churn the 19 generated
projections.

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
- **Normalized layers translate; native layers emit.** The translate-to-emit
  seam is where derived and user-authored values meet — but there is **no custom
  guard** there. Per B7″ and A5, the module renders at `mkDefault` and the
  standard Nix option merge arbitrates, at FILE granularity.
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

#### The review the gate is asking for — answered

The recorded disposition is "the module intentionally ships CLI guidance; the
MCP server contributes its tool guidance at session start." That delegation was
tested directly, and **it does not hold**:

- the server's session-start `instructions` string is **byte-identical across
  0.5.4 and 0.5.5** and never mentions content selection at all;
- the `content` parameter descriptions are bare one-liners — "Content to search.
  Defaults to the MCP server's configured content." and "Content containing the
  related file. Defaults to the MCP server configuration."

So there is no channel by which the MCP server teaches an agent that per-call
content selection exists, beyond the enum appearing in a JSON schema. **Prose
guidance is therefore needed**, and `packages/semble/agent-instructions.md`
should teach the MCP `content` field alongside the CLI flag.

This matters more than a documentation nicety because of R5: `["code"]` is
deliberately narrow, and its narrowness is only cheap if the model widens per
call. The design depends on a behaviour nothing currently teaches.

Landing mechanics (measured, and they differ per file):

- `agent-instructions.md` is under **no hash gate**. Its only consumers are a
  Nix _path_ reference (`packages/semble/lib/integrations.nix:4`) and four
  **path-equality** assertions (`checks/module-eval.nix:2624`, `:2689`, `:2692`,
  `:2700`). Editing its bytes moves nothing, so it can land on `main`
  independently of the bump, at any time.
- `disposition` strings are free prose — `checks/semble-templates.nix:76` checks
  only that the key exists.
- `reviewedHash` must move **atomically with the snapshot**, so it belongs on
  the bump branch. That is safe: `.github/workflows/update.yml:358-404` detects
  non-bot commits and **refuses** the force-push at `:407`, keeping the PR
  alive. Precedent: PR #825, where a human commit sat directly on the bot's on
  this same branch. **But once a human commit lands there the sweep never
  rebases it again**, so land it promptly or it rots.

### B1. Upstream re-scope

- 0.5.5 adds a per-call `content` to both MCP tools; 0.5.4 has none.
- At both versions the server flag is argparse `nargs="+"`, choices
  `code docs config all`, default `["code"]`. `semble-mcp --content code docs`
  is valid, measured against the pinned binary.
- So content-scoped MCP **instances** are dropped. One server named `semble`.
  `content` becomes a list, with the scalar coerced. MCP routing guidance is
  dropped along with the topology.

**Audited 2026-08-14 — the caveat is discharged.** These were re-measured
against upstream Python source at tag `v0.5.5` and by executing the pinned 0.5.4
package out of the store. Results:

- `nargs="+"`, the four choices, and the `["code"]` default: **CONFIRMED** at
  both versions.
- bare `--content` exiting non-zero: **CONFIRMED**.
- `all` + scoped collapsing to all: **CONFIRMED**.
- duplicates: **PARTIAL** — they are inert everywhere that matters, but they are
  NOT normalised at the parse layer and survive into on-disk metadata. Rejecting
  them remains right; the stated reason ("upstream normalises them away") is
  imprecise.
- the cache-key claim: see **R5** — mechanism real, conclusion refuted,
  rationale replaced.

**No build is required to settle any 0.5.5 question.** The pinned bump builds
semble from `fetchFromGitHub` at tag `v0.5.5` with **zero patch phases**, so
reading the tag IS reading the artifact the bump produces. Control: for 0.5.4
the tag source is byte-identical to the realised store source (`mcp.py` and
`cli.py` both diff clean). Residual risk is limited to the `fetchFromGitHub`
hash, which CI catches.

**Correction to the option shape.** The 0.5.5 per-call MCP `content` is a SCALAR
`Literal["code","docs","config","all"]`, not a list (`src/semble/mcp.py:87-90`,
`:127-130`). "`content` becomes a list" applies to the **server flag only**. Do
not model the per-call field as a list.

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

**Codex per-agent `mcp_servers` is SETTLED at the config-schema level**
(2026-08-14), retiring the long-standing OFF-RAMP item — with one honest
residual.

Codex 0.147.0's agent-role deserializer uses `deny_unknown_fields`, which makes
the test discriminating rather than an absence-of-error read:

- an unknown key returns `unknown field`;
- `mcp_servers = "not-a-table"` returns
  `invalid type: string "not-a-table", expected a map` — **positive proof the
  key is in the schema**, not mere silence;
- a well-formed table parses clean, and the block is **agent-scoped**:
  `codex mcp list --json` stays `[]`.

The destination directory is confirmed at **syscall level** for both backends,
retiring the second untested premise. One precondition the plan did not state:
devenv's `.codex/agents/` is read only when the **project is trusted**.

**Residual, to be worded like B5's Kiro caveat rather than closed outright:**
consumption is proven at the config-schema level; runtime tool exposure during
an actual subagent turn stays auth-blocked and is NOT proven.

**Trap for whoever tests this next:** `codex debug prompt-input` and
`codex doctor` both report **clean for an agent file that is outright
unparseable**. Only `codex exec` is a valid oracle here.

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

**Known trap for the tests — corrected and re-sized 2026-08-14.** The
`checks/module-eval.nix:2655-2668` parity test does
`lib.mapAttrs (_: o: o.type.description)` one level deep, and a nested option
group has no `.type` and throws. Two corrections to the earlier wording:

- **The trap is LATENT, not live.** Every option group is flat at `c5475438`, so
  it fires only if the rework introduces nesting — which it will.
- **"Aborting the whole checks attrset" is WRONG.** Attribute values are
  independently lazy; a sibling check still evaluates. Verified.
- **`lib.isOption` recursion alone does NOT fix it.** There is no expected-value
  fixture to restructure, but the hard-coded six-key enumeration at `:2658-2665`
  still names the deleted option and still roots at `evaluated.options.semble`.
  Recursion also stops at submodule boundaries, where the repo's own `:2717`
  uses `getSubOptions` — follow that.

Blast radius: 12 semble tests in one 371-line block; 6 touched by the `runtimes`
deletion alone; 1 (`module-semble-runtime-selection`, `:2541-2571`) deleted
outright; 11 touched by the relocation. Plus 3 other checks, 5 `common.nix`
constructs, and 3 doc surfaces.

**Packaging:** the `runtimes` deletion is one self-contained PR. The relocation
must land **atomically** with the parity-test rewrite and the options-doc
fixture, because CI is red between any two of the three.

### B8. Surfaces that must change with semble

`packages/semble/{modules/options.nix,modules/common.nix,lib/mkSemble.nix,lib/integrations.nix,lib/templateCoverage.nix,cli-instructions.md,docs/semble.md,upstream-templates.json}`,
`checks/{semble-templates.nix,module-eval.nix}`, and `dev/generate.nix`.

Must not be edited directly: `README.md`, `.claude/rules/`,
`.github/instructions/`, `.kiro/steering/`. Regenerate with
`devenv tasks run --mode before generate:all`, then stage the tracked generated
outputs.

## Findings to bank separately

- ~~Fragment-versus-fragment contradiction on root emission~~ — **WITHDRAWN
  2026-08-14.** There is no contradiction. Reading `layered-fanout.md:97-99`
  scopes that pitfall to FILE emission (`home.file.*` / `files.*`), while
  `lib/ai/sharedOptions.nix:391` is an OPTION write. A0 above still describes
  the Git-SSH root emission as real drift on its own merits, but stop citing a
  fragment conflict that does not exist.
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

**Previous draft**, 52 citations against `c5475438`: 48 exact, 3 imprecise, 1
wrong — the `common.nix:227` case that motivated the tree-qualification rule at
the top of this document.

**This document**, 67 unique citations re-audited 2026-08-14: **65 resolve to
exactly the named construct, 2 are imprecise by one line, none are wrong and
none point at a missing file.** The two corrections are applied above:

- `mkCodex.nix:1039` is the assertion **message**; the assertion itself is
  `:1038`.
- `mkMcpServer.nix:20` is the **block head**; the `eval.config` return is `:36`.

Three citations lacked a directory path and are now qualified — the first is
`lib/ai/mkSkillPackageModule.nix:56-57`. Originally recorded as
(`mkSkillPackageModule.nix:56-57`, `layered-fanout.md:96`,
`ai-module-fanout.md:172-190`) though their content verifies; the first is
`lib/ai/mkSkillPackageModule.nix`.

The one internal contradiction the self-audit caught — A1a versus A0 on the
runtime registry — is recorded as **R6** and fixed in place. It was exactly the
class of error this document audits its predecessor for, which is the argument
for re-running this audit against any future revision rather than trusting that
a careful author avoids it.
