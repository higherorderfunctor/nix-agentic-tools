# Probe: does devenv 2.3.2 still serve a stale eval cache on a bare `${src}` store copy?

Worktree:
`/home/caubut/Documents/projects/nix-agentic-tools-worktrees/devenv-storecopy`
Branch: `probe/devenv-storecopy` (off `origin/main` @ `8e4ed690`) Date:
2026-09-22 devenv: `devenv 2.3.2+87edd16 (x86_64-linux)`

## Answer

**The claim in the `lib/traceSource.nix` header is FALSE on devenv
2.3.2+87edd16.**

devenv tracks a bare path store copy as a **recursive, content-hashed directory
input**. A content-only edit to a file inside such a tree changes that input's
hash, busts the eval cache, and the materialized output updates. This holds for
all three shapes in play:

1. `ai.skills.<name> = ./dir;` — a bare path, the real call shape.
2. `"${./dir}"` — a plain directory store copy with no `readDir`/`readFile`
   anywhere in the expression.
3. `builtins.path { path = ./dir; filter = ...; }` — the filtered shape used by
   `packages/stacked-workflows/packages/stacked-workflows-content/package.nix`.

Both controls passed. 4 content-only trials on the bare `ai.skills` arm, 2 on
the `tracedPath` positive control, 3 on the isolated store-copy arms, 6
no-change cache-hit controls. Every trial agreed.

## The mechanism

`.devenv/nix-eval-cache.db` has a `file_input` table with a `recursive` column:

```
CREATE TABLE "file_input"
(
  id           INTEGER NOT NULL PRIMARY KEY,
  path         BLOB NOT NULL UNIQUE,
  is_directory BOOLEAN NOT NULL,
  content_hash CHAR(64) NOT NULL,
  modified_at  INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
, recursive BOOLEAN NOT NULL DEFAULT 0);
```

The column arrived in migration `20260603000000  add-recursive-to-file-input`.
`recursive = 1` rows carry a content hash covering the whole subtree; a
`readDir` on a directory registers `recursive = 0` (listing only). Both modes
coexist in one run, which is what makes the distinction observable rather than
assumed:

```
probe-bare                      dir=1 rec=1   <- bare store copy: CONTENT-hashed subtree
probe-bare/SKILL.md             dir=0 rec=1
probe-bare/references           dir=1 rec=0   <- readDir from the ai.skills walker: LISTING only
probe-bare/references/note.md   dir=0 rec=1
```

So the header's distinction between "listing tracked" and "contents tracked" is
still a real distinction in devenv — it is just no longer the distinction
between a store copy and a `readFile`. A store copy is now on the content side
of it.

## Setup

Two scratch skills, registered in `devenv.nix` under `ai.skills`, differing
**only** in the `tracedPath` wrapper:

```nix
# PROBE (scratch, not for merge): arm A — BARE path, no tracedPath.
probe-bare = ./dev/skills/probe-bare;
# PROBE (scratch, not for merge): arm B — positive control.
probe-traced = traceSource.tracedPath ./dev/skills/probe-traced;
```

Each arm holds `SKILL.md` (marker `MARKER:`) and `references/note.md` (marker
`NOTEMARK:`), so a content edit can be applied to a nested non-`SKILL.md` file
as well as to `SKILL.md`.

"Re-enter the shell" means **`devenv shell true`** throughout. Not
`direnv reload` (re-runs `use devenv`, whose cache sees the same inputs — it
does not fix the symptom, and testing it would test direnv rather than devenv).
Not `devenv tasks run` (runs the task DAG but is not the shell-entry path that
materializes `files.*`). `devenv shell true` runs the full entry DAG including
`devenv:files`, which is what writes the projections.

### Observables

- **Source**: marker text in `dev/skills/<arm>/…`.
- **Materialized output**: marker text in `.claude/skills/<arm>/…`,
  `.github/skills/…`, `.kiro/skills/…`, `.agents/skills/…`, plus the store path
  each symlink resolves to.
- **Cache state**: `cached_eval.input_hash` for `attr_name='shell'`, and the
  `file_input` rows for the probe paths.
- **Wall time**: a cache hit is ~0.9 s, a re-evaluation is ~15–21 s. This is the
  sharpest single discriminator and it needs no database access.

### Two materialization shapes, both observed

Reading `lib/ai/hm-helpers.nix` before running anything mattered, because the
devenv backend does not hand the skill directory to devenv whole:

- `mkDevenvSkillEntries` walks the skill dir with `builtins.readDir` recursively
  and emits one `files."<path>".source = <file>` per leaf. Claude, Copilot and
  Kiro projections are therefore **per-file** symlinks into the store.
- `mkSkillDirectoryEntries` (`.agents`, for Codex) sets `source = <the dir>`, so
  `.agents/skills/<name>` is a symlink to a **whole-directory** store copy.

The `.agents` arm is the literal `${src}` directory store copy the header
describes, and it is observed in every trial below alongside the per-file arms.

## Trials

### Controls

| Control                         | Expectation                    | Result                                                              |
| ------------------------------- | ------------------------------ | ------------------------------------------------------------------- |
| Cache hit on no change          | ~0.9 s, `input_hash` unchanged | PASS (6 runs: 0.873 s, 0.901 s, 0.919 s, 0.930 s, 0.941 s, 0.959 s) |
| Positive control (`tracedPath`) | edit reaches output            | PASS (2 trials)                                                     |
| Negative control (add a file)   | edit reaches output            | PASS (1 trial)                                                      |
| Detector sees staleness         | prints STALE when output lags  | PASS                                                                |
| mtime-only `touch`              | cache still hits               | PASS (content-addressed, not mtime-addressed)                       |

The detector check is the one that makes the rest trustworthy: after editing the
bare arm's `SKILL.md` and **not** re-entering the shell, the comparison reports

```
(no shell entry) probe-bare: src=[MARKER: BARE-M4] claude=[MARKER: BARE-M3] **STALE** | agents=[MARKER: BARE-M3] **STALE**
```

so a lagging output is something the harness prints, not something it would
silently pass over.

### Phase 1 — the real `ai.skills` call shape

| #   | Change (content only)             | Elapsed | `shell.input_hash`              | Output  |
| --- | --------------------------------- | ------- | ------------------------------- | ------- |
| 1   | bare `SKILL.md` M1→M2             | 16.5 s  | changed                         | updated |
| 2   | bare `SKILL.md` M2→M3             | 16.9 s  | `a31463b727fd` → `afbbd9fc4d67` | updated |
| 3   | bare `references/note.md` N1→N2   | 18.3 s  | `afbbd9fc4d67` → `71b51d750b00` | updated |
| 4   | bare `SKILL.md` M3→M4             | 21.4 s  | `b5dfd2bcb083` → `47cf39dec2a5` | updated |
| 5   | traced `SKILL.md` T1→T2 (control) | 17.6 s  | `71b51d750b00` → `b8bdf6eef2b6` | updated |
| 6   | traced `references/note.md` N1→N2 | 18.2 s  | `b8bdf6eef2b6` → `b5dfd2bcb083` | updated |

