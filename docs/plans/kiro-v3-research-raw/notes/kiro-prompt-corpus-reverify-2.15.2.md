# Prompt — re-verify the Kiro corpus against 2.15.2 and stand up drift tracking

Paste everything below the line into a fresh session. It is self-contained.

---

We need to re-verify the tracked Kiro CLI v3 primitive corpus against a new
engine version, and — more importantly — to **standardize how drift between
versions is recorded**, so that this stops being a one-off re-read and becomes a
ledger that accumulates.

## Where things are

- Repo: `/home/caubut/Documents/projects/nix-agentic-tools` (primary checkout, on
  `main`). Work in a NEW worktree off `origin/main`, per `AGENTS.md` — worktrees
  live in the sibling `nix-agentic-tools-worktrees/`. Bootstrap it with **one**
  `devenv shell` before the first commit, and if a second shell entry ever leaves
  a stale `commit-msg.legacy` in the shared hooks dir, remove it after confirming
  it is byte-identical to `commit-msg`.
- The corpus: `fixtures/kiro-primitives/` — `records/*.md` (code-read records),
  `evidence/*.md` (machine-state measurements), `carried-negatives.md` (C-1
  through C-15). **Read `README.md` first, then `carried-negatives.md`.** The
  negatives are the cheapest orientation in the repo: they are the wrong turns
  already paid for, and several are methodology traps you will otherwise repeat.
- There is an unmerged branch `test/kiro-mode-f-harness` (11 commits) carrying a
  mode-F fixture harness. **Do not run its live fixtures** — those are reserved
  for an operator-driven sitting. You may reuse its read-only tooling; see below.

## The situation that triggered this

`kiro-cli` was updated to **2.15.2** (repo commit `e373f2ea`). The corpus is
pinned to **KAS `2.15.1-e20633b4…`**, whose bundle is still on disk. **No 2.15.2
bundle is extracted yet**, so the pinned resolver correctly refuses with
`found 0` rather than silently selecting a neighbour.

Bundles currently on disk (note 2.12.1 disappeared since the last capture — the
set is not append-only, which is itself worth recording):

```
2.12.3  2.13.0  2.13.1  2.14.1  2.14.2  2.15.1
```

**Extracting the 2.15.2 bundle requires running the new CLI once.** That is a
real mutation of machine state and it is the first thing to confirm with me
before doing it. Do not treat it as incidental setup.

