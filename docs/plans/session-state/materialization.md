# Session state — materialization (symlink vs real file)

> **Handoff artifact.** Written 2026-07-21 so three concurrent sessions can be
> unified. Follows the section order set by `labs-fixtures.md`. Self-contained.
>
> I am **session (a)** in `labs-fixtures.md` §6.2 — the CI fix that turned into
> the symlink-vs-real-file fan-out. §7 answers their direct question.

## 1. Identity and scope

**Thread:** how the factory materializes generated instruction files — steering,
rules, context, and by extension skills/agents/hooks.

**Question I was given:** should the factory emit steering/rules as copies
instead of symlinks? Explicitly a _decision brief, not an implementation task_.

**Answer:** yes for Kiro steering, **no for Claude**, unknown for Kiro
skills/agents — and the mechanism should be a `strategy` field on a declarative
attrset, not a hard-coded copy.

**Out of scope, deliberately:** I changed no emitter, module, or check.

## 2. Where everything is

Main checkout, branch `refactor/ai-factory-architecture`. Committed alongside the
peer sessions' state docs (see §3):

| Path                                                      | What                                               |
| --------------------------------------------------------- | -------------------------------------------------- |
| `docs/plans/factory-steering-materialization-decision.md` | The decision: evidence, tradeoff table, scope call |
| `docs/plans/session-state/materialization.md`             | This file                                          |
| `docs/plans/steering-symlink-probe/run-probe.sh`          | **Self-tested** reproducer (+ `fixtures/`)         |
| `docs/plans/factory-steering-copy-kickoff.md`             | The brief I was answering (pre-existing)           |