Trial 3 matters on its own: `references/note.md` is not `SKILL.md`, so no
frontmatter-rewriting readFile can explain it. Nothing in the expression reads
that file — `mkDevenvSkillEntries` only sets `.source`, a symlink-strategy
entry, and `lib/ai/materialize.nix` calls `builtins.readFile` only for
`strategy = "copy"` entries. The materialized result is a symlink, so the copy
path is not taken.

Both the per-file `.claude` symlink and the whole-directory `.agents` symlink
moved to new store paths on every one of these:

```
# trial 4, bare arm
.claude SKILL.md -> /nix/store/fh831vxpi36d37cdva5rw0f9dkfwmgx4-SKILL.md
.agents dir      -> /nix/store/rs7cv138yh45hnypyv2f1dx7ryapr8lj-probe-bare
```

### Phase 2 — isolate the literal claim

Phase 1 cannot separate "the store copy is tracked" from "the `readDir` walk
around it is tracked", because `mkDevenvSkillEntries` runs `readDir` on the same
tree. So: a directory referenced **only** by string interpolation, with nothing
reading inside it.

```nix
env.PROBE_STORECOPY = "${./dev/probe-dircopy}";
```

| #   | Change                                | Elapsed | `shell.input_hash` | `PROBE_STORECOPY`         |
| --- | ------------------------------------- | ------- | ------------------ | ------------------------- |
| A   | baseline                              | 16.0 s  | → `79e4c1403468`   | `wk0n8r17…-probe-dircopy` |
| B   | none                                  | 0.94 s  | unchanged          | unchanged                 |
| C   | `nested/deep.txt` ND1→ND2             | 17.1 s  | → `41e8b1123d16`   | `g8crcnzp…` (new)         |
| D   | `payload.txt` D1→D2                   | 15.2 s  | → `d0a0da8f9fce`   | `1rg6255f…` (new)         |
| E   | none                                  | 0.93 s  | unchanged          | unchanged                 |
| F   | `touch payload.txt` (bytes identical) | 0.92 s  | unchanged          | unchanged                 |

`file_input` carries exactly one row for this tree — `probe-dircopy dir=1 rec=1`
— whose `content_hash` moved on C and D and did not move on F. This is the
header's exact scenario, and it busts.

### Phase 3 — the filtered `builtins.path` shape

`stacked-workflows-content` uses `builtins.path { path = ...; filter = ...; }`,
a different Nix code path, carrying the same justification comment. Tested the
same way via `env.PROBE_FILTERED`:

| #   | Change                  | Elapsed | `shell.input_hash` | `PROBE_FILTERED`  |
| --- | ----------------------- | ------- | ------------------ | ----------------- |
| A   | baseline                | 15.2 s  | → `d256bdaf56e1`   | `dcdjbj3b…`       |
| B   | none                    | 0.92 s  | unchanged          | unchanged         |
| C   | `nested/deep.txt` F1→F2 | 15.9 s  | → `1af855de2cab`   | `l1z2gdv4…` (new) |

The filter worked as written (`ignored.tmp` absent from the store copy), so the
filtered path is genuinely exercised, and it is tracked the same way:
`probe-filtered dir=1 rec=1`.

## Corroboration: `.devenv/input-paths.txt`

direnv's watch list contains the bare arm's files, with no `tracedPath` in
sight:

```
55:…/dev/skills/probe-bare/SKILL.md
56:…/dev/skills/probe-bare/references/note.md
57:…/dev/skills/probe-traced/SKILL.md
58:…/dev/skills/probe-traced/references/note.md
```

Treated as corroboration only. The behavioural test above is the evidence.

## Contamination control

Between any two observations in a trial, the only mutation was the single
`sed -i` named in that row. No git operations, no lockfile updates, no edits
elsewhere. `devenv.nix` was edited only at the three phase boundaries (register
the probe skills; add `PROBE_STORECOPY`; add `PROBE_FILTERED`), never between an
edit and its observation. Each phase re-established its own baseline and its own
no-change cache-hit control after the `devenv.nix` edit.

## Course corrections and dead ends

- **First probe shape was under-determined.** The initial scratch skill held
  only `SKILL.md`. Its appearance in `input-paths.txt` was consistent with two
  different stories: devenv tracking the store copy, or the `ai` module
  `readFile`-ing `SKILL.md` to rewrite frontmatter (`prefixSkill` does exactly
  that for the `dev-stack-*` skills, and `lib/ai/materialize.nix` has a
  `builtins.readFile entry.source` path). Adding `references/note.md` and
  reading `lib/ai/hm-helpers.nix` separated them.
- **"The output updated" was nearly reported before the cache was shown to be
  live.** Phase 1 trial 1 showed the edit propagating, which is equally
  consistent with devenv never caching anything in a fresh worktree. The 0.9 s
  vs 16.5 s no-change control is what rules that out, and it should have been
  established first.
- **Log lines are useless here.** `devenv shell true` prints the same task list
  on a cache hit as on a re-evaluation — the 0.9 s run still ran `devenv:files`,
  `generate:instructions:materialize` and the rest. Only the Nix evaluation is
  skipped. Wall time and `input_hash` are the signals; the log is not.

## What this does NOT settle

- **Whether the claim was true when recorded on 2026-07-21.** The
  `add-recursive-to-file-input` migration is versioned `20260603000000`, which
  is _before_ that date. That is a devenv authoring date, not necessarily the
  date it reached the pinned CLI, and this probe cannot tell which devenv was
  installed in July. The claim may have been correct then and overtaken since,
  or it may have been wrong when written. Not determinable from here — and not
  necessary to determine, since the header's job is to describe devenv now.
- **Whether every other devenv version behaves this way.** Measured on
  2.3.2+87edd16 only.

## State of the worktree

Left as run, for reproducibility. `devenv.nix` carries three scratch edits
(marked `PROBE`), and `dev/skills/probe-bare`, `dev/skills/probe-traced`,
`dev/probe-dircopy`, `dev/probe-filtered` are untracked scratch trees. Nothing
here is meant to merge. `lib/traceSource.nix` was not modified.

Raw logs, per-trial transcripts and the observation scripts are in the session
scratchpad:
`/tmp/claude-1000/-home-caubut-Documents-projects-nix-agentic-tools/61c741b3-3ce2-4bb7-84f1-2497941fc030/scratchpad/`

---

# Refutation pass — independent re-measurement (2026-09-22, second agent)

Brief: attack the result above. Re-ran the experiment from scratch rather than
re-reading the notes. Same worktree, same devenv (`2.3.2+87edd16`), HEAD unmoved
at `5e55beaa` throughout (the header above says the branch is off `8e4ed690`;
that commit is an ancestor, not the branch point — immaterial).

## Verdict

**The eval-cache half of the answer survives. The conclusion drawn from it does
not.**

- The claim _"devenv invalidates its eval cache only on files that were READ"_
  is **FALSE** on 2.3.2+87edd16. Independently replicated three times, plus a
  control the first pass did not run. Upheld.
- The claim _"...and direnv reloads only on files that were READ"_ — the other
  half of the same sentence in the header — is **TRUE**, and the first pass did
  not test it. A bare `${dir}` store copy contributes **nothing** to
  `.devenv/input-paths.txt`, which is the entire set of files direnv watches.
- So "`traceSource.tracedPath` changes nothing about that outcome" is too broad.
  It changes nothing about the **eval cache**. It is the only thing that puts a
  pure store copy's files into the **direnv watch list**.