Also relevant: repo commit `2706055b` (#609) fixed the kiro-cli launcher wrapper
to inject its global flags (`--tui`, `--v3`) **before** the subcommand instead of
appending them. Appending broke every subcommand with its own parser — `acp` died
with `unexpected argument '--tui'`. The wrapper on PATH is rebuilt and correct.

## What I want, in order

### 1. Design the drift-tracking format FIRST, before verifying anything

This is the part that outlives the immediate task. Today each record carries a
single `Verified against: KAS <id>` stamp, which answers "was this true once" and
cannot answer "what changed, when, and is it still true".

Propose a standard — then let me approve it before you retrofit anything. It must
distinguish these outcomes per record, because collapsing them is what makes a
drift log useless:

| Outcome              | Meaning                                                                        |
| -------------------- | ------------------------------------------------------------------------------ |
| **reproduced**       | the recorded command produces the recorded output byte-for-byte                 |
| **relocated**        | offsets/identifiers moved, but the semantic anchor found it and the claim holds |
| **changed**          | the behaviour itself differs — a real finding, and the most valuable row        |
| **removed**          | the thing is gone; needs positive controls to distinguish from "search broke"   |
| **unverifiable**     | could not be checked this run, and why                                          |

Constraints on the format:

- It must be **greppable and diffable** — this repo has no extractor and no
  automated drift check, deliberately (see README §"Why replayable rather than
  tested"). Do not add one now; the anchors renumber every release and nothing
  consumes the output at build time.
- It must record **which version each outcome was observed at**, so the history
  reads as a series, not a latest-value.
- It must not bloat every record. A per-record history table and a single
  top-level ledger are both plausible; argue for one.
- `records/**` and `evidence/**` are cspell-excluded; authored prose elsewhere is
  not. Keep that in mind for whatever file you add.

### 2. Re-verify, once I have approved the format and the extraction

Work through the corpus and record an outcome per claim. The two standing rules
are not optional and are the reason this corpus is worth anything:

- **Every asserted absence names positive controls** — strings confirmed present
  by the same method. Otherwise "removed" and "my search no longer parses the
  artifact" are indistinguishable, and the second silently reads as the first.
- **Every count names its denominator.** A zero means nothing without proof the
  event family is recorded in those files at all.

Practical notes that will save you time:

- **Every command block must be bash**, not zsh: `shopt` is not a zsh builtin and
  a non-matching glob is a hard error there. This has already produced one wrong
  result in this corpus.
- **The bundle is ~20 MB with one line over 180 KB.** Never `cat` it, never read
  it into a variable, never pipe it whole through a language runtime. Bounded
  windows only: `grep -boF` then `head -c … | tail -c …`.
- **A pattern starting with `--` needs `grep -e`**, or grep parses it as an option
  and exits 2 — and a surrounding pipe or `|| true` turns that into a false zero.
- **`grep -c` counts LINES, not occurrences**, which in this bundle is a different
  measurement. Do not mix the two inside one claim.
- **Never put a literal NUL byte in a source file** — git classifies it binary and
  every diff on it stops being reviewable. This already happened once here.

There is a scriptable, read-only way to interrogate the engine directly:
`fixtures/kiro-primitives/harness/acp-probe.py` on the harness branch drives the
engine's **unadvertised** `_kiro/workflow/*` ACP extension methods over stdio,
under a scratch `HOME`, with the auth request refused. It needs no seeded
session, no feature flag and no model. Useful for confirming that a *behaviour*
survived, not merely that a string did. Note it isolates with `HOME` — never
`KIRO_HOME`, which reaches a different root — and it deliberately leaves
`XDG_DATA_HOME` real, because an empty credential store triggers a browser login
rather than an error.

### 3. Report drift as findings, not as a diff

For anything in the **changed** or **removed** column, treat it the way the
corpus treats a discovery: what was believed, what is now true, how the
difference would have presented to someone trusting the old record, and whether
it invalidates a downstream design decision. Several records feed an unmerged
mode-F harness; if one of them moved, say so explicitly.

If a change deserves a new carried negative, add it in the existing four-field
form and match the file's tone.

### 4. Take it all the way to a merge-ready PR

This is not a hand-back-a-diff task. Carry it through review.

**Where work happens.** Everything code- or corpus-related happens in the
worktree, on the PR branch. **Do not modify the primary checkout at all**, with
exactly one exception: `private/` docs, which are gitignored and machine-local,
and which you should update there as you go.

Derive the worktree directory this way — it is correct from any worktree, and a
bare `../<repo>-worktrees/…` silently resolves one level too deep from a linked
one:

```bash
worktrees="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")-worktrees"
git worktree add -b <type>/<slug> "$worktrees/<slug>" origin/main
cd "$worktrees/<slug>" && devenv shell   # ONCE, before the first commit
```

That bootstrap is load-bearing: `.pre-commit-config.yaml` is a devenv `files.*`
artifact materialized on shell entry, and `git worktree add` runs no devenv, so
until you do it the shared hooks have no config and the commit is rejected.

**Push at the first commit**, not at the end, so the branch is a continuous
off-machine backup. Then open the PR **ready, never draft** — Copilot review does
not run on draft PRs in this repo, so a draft that is actually ready silently
skips review.

**Then run the review loop, up to FIVE rounds.** Fix, push, re-trigger, verify.
Stop early the moment a round comes back clean in **both** buckets; stop at five
regardless and hand me a summary of what was found, what was fixed, and what is
outstanding. The failure mode this cap prevents is not a bad round — it is a good
one repeating until the PR has been force-pushed eight times.

Three things about reading Copilot's review that are easy to get wrong, and each
of which has already cost a round here:

1. **Reading the threads is not reading the review.** Copilot puts findings in two
   places and only one creates a thread. The other is a
   `<details>Comments suppressed due to low confidence (N)</details>` block inside
   the review **body** — no thread, nothing to resolve, invisible to any thread
   query. On the last PR that used this loop, the suppressed bucket produced 7
   findings, all genuine, including a functional bug; the gating bucket produced
   2. On that sample the confidence signal was inverted. Always fetch the body:

   ```bash
   gh api --paginate "repos/OWNER/REPO/pulls/N/reviews" \
     --jq '[.[] | select(.user.login=="copilot-pull-request-reviewer[bot]")]
           | last | .body' | sed -n '/low confidence/,$p'
   ```

   `--paginate` is not tidiness — the endpoint pages at 30 and a PR in a review
   loop reaches that easily. Without it, `last` returns the last review on the
   FIRST page, which is an old one, and a stale review reads exactly like a fresh
   clean one.

2. **Gate on `commit_id`, not on a timestamp.** The only condition meaning "this
   review saw my code" is the review's `commit_id` equalling the PR head. A review
   of an older commit still advances `submitted_at`, so a timestamp baseline reads
   as fresh when it is not.

3. **Distinguish "not run yet" from "ran and found nothing"** — they look
   identical otherwise. Ask for the check run **by name** on the head commit;
   counting checks is only correct until the CI matrix changes:

   ```bash
   gh api --paginate "repos/OWNER/REPO/commits/<head-sha>/check-runs" \
     --jq '.check_runs[] | select(.name=="copilot-pull-request-reviewer") | .status'
   ```

   Absent means it never started, so re-request it; `in_progress` means wait.

**Resolve each gating thread as you fix it** — the ruleset requires every review
thread resolved, so an unresolved one blocks merge. A PAT-authenticated MCP client
cannot resolve threads; use the GraphQL `resolveReviewThread` mutation through
`gh api`. **Suppressed findings have no thread to resolve**, so reply on the PR
itself saying what you did with each one.

The four required checks are `build (x86_64-linux, ubuntu-latest)`,
`build (aarch64-darwin, macos-latest)`, `test`, and `gitleaks`. Zero approving
reviews are required. Merges are squash-only and **I perform them** — get the PR
green and thread-clean, then hand it to me.

## Scope boundaries

- **Do not run the mode-F live fixtures.** Those need an operator sitting.
- **Never commit to `main`**, and do not touch the primary checkout outside
  `private/`.
- Follow the repo's Conventional Commits convention and run `treefmt` on every
  changed file.
- There is a `private/kiro-acp-and-launcher-argv.md` documenting ACP and launcher
  argv behaviour from a separate session. It is **not in scope** to fold in here —
  I will converge that separately — but skim it if you hit an ACP question, so you
  do not re-derive what it already settled.

Start by reading the README and the carried negatives, then come back to me with
the proposed drift-tracking format and a plan. Do not extract the 2.15.2 bundle
until I say so.
