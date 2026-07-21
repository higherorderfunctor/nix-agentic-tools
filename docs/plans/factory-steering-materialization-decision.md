# Decision: how the factory materializes generated instruction files

Answers `docs/plans/factory-steering-copy-kickoff.md`. Written 2026-07-21 on
`refactor/ai-factory-architecture`. **Recommendation + evidence. No emitter
changes made.**

---

## 1. The premise: CONFIRMED — but only for v3, and not for the recorded reason

`kiro-cli` 2.13.0 ships **two independent steering loaders** that disagree.

| Engine           | Reached by                                       | Loader                                                                                               | Symlinked leaf file  |
| ---------------- | ------------------------------------------------ | ---------------------------------------------------------------------------------------------------- | -------------------- |
| **v2 / classic** | `kiro-cli chat --no-interactive` (no pty)        | Rust: `getdents64` → path-based `statx` **without** `AT_SYMLINK_NOFOLLOW` → `openat`. Follows.       | **loads**            |
| **v3**           | `--tui --v3` **under a pty**; logs `[KiroAgent]` | Node/Bun (`.kiro-cli-chat-wrapped`, 555 MB): `fs.readdir(…,{withFileTypes:true})` + `entry.isFile()` | **silently dropped** |

**The repo's own wrapper appends `--tui --v3`** (`kiro-cli-wrapped/bin/kiro-cli`),
so every consumer gets v3. The defect is real and shipping.

### The decisive experiment

Same directory, same run, then swapped to kill the content confound:

| Run | real file        | symlink → store          | model reported |
| --- | ---------------- | ------------------------ | -------------- |
| A   | `juliet-real.md` | `india-store-symlink.md` | JULIET only    |
| B   | `india-real.md`  | `juliet-symlink.md`      | INDIA only     |

The result tracks symlink-ness, not name or content.

### The nuance that shapes the fix

**A symlinked _directory_ is followed fine under v3.** `.kiro/steering` →
`/nix/store/…-steerpkg` loaded both files inside it. Only **leaf-file** symlinks
inside a real directory are dropped — and leaf-file symlinks are precisely what
`home.file` and devenv `files.*` produce.

Also verified: a **dangling** symlink is `statx`-ENOENT'd and **silently
skipped**, siblings still load. No error surfaces. (v2; v3 untested.)

### Corrections this forces

1. **`mkKiro.nix:794` (commit `88f1fc8b`) cites the wrong issues.**
   `kirodotdev/Kiro#2921` and `#8121` are **Kiro IDE**, a different product with a
   different loader (Electron/VSCode `vscode.FileType`). `#8121` was moreover
   **auto-closed by a duplicate bot, not by a fix.** The correct citation is
   **`kirodotdev/Kiro#9787`** — _"[kiro-cli][--v3] Global steering files that are
   symlinks are silently ignored"_, `cli`/`steering`/`bug`, OPEN,
   maintainer-acknowledged 2026-07-02, quoting the bundled scanner source and
   confirming v2 loads them fine.

   Note the probe is not redundant with upstream: `#9787` was filed against
   **2.10.0 on macOS**, and no 2.11/2.12/2.13 changelog entry mentions a symlink
   or scanner fix — there was **no upstream evidence for the pinned 2.13.0 on
   Linux**. Upstream also independently corroborates the leaf-vs-directory split:
   the lone "worked fine" report concerns a symlinked **directory**, matching §1's
   nuance rather than contradicting it.

2. **The comment `88f1fc8b` replaced was half right.** "Steering and agents load
   fine as symlinks" was **true for v2** and false for v3. Both the old and new
   comments are wrong because neither names the engine. The engine is the whole story.
3. **`f12aa5f1` still stands.** It was independently justified — two writers
   producing divergent content, and git-tracked outputs that cannot be mode-120000
   symlinks. Only its supporting symlink sentence needs the engine qualifier.

---

## 2. The tradeoff table, filled in with what is actually true here