## What I attacked, and what happened

### 1. The missing control: does an _unrelated_ edit bust the cache?

The first pass had a no-change control (cache hits) but never showed that a
change **outside** the probe tree leaves the cache alone. Without that, every
"it busted" observation is equally consistent with "any edit anywhere in the
worktree busts", which would void the attribution.

```bash
printf 'UNRELATED: U1\n' > dev/refute-unrelated.txt   # create
devenv shell printenv ...                              # 0.853s, input_hash unchanged
printf 'UNRELATED: U2 …\n' > dev/refute-unrelated.txt  # edit
devenv shell printenv ...                              # 0.846s, input_hash unchanged
```

Control **passes**. Unrelated edits are inert. Attribution holds.

### 2. Was the edit really content-only? Made it stricter.

The first pass used `sed -i`, which replaces the inode. I used a truncating
`printf >` redirect with an **identical-length** payload, so inode, size and
directory listing are all unchanged:

```
before: 27952044 -rw-rw-r-- 16 bytes  22:43:08.760714434  payload.txt
after:  27952044 -rw-rw-r-- 16 bytes  22:49:26.688909668  payload.txt   # same inode, same size
```

`devenv shell` → **15.87s**, `shell.input_hash 1af855de2cab → 85d92498c27f`,
`file_input` row for `dev/probe-dircopy` moved `92a228572e8a → 4a494224533b`,
`PROBE_STORECOPY` moved to a new store path carrying the new bytes. **Busts.**

### 3. New test: content edit with the **mtime restored**

Not run in the first pass. It complements their `touch` test (same bytes, new
mtime → hit) and closes the stat-short-circuit hypothesis from the other side:

```bash
ref=$(stat -c '%y' dev/probe-dircopy/payload.txt)
printf 'DIRCOPYMARK: D4\n' > dev/probe-dircopy/payload.txt
touch -d "$ref" dev/probe-dircopy/payload.txt     # identical inode, size AND mtime
```

→ **15.59s**, `input_hash 85d92498c27f → ab821facb3f0`, `file_input`
`4a494224533b → f612fde78d91`. Tracking is genuinely **content**-addressed, not
stat-addressed. This strengthens the first pass's result rather than breaking
it.

### 4. Self-contamination from `devenv:files`

Checked: no. Every no-change re-entry across this pass hit the cache at
0.85–0.87s with a byte-identical `input_hash`, so nothing the entry DAG writes
is itself a tracked eval input. `git diff --stat devenv.lock flake.lock` is
empty; the only tracked file modified all session is `devenv.nix`.

### 5. The corroborating evidence disagreed with the behaviour — and that is the finding

The first pass cited `.devenv/input-paths.txt` as corroboration. It is not, for
two reasons.

**(a) The file it read was stale.** `input-paths.txt` is written only by
`devenv direnv-export`, never by `devenv shell`. Its mtime was `22:41`, which
predates the Phase 2 `PROBE_STORECOPY` edit. So the lines it quoted could not
have contained the Phase 2 tree either way.

**(b) Regenerated, it still omits the store copy.** I ran the exact command
direnv runs:

```bash
_DEVENV_CALLER=direnv devenv direnv-export
```

A full 16.1s re-evaluation — and `input-paths.txt` was **not rewritten at all**
(mtime still `22:41`, md5 unchanged). To prove the writer was not simply broken,
I forced a change that must alter the list (added
`dev/skills/probe-bare/references/extra2.md`, a new per-file `source` entry).
The list **was** rewritten and the new line appeared. The writer works. The
store copy is simply not in it.

**The decisive shape — both arms in one list, one run.** Added a second pure
store copy, identical to the first except for the wrapper:

```nix
env.PROBE_STORECOPY  = "${./dev/probe-dircopy}";                                            # bare
env.PROBE_TRACEDCOPY = "${(import ./lib/traceSource.nix {inherit lib;}).tracedPath ./dev/probe-tracedcopy}";
```

One `direnv-export`, one resulting `input-paths.txt`:

```
50:…/dev/probe-tracedcopy/nested/deep.txt      <- traced
51:…/dev/probe-tracedcopy/payload.txt          <- traced
(no line for dev/probe-dircopy/*)              <- bare: ABSENT
```

while the eval cache tracks **both** directories recursively:

```
dev/probe-dircopy                     dir=1 rec=1
dev/probe-tracedcopy                  dir=1 rec=1
dev/probe-tracedcopy/nested           dir=1 rec=0
dev/probe-tracedcopy/nested/deep.txt  dir=0 rec=0
dev/probe-tracedcopy/payload.txt      dir=0 rec=0
```

`input-paths.txt` contains **zero directory entries** (checked: every one of its
297 lines is a regular file). It is populated from files _read_ during
evaluation, exactly as the header says — the recursive directory input that
busts the eval cache never reaches it.

`devenv direnvrc`'s `use_devenv` watches only `.envrc`, the user direnvrcs,
`devenv.{nix,lock,yaml}`, `devenv.local.*`, and the `input-paths.txt` entries.
Nothing else. **Inference, not measurement** (I did not `direnv allow` this
worktree): a content edit inside a pure store copy changes no watched file, so
direnv has nothing to notice and will not re-run `use devenv`.

### 6. Replication count

| Trial | Change                                            | Elapsed | Cache |
| ----- | ------------------------------------------------- | ------- | ----- |
| R0    | none (baseline)                                   | 0.854s  | hit   |
| R1a   | create unrelated file outside every probe tree    | 0.853s  | hit   |
| R1b   | edit that unrelated file                          | 0.846s  | hit   |
| R2    | `probe-dircopy/payload.txt`, same inode+size      | 15.87s  | bust  |
| R3    | same, **mtime restored**                          | 15.59s  | bust  |
| R4    | `probe-bare/references/note.md` (real call shape) | 17.53s  | bust  |
| R5    | none, after the phase-4 `devenv.nix` edit         | 0.874s  | hit   |
| R6    | `probe-dircopy/payload.txt` again                 | 14.87s  | bust  |

Plus three `devenv direnv-export` runs (one hit, two full re-evals). 11
observations this pass, all agreeing, none dissenting. R4 confirmed the
materialized output end-to-end: `.claude/skills/probe-bare/references/note.md`
and the whole-directory `.agents/skills/probe-bare` both moved to new store
paths carrying the new bytes.

## What this changes about the consequences

The header sentence is **half wrong, not wrong**. Rewriting it as "devenv tracks
store copies by content, traceSource is unnecessary" would replace one false
statement with another.

Accurate as of 2.3.2+87edd16:

- devenv's **eval cache** content-hashes a bare path store copy recursively. An
  edit busts it and the next shell entry re-materializes. The header's "until
  some UNRELATED tracked input happens to change" is wrong **for anyone who
  re-enters the shell**.
- devenv's **direnv watch list** still only carries files that evaluation read.
  For a pure store copy nothing is watched, so under the `.envrc` workflow there
  is no automatic reload and the stale-output symptom the header describes can
  persist — the header's practical prediction, reached by the half of its stated
  mechanism that is still correct.