**Edited (labs session's file):** `docs/plans/agent-primitive-labs-impl-plan.md`
— added **P14**, plus an update note under **P13**. Additive only. **Already
landed** — the labs session swept it into `53526699`.

Memory: `project_kiro_steering_symlinks_work.md` + its `MEMORY.md` index line.

## 3. Commits

**Docs only — no code.** My P14 edit landed in the labs session's `53526699`;
everything else is one docs commit on top of `89aee2b1`. Nothing to rebase and
nothing that can conflict with either peer session.

**Hash caution for the merge session:** this branch was rewritten mid-flight. The
materialization commits are `f12aa5f1` / `a7b3e29d` / `88f1fc8b` **on this
branch**; the pre-rebase aliases `3050f894` / `bd67936f` / `cf71e9cd` still
resolve as loose objects but are **not ancestors of HEAD**. `labs-fixtures.md`
already uses the on-branch hashes.

## 4. Status

Decision brief **complete**. Implementation **not started and not authorized** —
the brief required agreement first, and the design is not yet settled (§9).

## 5. Empirical findings — the reusable part

### 5.1 kiro-cli has TWO steering loaders, and they disagree (CONFIRMED)

| Engine           | Reached by                                       | Loader                                                                         | Symlinked **leaf file** |
| ---------------- | ------------------------------------------------ | ------------------------------------------------------------------------------ | ----------------------- |
| **v2 / classic** | `kiro-cli chat --no-interactive` (no pty)        | Rust: `getdents64` → path `statx` **without** `AT_SYMLINK_NOFOLLOW` → `openat` | **loads**               |
| **v3**           | `--tui --v3` **under a pty**; logs `[KiroAgent]` | Node/Bun: `fs.readdir(…,{withFileTypes:true})` + `entry.isFile()`              | **silently dropped**    |

**The repo's wrapper appends `--tui --v3`, so consumers get v3.** The defect is
real and shipping.

Decisive A/B, same dir, same run, then swapped to kill the content confound:

| Run | real file        | symlink → store          | loaded      |
| --- | ---------------- | ------------------------ | ----------- |
| A   | `juliet-real.md` | `india-store-symlink.md` | JULIET only |
| B   | `india-real.md`  | `juliet-symlink.md`      | INDIA only  |

### 5.2 A symlinked DIRECTORY is followed fine under v3 (CONFIRMED)

`.kiro/steering` → `/nix/store/…-steerpkg` loaded every file inside. **Only
leaf-file symlinks are dropped** — which is exactly what `home.file` and devenv
`files.*` emit. This also means "symlink the whole dir" is a real (if
consumer-hostile) alternative to copying.

### 5.3 Dangling symlinks fail silently (CONFIRMED, v2)

`statx` → ENOENT, entry skipped, siblings still load, no error surfaced.

### 5.4 Upstream citations currently in the repo are the wrong product

`kirodotdev/Kiro#2921` and `#8121` (cited at `mkKiro.nix:794`) are **Kiro IDE** —
a different product with a different loader (Electron/VSCode `vscode.FileType`,
not the CLI's bundled `fs.readdir`). Also `#8121` was **auto-closed by a
duplicate-detection bot, not by a fix**, then reopened for maintainer review — do
not read its closed state as resolved.

The correct citation is **`#9787`** — _"[kiro-cli][--v3] Global steering files
that are symlinks are silently ignored"_, OPEN, maintainer-acked 2026-07-02,
quotes the `@kiro/agent` scanner source and confirms v2 loads them fine.

**My probe fills the exact gap upstream leaves.** `#9787` was filed against
kiro-cli **2.10.0 on macOS**, and no changelog entry for 2.11/2.12/2.13 mentions
any symlink or steering-scanner fix. There was **zero upstream evidence for the
pinned 2.13.0 on Linux** — which is what my A/B establishes.

**Upstream independently corroborates the leaf-vs-directory split (§5.2).** The
one report that looked contradictory — Windows CLI `--v3` reading a symlinked
steering **directory** fine — is not a contradiction at all: it is the directory
case, which I also found works. Leaf files are the broken shape in both reports.

**Lead for the skills question:** a comment on the skills issue claims kiro-cli
**2.12.3 fixed symlinked _skills_** — unverified and absent from the changelog,
and `#9787` notes the bundle ships an **unused symlink-aware variant**. Skills and
steering are different code paths. This is a concrete hypothesis for whoever runs
the skills probe: skills may already be fixed while steering is not.

### 5.5 Probe methodology traps — these cost me a WRONG conclusion

1. **`--no-interactive` without a pty silently runs v2** → false negative. I
   initially concluded "symlinks are fine" because of this. v3 needs
   `script -qec "kiro-cli chat --tui --v3 …"`.
2. **Assert the engine, never assume it** — v3 logs `[KiroAgent]`. Make it a hard
   precondition or a future launcher change silently reverts you to v2.
3. **Swap the A/B.** Without the swap, a null is indistinguishable from the model
   simply not mentioning that token.
4. **Don't write "secret passphrase" in fixtures** — triggers a model refusal. Use
   "build token".
5. **Don't grep the binary.** The v3 loader is inside a 555 MB compressed Bun
   bundle (`.kiro-cli-chat-wrapped`); `strings`/`grep` return nothing usable.

## 6. Cross-session collision analysis

### 6.1 File overlap (mechanical)

**Effectively none.** I have zero code changes. Only shared file is
`docs/plans/agent-primitive-labs-impl-plan.md` (labs session's), where my edit is
purely additive (P14 + a note under P13) — resolve by union.

### 6.2 Substantive overlap

**Correction to `labs-fixtures.md` §6.2.** It says session (a) "fixes how bytes
reach the CLI". That is **only half true and the half matters**:

> `f12aa5f1` fixed the **repo's own** generated files. The **factory emitters
> were deliberately NOT converted** — every downstream consumer still gets store
> symlinks today. The defect keeps shipping outward.

So there are **three** independent failure axes, not two:

| Axis                               | Owner | Status                                                |
| ---------------------------------- | ----- | ----------------------------------------------------- |
| **Scope** — is the dir read?       | labs  | Global `~/.kiro/hooks/` is inert under v3 (their 5.3) |
| **Delivery** — do bytes arrive?    | me    | Repo-local FIXED; **factory NOT fixed**               |
| **Wiring** — is the surface typed? | hooks | landed for hooks                                      |

A symlink→copy fix does not make global hooks fire (labs are right). And
conversely: hook _wiring_ being done does not mean hooks _arrive_, for any
consumer using the factory.

**Also:** `88f1fc8b` "correct the steering loads fine as
symlinks claim" is **wrong as written** — it is engine-unqualified and cites the
IDE issues. The comment it replaced was true for v2. Neither names the engine,
which is the entire story. This needs re-correcting whoever lands it.

## 7. What I need / what I offer

**Answering labs §7 "Need from (a): exactly which surfaces moved symlink→copy":**

- **Moved (repo-local only, `f12aa5f1`):** this repo's own generated `CLAUDE.md`,
  `.claude/rules/*`, `.kiro/steering/*` (gitignored) and the git-tracked
  `AGENTS.md`, `.github/copilot-instructions.md`, `.github/instructions/*`. These
  are now real files materialized on shell entry.
- **NOT moved — still store symlinks for every consumer:** all factory emitters
  in `mkKiro.nix` (steering ×4 devenv, ×2 HM; skills; agents) and `mkClaude.nix`.
- **Bearing on labs:** labs `cp -rL` anyway, so lab-materialized trees are
  unaffected — your guess was right.

**Answering labs §10 P13 (workspace hooks as symlink):** I attempted it and
**could not settle it**. SessionStart hooks did not fire even with v3 confirmed
engaged (`[KiroAgent]` present) under `--no-interactive`, so the marker oracle
never armed. It needs a genuinely interactive TUI run. P13 stays open; I added a
note there.

**Need from hooks session:** whether the typed hook surface should adopt one
shared materializer (§9) or keep its own. `mkHooksActivationScript`'s
heredoc-embedding is the reason HM's hooks conversion kept every content
assertion — it is the pattern to generalize.

**Offer to both:** §5 in full, and the self-tested reproducer at
`docs/plans/steering-symlink-probe/run-probe.sh` (banked for the labs as **P14**).

## 8. Recommended merge order

1. **Take my docs as-is** — no code, no conflicts, mergeable at any point.
2. Fold my §5 into the labs' §5 (they are the same kind of artifact) and let the
   labs session own the fixture port (P14).
3. **Then** settle the design (§9) — it needs the hooks session in the room,
   because a shared materializer spans both threads.
4. Only then touch emitters. Re-correct `mkKiro.nix:794` in the same commit.

## 9. Parked / not decided

- **Which design to build — genuinely open.** Three candidates were generated and
  adversarially reviewed; **all three were found fatally flawed**, and three
  judges produced **three different rankings**. A synthesis pass is owed.
- **HARD CONSTRAINTS** any design must satisfy (each came from a real flaw found):
  1. **Never `force = true`** on a steering `home.file` — HM silently deletes the
     target; `contextFilename` defaults to `AGENTS.md`, so a consumer's
     hand-written file vanishes with no backup.
  2. **Never fold emitter branches with `//`** — `.claude/rules/ai-module.md`
     records that collisions must be _errors_. Today's `mkMerge` branches fail
     loudly; a `//` fold silently becomes last-wins. Two candidates regressed this.
  3. **Never blind-prune `~/.kiro/steering/`** — user-owned. Manifest-prune only.
  4. **A user edit to a managed file must not be silently clobbered.**
  5. **HM activation must be `entryAfter ["linkGeneration"]`**, not
     `["writeBoundary"]` (siblings; `lib.toposort` order). **Every HM activation
     block in this repo is currently wrong**, including landed hooks work — and
     `module-eval`'s dag stub discards `after`/`before`, so it cannot catch it.
- **Kiro skills / agents strategy** — gated on probes with working controls. My v3
  skills run was **inconclusive: the real-file control also failed to load.**
- Whether the devenv project-local scope should use the directory-symlink shortcut.

### Repo defects found in passing (not mine to fix)

- HM-side Kiro hooks emitter **never converted** — still `home.file` at
  `mkKiro.nix:600-602`. HM consumers' hooks broken today. → **hooks session**
- `enterShell` runs with the **caller's cwd**, not project root, and fires ≥2× per
  `devenv shell`; `mkKiro.nix:812-819` appears not to anchor to `$DEVENV_ROOT`.
- **The only real-file-vs-symlink gate never runs in CI** — `devenv.nix:318-333`
  `enterTest` is invoked by no workflow. → **CI session**
- `sync_file`'s `cmp` **follows symlinks**, so a destination symlink whose target
  has identical content compares EQUAL and survives — i.e. it breaks exactly the
  factory-migration case. Needs a `[ -L "$2" ]` force-write before any port.
- `instruction-file-single-mechanism.md:169-171` is **factually wrong**: it rejects
  `copyMode = "copy"` partly because "`files.<name>` has no `.source`". It does,
  and `mkKiro.nix:783` already uses it.

## 10. Outstanding HITL

- **Design synthesis needs a decision**, not just a review — see §9. I recommend
  keeping the four `mkMerge` branches intact (constraint 2), adding a derived
  attrset for assertions, and putting `strategy` on it.
- **Nothing of mine is committed.** If these docs should be committed rather than
  left untracked, that is your call — the repo convention is that working docs
  stay untracked.