| Axis              | `files.*` / `home.file` (today)                                                                                                                                                                                                                 | imperative copy                                                                                                                                 |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **Testability**   | attrset, asserted directly                                                                                                                                                                                                                      | **recoverable** — see §3. HM's hooks conversion kept content assertions verbatim; devenv's lost them. It is the _embedding_, not the mechanism. |
| **Lifecycle**     | **Weaker than assumed.** HM `cleanOldGen` deletes a target only if `readlink` matches `<store>/*-home-manager-files/*`. A real file is **skipped with a warning**. devenv prunes only entries still recorded as store symlinks in `files.json`. | untracked; needs its own manifest                                                                                                               |
| **Staleness**     | symlink always current                                                                                                                                                                                                                          | copy is point-in-time; needs re-run on every entry                                                                                              |
| **User edits**    | impossible                                                                                                                                                                                                                                      | possible; must be a deliberate clobber-or-preserve decision                                                                                     |
| **Kiro reads it** | **NO for leaf files under v3** (§1)                                                                                                                                                                                                             | yes                                                                                                                                             |
| **Failure mode**  | wrong content impossible; **dangling symlink is silently skipped**                                                                                                                                                                              | devenv task failure **does not block shell entry** — degrades to a swallowed warning, which is worse than "leaves old file"                     |
| **Git-tracked**   | **impossible** — commits as mode 120000 holding an absolute `/nix/store` path                                                                                                                                                                   | works                                                                                                                                           |

**The orphan row inverts the brief's expectation.** The "HM removes managed
files" advantage is real but _narrow_, and it **evaporates the instant you
convert** — HM refuses to delete real files. It also never protected against the
case that matters. So "declarative keeps the lifecycle guarantee" is true only
while the mode stays `symlink`; **every real-file answer needs its own prune
design.** Blind pruning of a consumer's `~/.kiro/steering/` is unsafe (user files
live there); this repo's `sync_dir` is safe only because it prunes a 100%-generated
gitignored dir. The safe shape is what devenv itself does: **persist a manifest and
delete only previously-ours-now-gone entries.**

---

## 3. Is there a shape that keeps the assertions? **Yes — and it already exists in-repo**

The brief's §3 hypothesis is correct, and the hooks precedent already proves it —
**twice, once per backend, with zero assertions deleted**:

- **HM (`af53cf63`)**: 7 tests rewritten, 3 added, 0 deleted. Each rewrite is a
  one-line accessor swap; `lib.hasInfix` payload assertions carried over verbatim.
  It works because `lib/ai/hm-helpers.nix:mkHooksActivationScript` **inlines each
  file's content as a shell heredoc**, with a comment saying exactly why: _"The
  content rides an inline heredoc … so module-eval can read it."_
- **devenv (`38b7088f`)**: 2 tests rewritten, content assertions **lost** — because
  `enterShell` interpolates a `pkgs.writeText` store path, so the bytes are not in
  the script.

**Conclusion: the embedding strategy, not declarative-vs-imperative, decides
whether the test surface survives.** Scale: ~21 tests / ~64 conjuncts touch Kiro
steering. A conversion that keeps a declarative attrset as SSOT preserves ~54 of
them as literal copy-paste, and the ~10 that cannot port (whole-attrset scans,
key-absence negatives, byte-equality parity) are recovered by asserting on the
attrset instead of on the backend output.

---

## 4. Recommendation: one mechanism, strategy as data

Do **not** hard-code "copy" into the emitters. Make materialization a **property
of a declarative attrset**, so one shared materializer serves every surface and
every backend, and `module-eval` asserts on the attrset regardless of which branch
it takes.

```nix
# SSOT — declared once in the shared options block, reachable from BOTH backends
# as evaluated.config.ai.<cli>.<surface>Files with zero test-harness change.
ai.kiro.steeringFiles."named-rule.md" = {
  text     = "…rendered by the kiro transformer…";
  strategy = "copy";      # "copy" | "symlink"
};
```

- **HM**: `strategy = "symlink"` → `home.file`; `"copy"` → a derived activation
  script, heredoc-embedded, ordered `entryAfter [ "linkGeneration" ]`, manifest-pruned.
- **devenv**: `"symlink"` → `files.*`; `"copy"` → a task with
  `before = [ "devenv:enterShell" ]`, reusing `sync_file`.
- **Shared** `lib/ai/materialize.nix` renders the copy script for both backends, so
  the DRY rule holds and skills/agents/hooks can adopt it later.

### This is what answers the GitHub / committed-files case

Git-tracked generated files (`AGENTS.md`, `.github/copilot-instructions.md`,
`.github/instructions/*`) **cannot be symlinks** — a store symlink commits as mode
120000 holding an absolute `/nix/store` path, which is broken in every clone and on
CI. Under this design that is **not a special case bolted on**: it is one value of
`strategy`, chosen for the same reason as every other surface. The store path is
only ever the _build input_; the committed artifact is always plain bytes.