On whether `traceSource` is dead weight — **it is at today's call sites, but not
for the reason the first pass gave.** `mkDevenvSkillEntries` walks each skill
dir with `readDir` and emits one per-file `source` entry per leaf, so every file
of a **bare** `ai.skills` dir already lands in `input-paths.txt`. Measured: the
`probe-bare` arm's four files are all listed, with no `tracedPath` anywhere. So
the four `tracedPath` calls in `devenv.nix` are redundant for both the eval
cache and the watch list. A future caller handing a directory somewhere with no
surrounding per-file reads would _not_ be covered — that is what `tracedPath`
still buys, and it is what the header should say if it is kept.

Not asserting what should be done; that is the operator's call. The two claims
above are what the measurements support.

## Worktree delta from this pass

`devenv.nix` gains one scratch line (`env.PROBE_TRACEDCOPY`, marked
`REFUTE PROBE`) on top of the three from the first pass. New untracked scratch:
`dev/probe-tracedcopy/`, `dev/refute-unrelated.txt`,
`dev/skills/probe-bare/references/extra2.md`. `lib/traceSource.nix` still
untouched. Scripts and raw logs: `…/scratchpad/refute/` (`obs.sh`, `log.*.txt`,
`direnv-export*.log`).

---

# direnv pass — behavioural measurement (2026-09-22, third agent)

Brief: the first two passes settled the **eval cache** and then _inferred_ the
direnv half without running direnv. This pass runs direnv. Same worktree, same
devenv (`2.3.2+87edd16`), direnv `2.37.1`.

## Verdict

The answer splits by call shape, and collapsing the two is what would get the
module deleted wrongly.

- **Bare `ai.skills.<name> = ./dir` — the real call shape: direnv DOES notice a
  content-only edit and reloads.** Measured, 3/3. `tracedPath` on the same
  directory behaves identically (1/1). At today's call sites `tracedPath` is
  redundant for direnv as well as for the eval cache.
- **Bare `"${./dir}"` — a pure store copy with no surrounding read: direnv does
  NOT notice.** Measured, 3/3 no-reload. The same directory wrapped in
  `tracedPath` reloads, 3/3. There `tracedPath` is the only thing that works.

So `traceSource` is dead weight at every present caller, and live for a shape
nobody currently writes. That is a decision about future callers, not a
measurement question.

## direnv IS wired here, and needs no `direnv allow`

`direnv status` from the worktree, with the session's inherited `DIRENV_*`
scrubbed:

```
whitelist.prefix [/home/caubut/Documents/projects /home/caubut/Documents/work]
Found RC path …/nix-agentic-tools-worktrees/devenv-storecopy/.envrc
Found RC allowed 0
```

The worktree sits under a whitelist prefix, so it is trusted implicitly. No
allow-file was created by this pass (`~/.local/share/direnv/allow/` unchanged, 8
entries before and after) and none had to be revoked.

**Trap that voided a reading in this pass too:** a bare `direnv status` run with
cwd in the worktree reports `Loaded RC path …/nix-agentic-tools/.envrc` — the
PRIMARY CHECKOUT. That is the agent session's own inherited environment, not the
worktree's. Every direnv invocation here scrubs
`DIRENV_DIFF/DIR/FILE/WATCHES/ACTIVE` first. Without that scrub the measurement
describes the wrong directory entirely.

## Driver

Not `devenv shell`. Not `devenv direnv-export` called by hand either — that
reports what devenv would emit, not what direnv decides. The driver is one tick
of **direnv's actual shell hook**:

```bash
( unset DIRENV_DIFF DIRENV_DIR DIRENV_FILE DIRENV_WATCHES DIRENV_ACTIVE
  . "$STATE"          # the DIRENV_* state left by the previous tick
  cd "$WT"
  direnv export bash )
```

This is literally what a prompt in that directory runs. Empty stdout = direnv
considers the environment current (NORELOAD). Non-empty stdout plus
`direnv: loading …/.envrc` on stderr = direnv re-ran `use devenv`, which runs
`_DEVENV_CALLER=direnv devenv direnv-export` (RELOAD). The state file carries
`DIRENV_WATCHES` forward so each tick starts from the previous load, exactly as
a long-lived shell would. Wall time separates the two unambiguously: 0.01 s
versus 15–18 s.

## The watch list, read from direnv rather than from a file

`.devenv/input-paths.txt` is the trap the second pass caught. This pass does not
rely on it: direnv's live watch set is decoded from its own `DIRENV_WATCHES`
(`direnv status` prints it as `Loaded watch:` lines with the state restored).

At the cold load, 593 watches. Of the probe trees:

```
dev/probe-tracedcopy/nested/deep.txt        <- traced pure store copy: WATCHED
dev/probe-tracedcopy/payload.txt            <- traced pure store copy: WATCHED
dev/skills/probe-bare/SKILL.md              <- BARE ai.skills: WATCHED
dev/skills/probe-bare/references/extra.md
dev/skills/probe-bare/references/extra2.md
dev/skills/probe-bare/references/note.md
dev/skills/probe-traced/SKILL.md
dev/skills/probe-traced/references/note.md
(no line for dev/probe-dircopy/*)           <- BARE pure store copy: ABSENT
```

**Zero of the 593 watches is a directory** (checked with `test -d` over every
entry). That single fact predicts both the pure-store-copy result and the
add-a-file result below.

`input-paths.txt` mtime was recorded on all 22 ticks. It advanced **once**, at
F1 — the only tick whose file _set_ changed (300 → 301 lines, the new line being
`dev/skills/probe-bare/references/added1.md`). It did not advance on the other
five full re-evaluations. So it is rewritten only when its content changes, and
an unmoved mtime is not proof that nothing ran. Nothing in this pass's argument
rests on it.

## Trials (22 ticks)

| #   | Change                                                 | Tick     | Elapsed |
| --- | ------------------------------------------------------ | -------- | ------- |
| L0  | cold load                                              | RELOAD   | 1.26s   |
| C1  | none                                                   | NORELOAD | 0.01s   |
| T1  | `probe-dircopy/payload.txt` D6→D7 (BARE store copy)    | NORELOAD | 0.01s   |
| C2  | none                                                   | NORELOAD | 0.01s   |
| T2  | `probe-tracedcopy/payload.txt` T1→T2 (TRACED)          | RELOAD   | 14.98s  |
| C3  | none                                                   | NORELOAD | 0.01s   |
| T3  | `probe-bare/references/note.md` (BARE `ai.skills`)     | RELOAD   | 17.13s  |
| C4  | none                                                   | NORELOAD | 0.01s   |
| T4  | `dev/refute-unrelated.txt` (outside every probe tree)  | NORELOAD | 0.01s   |
| T5  | ADD `probe-dircopy/added1.txt`                         | NORELOAD | 0.01s   |
| T6  | ADD `probe-bare/references/added1.md`                  | NORELOAD | 0.01s   |
| F1  | `touch devenv.nix` (forced reload)                     | RELOAD   | 17.04s  |
| C5  | none                                                   | NORELOAD | 0.01s   |
| T1b | `probe-dircopy/payload.txt` D7→D8                      | NORELOAD | 0.01s   |
| T1c | `probe-dircopy/nested/deep.txt` ND2→ND3                | NORELOAD | 0.01s   |
| C6  | none                                                   | NORELOAD | 0.01s   |
| T2b | `probe-tracedcopy/nested/deep.txt` TN1→TN2             | RELOAD   | 16.90s  |
| C7  | none                                                   | NORELOAD | 0.01s   |
| T3b | `probe-bare/references/extra.md`                       | RELOAD   | 18.22s  |
| T7  | TRACED arm, content edit with **mtime restored**       | NORELOAD | 0.01s   |
| T8  | TRACED arm, **touch only**, bytes unchanged            | RELOAD   | 15.54s  |
| T9  | `probe-traced/references/note.md` (TRACED `ai.skills`) | RELOAD   | 17.22s  |

