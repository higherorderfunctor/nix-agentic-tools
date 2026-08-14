# Beads ecosystem — dedup, indexing, and session-linking prior art

> **Last verified:** 2026-08-14, from the upstream community-tools and
> related-projects docs, plus the emBEADings README (the other projects are
> described from upstream's docs, not their own READMEs). Companions:
> `bd-reference.md`, `dolt-git-remotes.md`. Decisions land in
> `docs/plans/beads-package-and-options.md`.

## The verdict that frames everything

**Retrieval over a beads backlog is solved prior art; write-path triggering is
not.** Several projects below cover semantic/lexical retrieval, but nobody fires
retrieval on `bd create` — the unsolved part is a create-time gate
(check-before-file), and the known field report is that agents do not
proactively use `bd`: instruction-file guidance fades over long sessions, and
hooks help but are not magic. Sequencing rule carried into the plan: measure the
agent check-before-file rate first — if it is ~zero, the best search surface is
moot and the gate is the fix.

## Dedup and indexing

- **emBEADings** (`DyrtyJax/embeadings`, v0.4.3, MIT, Python ≥3.11, PyPI) — the
  integration exists. Read-only coordination CLI for beads + Linear:
  - Reads via allowlisted `bd --readonly ... --json`; **zero tracker writes** by
    contract.
  - Local embeddings, pinned `minishlab/potion-base-8M` (a static-embedding
    model; first semantic command downloads it from Hugging Face; issue text
    never leaves the machine). Whole-record and field-level embeddings.
  - Candidate union = typed graph relationships + semantic retrieval + observed
    worktree code-surface (branch↔bead association via full bead ID or `bead-N`
    suffix; `--worktree-map` for explicit mapping).
  - Commands: `triage` (opinionated front door, ≤20 semantic candidates — a
    reviewer-capacity budget by explicit decision, not corpus coverage),
    `neighbors`, `collisions` (no model loaded), `sweep`, `batch`, `doctor`.
    Schema-versioned JSON plus audit receipts.
  - Evidence: 3/3 known exact-file collisions recovered across 4 live worktrees
    in one repo; 17/20 top-packet pairs "contextually useful" on an 8,143-issue
    corpus converted from the Ruff issue tracker (precision-on-shortlist,
    explicitly not recall).
  - Caveats: single-digit stars, single maintainer, technical preview; the
    agent-CLI plugins (Codex, Claude Code) are local-preview only — no
    marketplace, no write authority; the static model is the quality ceiling —
    the first swap candidate if paraphrase quality is the point.
- **`bd duplicates`** — native exact-dedup floor (content hash), covered in
  `bd-reference.md`. Do not rebuild it.
- **Dolt FULLTEXT** — the middle option between exact hash and semantic:
  MySQL-style `FULLTEXT` via a `bd sql` migration, no new process. Beads
  declares no FULLTEXT index itself, and the option carries a known hazard —
  FULLTEXT tokenization can match issue-ID-like strings (see `bd-reference.md`).
- **perles** (`zjrosen/perles`, Go) — TUI plus a custom BQL query language; a
  richer lexical/structured surface, not semantic. Relevant only if the felt gap
  is expressiveness.

## Adjacent tooling worth knowing

- **beads-sdk** (`HerbCaudill/beads-sdk`, TypeScript, zero runtime deps) — typed
  `BeadsClient` covering CRUD/filter/search/labels/deps/comments/epics/sync. The
  build-on target for any custom indexer.
- **Thread** (`jklenk/thread`) — read-only forensics over local Dolt history
  (fidelity scores, rework cost, session compliance, HTML report). Confirms the
  direct-SQL/Dolt-history mining path is viable.
- **scry** (`prmichaelsen/scry`) — marker-indexed recall graph (`@scry.entry`
  inline markers, reachable by meaning/tag/seeded question). Upstream's own
  related-projects doc draws the line: beads = _what to do next_, scry = _what
  was decided and why_. Relevant to memory pipelines, not backlog dedup.
- **claude-handoff** (`REMvisual/claude-handoff`) — uses bead IDs as chain tags
  for multi-session continuity: auto-detects active beads, updates bead notes on
  close, adds a pre-compaction safety hook. Prior art for a session-linking
  carrier.
- **beads-compound** (`roberto-mello/beads-compound-plugin`) — hooks that
  auto-capture from `bd comments add` at session end and inject at session start
  keyed on open beads. A live external instance of hook-mediated memory over the
  same substrate; a corroboration point, not an adoption target.

## The correlation rule for session linking

Carried from adjacent session-indexing research: a session↔bead/commit link
counts **only** on an explicit identifier in indexed text (`bead:<id>`,
`commit:<sha>`), never on temporal or workspace coincidence. The join key is the
explicit reference. Whatever carrier a linking design picks (metadata bag, notes
convention, or comments), the carrier text must emit `bead:<id>`-style tokens
into session-visible text for reverse lookup — `claude-handoff` precedent uses
notes; note that bd metadata is filter-only until value read-back is verified
(see `bd-reference.md`).