### Defaults, chosen per surface from evidence

| Surface                             | strategy                | why                                                           |
| ----------------------------------- | ----------------------- | ------------------------------------------------------------- |
| Kiro steering / rules / context     | **copy**                | v3 drops leaf symlinks (§1)                                   |
| Kiro skills / agents                | **copy, pending probe** | same emitted shape; **not yet proven** — see §5               |
| Claude rules / skills / `CLAUDE.md` | **symlink**             | documented symlink-safe **and** live-verified on this machine |
| Copilot git-tracked outputs         | **copy**                | git cannot hold a store symlink                               |

### Rejected: symlink the whole steering directory

Tempting — v3 follows it, it is zero-copy, and it keeps HM's lifecycle. Rejected
because it takes **exclusive ownership of a user-owned directory**: a consumer
could no longer put their own file in `~/.kiro/steering/`. It also has a nasty HM
migration (real dir → symlink trips `checkLinkTargets`' clobber guard). Worth
reconsidering **only** for the project-local devenv scope, as a follow-up.

---

## 5. Explicit scope call

| Surface           | Call               | Basis                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ----------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kiro steering** | **CONVERT**        | v3 defect confirmed by controlled A/B                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **Kiro skills**   | **PROBE FIRST**    | v3 run was **inconclusive — the real-file control also failed to load**, so nothing is attributable to symlinks. High suspicion (Layout B emits the broken shape), but do not convert on speculation. **Concrete hypothesis to test:** a comment on the upstream skills issue claims **2.12.3 already fixed symlinked skills** (unverified, absent from the changelog), and `#9787` notes the bundle ships an **unused symlink-aware variant** — skills and steering are different code paths, so skills may already be fine while steering is not. |
| **Kiro agents**   | **PROBE FIRST**    | untested under v3; same emitted shape                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **Claude Code**   | **DO NOT CONVERT** | `.claude/rules/`, `.claude/skills/` and `CLAUDE.md` are each explicitly documented symlink-safe **and** are store symlinks on this machine that demonstrably loaded. `.claude/agents/` has neither doc nor evidence — leave alone, do not assume by analogy. Claude's symlink handling is provably **per-surface**: `.claude/commands/` drops symlinked `.md` via `Dirent.isFile()` while the skill loader uses `isSymbolicLink()` correctly.                                                                                                       |

---

## 6. Defects found along the way (independent of this decision)

1. **HM activation ordering is wrong repo-wide.** `entryAfter [ "writeBoundary" ]`
   does **not** guarantee running after linking — `linkGeneration` is a
   `writeBoundary` sibling and sibling order comes from `lib.toposort`, i.e.
   config-dependent. The correct entry is `entryAfter [ "linkGeneration" ]`.
   **Every existing HM activation block in this repo uses the wrong one**, including
   the landed hooks work. Worse, `module-eval`'s dag stub **discards the
   `after`/`before` lists**, so it structurally cannot catch this.
2. **`sync_file`'s `cmp` follows symlinks.** A destination symlink whose target has
   identical content compares EQUAL and the symlink **survives**. This never fired
   repo-locally (content changed too), but a factory port emits the same bytes the
   symlink already targets — i.e. it breaks _exactly_ the migration case. Needs a
   `[ -L "$2" ]` force-write before any port.
3. **The HM-side Kiro hooks emitter was never converted** — still `home.file` at
   `mkKiro.nix:600-602`. HM consumers' hooks are broken today, independently.
4. **`enterShell` runs with the caller's cwd**, not the project root, and fires at
   least twice per `devenv shell`. `mkKiro.nix:812-819`'s shipped hooks emitter
   appears not to anchor to `$DEVENV_ROOT`.
5. **The only real-file-vs-symlink gate in the repo never runs in CI** —
   `devenv.nix:318-333` `enterTest` is not invoked by any workflow.
6. **`instruction-file-single-mechanism.md:169-171` is factually wrong**: it rejects
   `copyMode = "copy"` partly because "`files.<name>` has no `.source`". It does —
   and `mkKiro.nix:783` already uses it.

---

## 7. Open questions

- Kiro **skills / agents / hooks** under v3 — all need probes with working controls.
- Whether v3 also drops symlinked **global** `~/.kiro/steering/*` (v2 read them fine).
- Whether upstream fixes #9787, which would make the Kiro `strategy` default revisable.

Fixture/regression follow-up is banked as **P14** in
`docs/plans/agent-primitive-labs-impl-plan.md`.