Two independent trials of each arm (T1/T1b/T1c, T2/T2b, T3/T3b). They agree.

## Controls

| Control                                          | Expected                  | Result                   |
| ------------------------------------------------ | ------------------------- | ------------------------ |
| No-change                                        | NORELOAD                  | PASS — 7/7, 0.01s each   |
| Positive (`tracedPath` pure store copy)          | reloads                   | PASS — 3/3 (T2, T2b, T8) |
| Unrelated edit outside every probe tree          | NORELOAD                  | PASS — T4                |
| Negative (ADD a file is noticed in the bare arm) | reloads                   | **FAIL — see below**     |
| Missed edits are real, not no-ops                | appear at the next reload | PASS — see below         |

### The negative control failed, and it is a finding rather than a broken harness

An added file is noticed by **neither** arm: not in the pure store copy (T5),
not in the bare `ai.skills` tree (T6). The mechanism already on the table
explains it — direnv watches individual files that evaluation read, a file that
did not exist cannot have been read, and no directory is ever watched (0 of
593). There is no listing-level watch for an add to trip.

This does not threaten the other results, because the property the control
exists to establish — that the bare `ai.skills` arm is _capable_ of being
noticed — is established directly by T3 and T3b instead.

Note it corrects the module header from the other direction: the header says
"`readDir` alone tracks only the directory LISTING, so adding/removing a file is
caught but editing one is not." For the eval cache the listing half is right
(pass 1 measured `recursive = 0` rows for `readDir`ed directories). For **direnv
it is backwards**: editing is caught and adding is not.

### Proving the missed changes were real

A no-reload only means something if a real change was pending. Two observations
establish it, and they are the reason "direnv does not notice" is not just
"nothing happened":

1. **T2's reload swept up T1's edit.** T2 edited only the _traced_ tree, yet
   `PROBE_STORECOPY` — the _bare_ tree's store path — moved
   `xi254sml… → 2s5zi956…` at that reload, carrying T1's bytes. Same shape at
   T2b for T1b/T1c. The bare edit was live the whole time; direnv simply had no
   watch that could see it.
2. **F1 flushed the adds.** After T5 and T6 both went unnoticed, touching
   `devenv.nix` (a watched file) forced a reload, and the resulting store copy
   contained the added file and the current payload:

   ```
   $ ls /nix/store/fpbmldj7f7i8a2313pk6z5l5ny1qrypn-probe-dircopy
   added1.txt   nested   payload.txt
   $ cat …/payload.txt
   DIRCOPYMARK: D7
   ```

   That is the header's predicted failure mode observed end to end: the
   materialized environment lagging the real source until an unrelated tracked
   input happened to change.

## direnv triggers on mtime, the eval cache on content

T7 and T8 are a matched pair on a **watched** file, and they separate the two
mechanisms cleanly:

- **T7** — content rewritten, `touch -d` restored the original mtime (same
  inode, same size, same mtime). direnv: **NORELOAD**. It never looked at the
  bytes.
- **T8** — `touch` only, bytes identical. direnv: **RELOAD**, and the 15.54 s
  full re-evaluation happened because devenv's cache had T7's real content
  change queued behind it, so `PROBE_TRACEDCOPY` moved.

Consequence worth carrying: `tracedPath` buys a watch, not a content check. A
tool that rewrites a file while preserving its mtime defeats direnv in both
arms. The eval cache catches that case (pass 2, R3); direnv does not.

## What this does NOT settle

- Measured on direnv 2.37.1 + devenv 2.3.2+87edd16 only.
- The `use_devenv` watch set is read from `devenv direnvrc`'s source and from
  direnv's live `DIRENV_WATCHES`. Both agree, but a future devenv that emits
  directory entries into `input-paths.txt` would change the add-a-file result.
- Nothing here measures `packages/stacked-workflows/.../package.nix`, which
  calls `traceSource.fingerprint` (not `tracedPath`) inside a derivation. That
  site's stated justification is partly about Nix's own rebuild behaviour, which
  is a different mechanism from either half measured in this file.

## Worktree delta from this pass

Marker edits only, left as run: `probe-dircopy/payload.txt` → `D8`,
`probe-dircopy/nested/deep.txt` → `ND3`, `probe-tracedcopy/payload.txt` → `T3`,
`probe-tracedcopy/nested/deep.txt` → `TN2`, `probe-bare/references/note.md` →
`BARE-N4`, one line appended to `probe-bare/references/extra.md`,
`probe-traced/references/note.md` → `TRACED-N3`, `dev/refute-unrelated.txt` →
`U3`. New untracked: `dev/probe-dircopy/added1.txt`,
`dev/skills/probe-bare/references/added1.md`. `devenv.nix` was `touch`ed at F1
but not edited. `lib/traceSource.nix` untouched. The primary checkout was never
entered: its `.devenv/input-paths.txt` mtime is unchanged from 2026-09-21.

Harness and raw logs: `…/scratchpad/direnv/` (`harness.sh`, `run1-4.sh`,
`trials.log`, `watches.txt`, `watches2.txt`).

---

# Refutation pass on the direnv measurement (2026-09-22, fourth agent)

Brief: attack the third agent's direnv result. Independent harness, fresh cold
load, separate state file (`…/scratchpad/refute4/`), same worktree, same direnv
2.37.1 / devenv 2.3.2+87edd16.

## Verdict: the measurement UPHOLDS. The conclusion drawn from it does not.

Every behavioural result reproduced, first try, in a harness I wrote from
scratch. What did not survive is the headline sentence — "`traceSource` is dead
weight at every present caller." One present caller is load-bearing for direnv,
and I measured it rather than leaving it open.

## What reproduced

| Arm                                              | Third agent | Mine (2 trials each)           |
| ------------------------------------------------ | ----------- | ------------------------------ |
| Bare `ai.skills.<n> = ./dir` — content edit      | RELOAD      | RELOAD (R5 17.13s, R12 17.64s) |
| Bare `"${./dir}"` pure store copy — content edit | NORELOAD    | NORELOAD (R3, R14, both 0.01s) |
| `tracedPath` on the same pure store copy         | RELOAD      | RELOAD (R7 15.09s, R16 14.95s) |
| No-change control                                | NORELOAD    | NORELOAD 7/7 at 0.01s          |
| Unrelated file outside every probe tree          | NORELOAD    | NORELOAD (R18)                 |
| Content edit with mtime restored (`touch -d`)    | NORELOAD    | NORELOAD (R11)                 |
| Watch list contains zero directories             | 0 of 593    | 0 of 594 (`test -d` over each) |

The missed-change control reproduced too, and on three arms at once: at R5's
reload `PROBE_STORECOPY` and `PROBE_FILTERED` both moved, carrying R3's and R4's
bytes; at R16's reload all three moved. The NORELOADs were real changes direnv
could not see, not absent changes.

R11 is worth separating out: I ran the mtime-held edit on the **bare `ai.skills`
arm**, not on the traced store copy the third agent used. Same answer. So
"direnv triggers on mtime, never on content" is a property of direnv, not of one
arm.

## What I added, and what it changes

### 1. The attribution control the third agent never ran — it passes

Nothing in that pass ruled out the possibility that `dev/skills/probe-bare/*`
was in the watch list because some _other_ consumer walks `dev/skills/`, rather
than because of the bare `ai.skills` entry. Without that control, "the bare arm
is watched" does not establish "`ai.skills` watches it."

Test: create `dev/skills/probe-unref/SKILL.md`, referenced by nothing, then
force a reload (R7).

```
ATTRIBUTION: probe-unref lines in input-paths = 0
```

Zero. Nothing else walks `dev/skills/`. The bare arm's five watch entries are
attributable to `ai.skills` → `mkDevenvSkillEntries`'s `readDir` walk, which
emits one `files."….source" = <leaf file>` per leaf. The third agent's headline
survives a control it had not earned. (Directory removed afterwards.)

### 2. `builtins.path { filter = …; }` was in the harness and never ticked

`env.PROBE_FILTERED` — the shape `stacked-workflows-content` actually uses — sat
in `devenv.nix` unmeasured through the whole direnv pass. It behaves like the
bare store copy: **not watched.**

- `grep -c probe-filtered .devenv/input-paths.txt` → `0`
- R4 and R15, content-only edits: NORELOAD, 0.01s
- the store path moved anyway at the next unrelated reload (`l1z2gdv4…` →
  `nvak3qkb…` at R5, → `kbh6dq09…` at R16)

That last line matters on its own: `builtins.path` **is** content-addressed, so
Nix's own rebuild behaviour never needed help. The gap is only in what direnv
watches.

### 3. The one "not settled" call site is settled, and it refutes the headline

`packages/stacked-workflows/packages/stacked-workflows-content/package.nix`
calls `traceSource.fingerprint` on `../../references` and `../../skills`. The
third agent left it open. It is live in this devenv, so it is measurable.

Attribution first, by elimination:

- `skillsSrc` is `builtins.path {filter}` — contributes 0 watches (measured
  above).
- `${../../references}` is a bare directory store copy — contributes 0
  (measured, the `probe-dircopy` arm).
- `readDir ../../skills` yields names only; **0 of 594 watches is a directory**.
- The skills reach `ai.skills` as **store-path strings** into the built
  derivation, and `input-paths.txt` contains **0 entries under `/nix/store`**,
  so the `mkDevenvSkillEntries` walk cannot be the source either.
- `grep -rn references --include=*.nix packages/stacked-workflows/` outside that
  file finds only comments and a `checks/` file devenv never evaluates.

Yet all 6 `references/*.md` and all 6 `skills/stack-*/SKILL.md` are in
`input-paths.txt`. `fingerprint` is the only thing that put them there.

Behavioural confirmation — a content-only edit to a tracked file, reverted
byte-exactly afterwards (`md5` verified, `git status` clean):

```
R19 edit REAL fingerprint site (references/philosophy.md)  RELOAD  24.99s
R20 restore that file                                      RELOAD  14.30s
restored md5 e219244daac8d1767777e4c194bd099a == original
```

_*So: editing a stack-* skill body or a shared reference is invisible to direnv
without `traceSource.fingerprint`._* Delete the module and that stops working.
The header's stated reason for that call site ("served from a stale eval cache")
is still wrong — pass 1 settled that the eval cache catches it — but the call
site is load-bearing for a reason the comment does not give.

### 4. Removal IS noticed. The add/edit framing was half the story

The third agent wrote that for direnv "editing is caught and adding is not." The
third case was never run.

```
R9  REMOVE dev/skills/probe-bare/references/extra2.md   RELOAD   16.77s  (ipt 301 → 300)
R10 RESTORE the same file                               NORELOAD  0.01s
```

A removal moves a watched path's stat, so it reloads. The re-add does not —
after R9 the path is no longer in `input-paths.txt`, so nothing watches it. It
entered the environment only at R12, an unrelated reload, `ipt` back to 301.
Correct statement: **edit caught, remove caught, add not caught** — an add is
caught only if evaluation had already probed that exact path.

That last clause is not hypothetical. 33 of the 301 input paths do not exist on
disk: `devenv.local.nix`, `.env`, `~/.config/nixpkgs/overlays.nix`,
`packages/agnix/packages/ai/mcpServers/package.nix` (a `pathExists` probe), and
the dangling `dev/skills/repo-review/references/*.md` symlinks. Creating any of
those would reload.

### 5. "Nothing in this pass's argument rests on `input-paths.txt`" is false

Read `devenv direnvrc`: `use_devenv` builds its **entire** watch set with
`watch_file` over the lines of `$DEVENV_DOTFILE/input-paths.txt` — once before
the export (the previous set, so a failed eval can still recover) and once
after. `DIRENV_WATCHES` is a downstream copy of that file, not an independent
witness. Their result is unaffected, because they read direnv's live state at
the right moment, but the independence claim is not true and the next agent
should not rely on it.

The mtime discipline itself held up: `ipt` mtime advanced on exactly the two of
my ticks whose file _set_ changed (R9, R12), and on neither of the six other
full re-evaluations. An unmoved mtime is not evidence that nothing ran.

### 6. Minor: the allow-dir count does not reproduce

They recorded `~/.local/share/direnv/allow/` as 8 entries before and after. I
count 6, unchanged across this pass. The load-bearing part is right and I
re-verified it: the worktree is trusted by
`whitelist.prefix [/home/caubut/Documents/projects …]`, `Found RC allowed 0`,
and no allow file was created by either pass.

The inherited-`DIRENV_*` trap also re-verified exactly as described — unscrubbed
`direnv status` in the worktree reports
`Loaded RC path …/nix-agentic-tools/.envrc`, the primary checkout. Every call in
this pass scrubbed first.

## What would break my own result

- A devenv release that emits directory entries into `input-paths.txt` flips the
  add-a-file result and makes the whole watch-list analysis stale. Re-run on any
  devenv bump.
- I did not remove `fingerprint` from `stacked-workflows-content` and
  re-measure; the attribution there is by elimination plus the behavioural
  reload, not by ablation. An ablation would be conclusive. I judged editing a
  tracked `package.nix` out of scope for a probe branch.
- Home-manager's `mkSkillEntries` path is untouched by all four passes. Nothing
  here says anything about HM consumers.

## Decision this leaves

Not "delete the module." Two distinct facts:

- For `ai.skills.<name> = ./dir` in **devenv**, `tracedPath` is redundant — for
  the eval cache (passes 1–2) and for direnv (pass 3, reproduced here). The five
  `tracedPath` wrappers in `devenv.nix` could go today with no behaviour change.
- For `stacked-workflows-content`, `fingerprint` is the only reason direnv sees
  a skill-body or reference edit. Removing it is a live regression, measured.

So the module stays, its header needs correcting on three counts (the eval cache
does catch content edits; for direnv it is _add_ that is missed, not _edit_; and
`builtins.path` is content-addressed so Nix's rebuild never needed the
fingerprint), and the `tracedPath` call sites are the ones that are dead.

## Worktree delta from this pass

Marker edits only, left as run: `probe-dircopy/payload.txt` → `R-D9`,
`probe-dircopy/nested/deep.txt` → `R-ND4`, `probe-tracedcopy/payload.txt` →
`R-T4`, `probe-tracedcopy/nested/deep.txt` → `R-TN3`,
`probe-filtered/nested/deep.txt` → `R-F3`, `probe-bare/references/note.md` →
`BARE-R5`, two lines appended to `probe-bare/references/extra.md`,
`dev/refute-unrelated.txt` → `R18`. `probe-bare/references/extra2.md` was
removed and restored byte-identical. `dev/skills/probe-unref/` was created and
deleted. **No tracked file changed**:
`packages/stacked-workflows/references/philosophy.md` was edited and restored,
md5 verified, `git status` clean for that tree. `lib/traceSource.nix` untouched.
`devenv.nix` untouched by this pass (not even `touch`ed). The primary checkout
was never entered. No `__pycache__` created.

Harness and raw log: `…/scratchpad/refute4/` (`h.sh`, `trials.log`,
`watches.txt`).

---

# `devenv hook` auto-activation pass — what the post-direnv mechanism watches (2026-09-22, fifth agent)

Brief: the operator is migrating off direnv onto devenv's own auto-activation
(`devenv hook`). Passes 1–4 measured the devenv **eval cache** and **direnv**.
Neither measured the hook. Same worktree, same devenv `2.3.2+87edd16`.

## Verdict

**`devenv hook` watches NOTHING. It has no watch set, no reload path, and no
per-prompt file check at all.** It is an _activation_ mechanism, not a reload
mechanism. The only refresh point is **shell re-entry**, and the thing that
decides what re-entry picks up is devenv's own eval cache — the content-hashed
`recursive = 1` mechanism pass 1 measured.

Consequences for `lib/traceSource.nix`:

- **The pure store copy — `env.X = "${./dir}"` with nothing reading inside — IS
  picked up on re-entry, without `tracedPath`.** Measured 3/3 (R2, R9, R13),
  each time with the store path moving. This is the discriminating test the
  brief named, and it comes out on the "broader than direnv" side.
- The `tracedPath` twin behaves **identically** (R4, R11): same reload, same
  latency band. The wrapper changes nothing under the hook.
- So `traceSource`'s sole remaining justification — putting a file into
  `.devenv/input-paths.txt` so direnv's `watch_file` can see it — **has no
  consumer once direnv is gone.** The hook never reads `input-paths.txt` (devenv
  still writes it, for `use_devenv`'s benefit).

**But the hook is strictly worse than direnv at noticing anything while you sit
in the shell — it notices nothing, not even `devenv.nix`.** See Test A. Deleting
`traceSource` after the migration loses nothing; the migration itself loses live
reload.

## Why: read the hook, then measure it

`devenv hook bash|zsh` defines `_devenv_hook`, registered in `PROMPT_COMMAND`
(bash) / `precmd_functions` (zsh). Its first statement:

```bash
if [[ -n "${DEVENV_ROOT:-}" ]]; then
    ... # cd-out handling only
    return $previous_exit_status
fi
```

**`DEVENV_ROOT` set ⇒ immediate return.** Inside an active devenv shell the hook
does no work whatsoever. Outside one it runs `devenv hook-should-activate` — a
static trust + `devenv.nix`-presence check, **12–13 ms flat across 5 runs,
unchanged by any edit** — and on success spawns
`(cd "$project_dir" && _DEVENV_HOOK_DIR=… _DEVENV_CALLER=hook devenv shell)`.
That spawn is the entire mechanism.

## Detector validity

Two independent signals, and they agreed on all 24 activations:

- **Wall time.** Cache hit 0.89–2.27 s (12 trials); full re-evaluation 15.2–20.8
  s (12 trials). No value in between. The ~1 s floor is the entry DAG
  (`devenv:files`, `git-hooks:install`, `hooks:isolate-config`), which runs on
  every activation including a hit.
- **Store path.** `PROBE_STORECOPY` / `PROBE_TRACEDCOPY` / `PROBE_FILTERED` read
  from inside the spawned shell. A hit shows the previous path; a re-evaluation
  shows a new one. Internal consistency check: P8 removing the file P6 added
  returned `SC` to `50nmirry…`, the exact pre-add hash.

## Contamination control — this pass nearly measured direnv instead

Two traps, both hit before the real measurement:

1. **The session's inherited `DEVENV_*`.** This agent session runs inside the
   primary checkout's direnv-loaded devenv shell, so `DEVENV_ROOT` was already
   set. Unscrubbed, `_devenv_hook` returns at line 1 and the harness measures
   nothing while appearing to work. Every subshell here scrubs `DEVENV_*`,
   `_DEVENV_*` and `DIRENV_*` (`scrub.sh`), verified by
   `env | grep -cE '^(_?DEVENV_|DIRENV_)'` → `0`.
2. **`~/.bashrc` re-arms direnv inside the spawned shell.** The hook spawns an
   interactive bash, which sources `~/.bashrc`, whose line 51 evals
   `direnv hook bash`. First run of Test A showed
   `PROMPT_COMMAND=[_devenv_hook;_direnv_hook]` and `direnv: loading …/.envrc` —
   and the "reload" it produced was direnv's, reproducing passes 3–4 exactly
   (bare arm missed, traced arm caught). Neutralized by exporting
   `DIRENV_CONFIG` to an empty directory, which removes the `whitelist.prefix`
   that trusts this worktree, so `.envrc` is blocked and `direnv export bash`
   returns in 4 ms. **Verified per trial:** every one of the 24 stderr captures
   contains exactly one direnv line and it is `is blocked`. No direnv allow-file
   was created (6 entries before and after). Nothing in direnv's configuration
   was modified.

Home-manager config, read only (`home/caubut/global/default.nix`): `devenv`
integration is zsh-only (`enableBashIntegration = false`), direnv is on for
both. In zsh, direnv's precmd is registered **before** devenv's, so with an
`.envrc` present direnv loads the environment first, `DEVENV_ROOT` gets set, and
the devenv hook never fires. Today the two coexist with direnv winning;
post-migration the hook is alone.

## Test A — prompt ticks INSIDE an active devenv shell

Driver: spawn the shell exactly as the hook does, feed it a script on stdin
(each line is one prompt tick, and `PROMPT_COMMAND` runs the real hook), with
direnv disarmed. Explicit `_devenv_hook` calls timed around each edit.

| Tick  | Edit before it            | dt   | Any env change |
| ----- | ------------------------- | ---- | -------------- |
| B1    | none                      | 1 ms | no             |
| B2/B3 | bare store copy content   | 1 ms | no             |
| B4/B5 | `tracedPath` twin content | 1 ms | no             |
| B6    | unrelated file            | 1 ms | no             |
| B7/B8 | **`devenv.nix` content**  | 1 ms | **no**         |
| B9    | none                      | 1 ms | no             |

The positive control does not fire in-shell, and that is the finding: there is
no in-shell reload to trigger. An operator editing `devenv.nix` under
`devenv hook` sees nothing happen until they leave and come back.

## Test B — re-entry activations (the hook's only refresh point)

One trial = `cd /tmp; _devenv_hook; cd $WT; _devenv_hook` — leave the project,
come back, hook spawns `devenv shell`. Faithful to exiting the shell and
`cd`-ing back in, or opening a new terminal.

| #   | Change before the activation              | dt      | Result     | Store path moved   |
| --- | ----------------------------------------- | ------- | ---------- | ------------------ |
| R1  | none                                      | 1.08 s  | HIT        | –                  |
| R2  | **bare `${./dev/probe-dircopy}` content** | 16.80 s | **RELOAD** | `SC dlqj… → r43f…` |
| R3  | none                                      | 1.00 s  | HIT        | –                  |
| R4  | `tracedPath` twin content                 | 17.54 s | RELOAD     | `TC iq6r… → a9kj…` |
| R5  | none                                      | 1.03 s  | HIT        | –                  |
| R6  | unrelated file outside every probe tree   | 1.04 s  | HIT        | –                  |
| R7  | **`devenv.nix` content (pos. control)**   | 16.34 s | RELOAD     | – (comment only)   |
| R8  | none                                      | 0.89 s  | HIT        | –                  |
| R9  | bare store copy content, trial 2          | 15.22 s | RELOAD     | `SC r43f… → 4hxk…` |
| R10 | none                                      | 1.10 s  | HIT        | –                  |
| R11 | `tracedPath` twin content, trial 2        | 16.30 s | RELOAD     | `TC a9kj… → f23k…` |
| R12 | none                                      | 1.04 s  | HIT        | –                  |
| R13 | bare store copy, **nested** file content  | 16.65 s | RELOAD     | `SC 4hxk… → 7d7s…` |
| R14 | `builtins.path {filter}` content          | 15.89 s | RELOAD     | `FL kbh6… → k0az…` |
| R15 | none                                      | 0.89 s  | HIT        | –                  |

Trial counts: bare store copy 3 (R2, R9, R13) — agree. `tracedPath` twin 2 (R4,
R11) — agree. No-change 7 — agree. Content-only edits throughout; no adds,
removes or renames in this block.

## Test C — what the eval cache keys on, versus what direnv keyed on

| #   | Change                                           | dt      | Result | direnv did (passes 3–4) |
| --- | ------------------------------------------------ | ------- | ------ | ----------------------- |
| P1  | none                                             | 1.14 s  | HIT    | —                       |
| P2  | `touch` only, **bytes identical**                | 0.96 s  | HIT    | **RELOAD** (T8)         |
| P3  | none                                             | 1.15 s  | HIT    | —                       |
| P4  | content edit, **mtime restored** with `touch -d` | 18.03 s | RELOAD | **NORELOAD** (T7, R11)  |
| P5  | none                                             | 0.93 s  | HIT    | —                       |
| P6  | **ADD** a file to the bare tree                  | 16.90 s | RELOAD | **NORELOAD** (T5)       |
| P7  | none                                             | 1.16 s  | HIT    | —                       |
| P8  | **REMOVE** it again                              | 20.84 s | RELOAD | RELOAD (R9)             |
| P9  | none                                             | 2.27 s  | HIT    | —                       |

P2/P4 are the matched pair and they invert direnv exactly: **the hook keys on
content, direnv keyed on mtime.** A tool that rewrites a file preserving its
mtime defeated direnv in both arms (pass 3's carried consequence); it does not
defeat the hook. And P6 closes pass 4's "edit caught, remove caught, add not
caught" asymmetry — under the hook, all three are caught, because the store copy
is hashed as a whole subtree rather than watched file by file.

## Controls summary

| Control                                 | Expected | Result                                                          |
| --------------------------------------- | -------- | --------------------------------------------------------------- |
| No-change                               | HIT      | PASS — 12/12, 0.89–2.27 s, no store path moved                  |
| Positive (`devenv.nix` content edit)    | RELOAD   | PASS — R7, 16.34 s                                              |
| Positive, in-shell (`devenv.nix`)       | RELOAD   | **FAIL by design** — B7/B8, 1 ms: no in-shell mechanism exists  |
| Unrelated file outside every probe tree | HIT      | PASS — R6, 1.04 s                                               |
| Detector distinguishes reload           | —        | PASS — two signals, 24/24 agreement, no intermediate wall times |
| direnv neutralized                      | —        | PASS — 24/24 stderr captures show only `is blocked`             |

## What this does NOT settle

- devenv `2.3.2+87edd16` only. A release that adds an in-shell watcher would
  change Test A; `watchexec`/`inotify` symbols exist in the binary but belong to
  `devenv up`/processes, not to the hook path.
- Measured on the bash hook (`devenv hook bash`), evaluated in a subshell. The
  operator runs the **zsh** hook. The two scripts are the same `posix.sh` body
  with a different registration tail (`PROMPT_COMMAND` vs `precmd_functions`),
  so the logic is identical, but zsh was not executed.
- The `stacked-workflows-content` `fingerprint` call site that pass 4 found
  load-bearing **for direnv** was not re-measured here. Its mechanism is the
  same one this pass measured (the eval cache sees the store copy's content), so
  it should be redundant too — but that is an inference from the shared
  mechanism, not a trial. Ablating `fingerprint` there and re-running Test B is
  what would settle it.
- Nothing here says a devenv-hook-only workflow is _pleasant_. It is a cold
  15–20 s on every re-entry after any content change anywhere in the eval
  closure, and zero feedback while you stay put.

## Worktree delta from this pass

Marker edits only, left as run: `probe-dircopy/payload.txt` →
`DIRCOPYMARK: HK-3`, `probe-dircopy/nested/deep.txt` → `NESTEDMARK: HK-1`,
`probe-tracedcopy/payload.txt` → `TRACEDCOPYMARK: HK-2`,
`probe-filtered/nested/deep.txt` → `FILTERED: HK-1`, `dev/refute-unrelated.txt`
→ `UNRELATED: HK-1`. `probe-dircopy/hookadd.txt` created (P6) and removed (P8).
**`devenv.nix` restored byte-exact** — appended twice as the positive control,
restored from a pre-run snapshot, `md5 935a7e1e37bf0706259c4448bddb4279` before
and after. `lib/traceSource.nix` untouched. `git status --short` identical to
the start. No `__pycache__` created. The primary checkout and the
`tracesource-binary` worktree were never entered. No shell configuration was
modified.

**devenv trust store**, `~/.local/share/devenv/allowed`:

- Before: 1 entry (`…/projects/effect-tui`), 54 B, md5
  `e3afde1155dbb8c31bc8a96dea83cb7a`, mtime 2026-08-24 11:31:28.
- During: `devenv allow` in this worktree added a second entry.
- After: reverted with `devenv revoke` in the same directory. File is
  **byte-identical** to the pre-run snapshot — same md5
  `e3afde1155dbb8c31bc8a96dea83cb7a`, 54 B, one entry (`effect-tui`), `diff`
  clean — and `devenv hook-should-activate` in this worktree is back to
  `rc=2 … is not allowed`. direnv's own allow directory is unchanged at 6
  entries; no direnv state was touched by this pass.

Harness and raw logs: `…/scratchpad/hookprobe/` (`scrub.sh`, `inside-A2.sh`,
`inside-B.sh`, `seqB.sh`, `seqC.sh`, `B.log`, `C.log`, `err-R*.txt`,
`errC-P*.txt`, `bin/direnv` stub).
