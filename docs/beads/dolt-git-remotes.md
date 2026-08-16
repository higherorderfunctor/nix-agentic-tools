# Dolt remotes, git-backed sync, and encrypted-remote options

> **Last verified:** 2026-08-15 against packaged Beads 1.2.2 and Dolt 2.2.3,
> plus the upstream sources listed at the end. The disposable black-box contract
> is `checks/beads-contracts.nix`; #991 carries the timestamped investigation
> record. Companions: `bd-reference.md` (the tool itself) and `ecosystem.md`
> (integrations). Remote-provider and encryption qualification remains #997.

## Problem framing — threat model before tooling

The driving question is not "which encrypted remote tool": work-state for
agentic development — issue titles, dependency structure, design rationale,
`bd remember` insights — gets pushed to a third-party host. The real question is
what confidentiality property that data needs and what is worth giving up to get
it. Beads content is closer to a design-doc corpus than an issue tracker (see
`bd-reference.md`), which raises the stakes.

Sections below describe mechanisms in enough detail that it is tempting to start
picking one. Resolve the threat model first — it changes which mechanisms are
even in scope:

| Adversary                                      | Defeated by                                               |
| ---------------------------------------------- | --------------------------------------------------------- |
| Host employee / insider browsing storage       | Client-side encryption                                    |
| Host breach, ciphertext exfiltrated            | Client-side encryption                                    |
| Legal process against the host                 | Client-side encryption (host has nothing to produce)      |
| An org admin with rights over the git host org | Client-side encryption **and** not using that org's infra |
| Network attacker                               | TLS alone; already solved                                 |
| Loss of the host (availability)                | Replication, not encryption                               |

Also decide whether **metadata** is in scope: push cadence, ciphertext size
deltas, and object counts leak activity patterns even under perfect content
encryption — if work-state timing is sensitive, that constrains the option set
further. And the answer may differ per repository — the remote is per-database
config, so a mixed posture is legitimate.

One categorical exposure holds regardless of the model chosen: beads
database-level config (set via `bd config set`, and capable of holding
external-tracker credentials) **replicates verbatim with `bd dolt push`**.
Secrets must never enter DB config on any remote-backed database — use the
env/INI credential paths only (see `bd-reference.md`).

## Dolt remote types

Four categories:

1. **Filesystem** — `file://<absolute-path>`.
2. **Cloud object stores** — `aws://[dynamo-table:s3-bucket]/db`, `gs://`,
   `oci://`, Azure. Same shape as filesystem; requires cloud credentials.
3. **DoltHub / DoltLab** — hosted and self-hosted products on the same
   primitives, adding PR-style workflow; DoltLab is the self-hostable one.
4. **Git remotes** — added 2026-02, built specifically to ease the beads
   migration off SQLite so existing users could keep their git remotes without
   provisioning new credentials.

### What Dolt writes to a remote

Only two kinds of file:

- **Tablefiles** — immutable, content-addressed; contain all database data for
  the history.
- **Manifest** — the single mutable file; holds version, storage format, lock
  hash, root hash, GC generation, and references to each tablefile with chunk
  counts.

Unreachable tablefiles become garbage and are safe to delete. Dolt periodically
_conjoins_ multiple tablefiles into one larger file.

### The Blobstore interface

Every remote implements the same five methods:

```
Exists(key)                              -> bool
Get(key, byteRange)                      -> reader, size, version
Put(key, size, reader)                   -> version
CheckAndPut(expectedVersion, key, ...)   -> version    // compare-and-swap
Concatenate(key, sources)                -> version    // conjoin
```

`CheckAndPut` is the load-bearing one — it is how the manifest write is made
safe. **Any encryption layer must preserve CheckAndPut's semantics or the
concurrency guarantee is gone.** This is the single most important constraint in
this document.

## Git as a Dolt remote — how it actually works

This is the path that preserves "issue sync piggybacks on the git remote I
already have", and its mechanics determine whether encryption can be layered
underneath it.

### Architecture

- Implemented as `GitBlobstore`, satisfying the same Blobstore interface as
  S3/filesystem remotes, so it slots into the Noms Block Store layer unchanged.
  (Because it lives at that shared layer, git remotes should be available to
  Doltgres as well — an architectural inference, not a documented claim.)
- Uses a **local bare git repo** in Dolt's data directory (one per database, so
  clones on the same host do not clobber each other). No working tree, no
  checkout.
- Operates via git plumbing only: `hash-object`, `read-tree`, `update-index`,
  `write-tree`, `commit-tree`, `update-ref`, `ls-tree`, `cat-file`.
- An earlier local-checkout design (clone + `reset --hard` + add + squash +
  force-push) was **rejected** because it could not land writes atomically under
  concurrency.

The packaged behavior matches this architecture. `bd init --remote <URL>`
persists the exact URL in `sync.remote`; `bd dolt remote list --json` exposes a
`git+`-normalized transport URL. The local workspace contains a separate bare
cache below `embeddeddolt/<database>/.dolt/git-remote-cache/`, including when
the source and ledger URLs are equal. The cache is materialized by the first
sync operation, not necessarily by init alone. The source working tree and its
ordinary branches are untouched. `[measured @Beads 1.2.2 / Dolt 2.2.3]`

One upstream behavior must be actively rejected: if `--remote` is omitted from a
source checkout with `origin`, bd inherits that source URL as its Dolt remote.
Consequently the module must always pass the declared ledger URL and verify both
`sync.remote` and `bd dolt remote list`; it cannot use omission as evidence of
isolation. `[measured @Beads 1.2.2 / Dolt 2.2.3]`

### Branch reflection — no, by design

Dolt data lives on one custom ref: **`refs/dolt/data`**. Custom refs are not
fetched, pulled, or cloned by normal git operations — which is exactly why the
design chose one: Dolt's data never interferes with normal branch/tag flow.

Consequences:

- All Dolt branches and history live inside that one ref's tree. There is **no**
  Dolt-branch → git-branch mapping.
- `git log` on source branches shows nothing about issues. No issue diffs in
  code review.
- Upside: source repo and issue DB share one remote and one credential without
  colliding.

If branch-visible issue state is a requirement, this feature does not provide it
and never will — that would be a different design (a git-native tracker writing
real files on real branches).

### Overwrite protection — two layers of CAS

There is no "force push and hope"; both layers matter.

**Layer 1 — git-level lease.** Writes hash blobs into the local bare repo first
(so retries do not re-read a consumed `io.Reader`), build a commit on top of the
fetched remote head, point a per-instance local ref at it, then:

```
git push --force-with-lease=refs/dolt/data:<expected-oid> origin <localRef>:refs/dolt/data
```

If someone pushed in between, the lease rejects, and the loser refetches,
rebuilds on the new state, and retries with exponential backoff.

**Layer 2 — application-level CAS on the manifest.** `CheckAndPut` compares the
manifest's current object ID to `expectedVersion` **before** building a commit.
On mismatch it errors immediately — no push attempted, no retry. This is
fail-loud, and it is how manifest updates get serialized.

Supporting details:

- Tablefiles are content-addressed and immutable, so `Put` is skip-if-exists —
  no redundant uploads on push.
- Both the remote-tracking ref and the local scratch ref carry **UUIDs**, so
  concurrent GitBlobstore instances sharing one bare repo cannot clobber each
  other's refs.
- The cache merges new tree entries rather than rebuilding — safe because
  tablefiles are immutable; only the manifest is overwritten in cache.

### Chunking

`maxPartSize` bounds git blob size, because hosting providers enforce per-object
limits and Dolt tablefiles get large. Oversized tablefiles are written as a
sub-tree (`tablefile/0001`, `tablefile/0002`, …) and reassembled transparently
on read. The default value, its configurability, and the interaction with host
limits (GitHub warns at 50 MB, hard-fails at 100 MB per object) remain
provider-scale questions for #997. A representative disposable MVP ledger
produced seven objects totaling 74,826 bytes under `refs/dolt/data`; the largest
was a 57,317-byte `.darc` blob, so no chunk boundary was approached. This is a
fixture-scale contract, not hosting-capacity evidence.
`[measured @Beads 1.2.2 / Dolt 2.2.3]`

## Qualified MVP ledger lifecycle

The supported lifecycle is explicit and contains no publication daemon:

1. Create a dedicated local state directory and pre-seed its contained config.
2. From a neutral non-Git cwd, run module-owned `bd init` with the exact ledger
   URL and non-interactive/skip flags documented in `bd-reference.md`.
3. Assert exact `bd where`, `sync.remote`, and `bd dolt remote list` values.
4. Publish only with explicit `bd dolt push`; consume only with explicit
   `bd dolt pull`. Runtime automation, if any, belongs to #993.

A completely unborn bare Git remote is rejected loudly: GitBlobstore requires an
ordinary branch/commit before the first Dolt publication. Once seeded, the first
explicit push creates `refs/dolt/data` plus `refs/heads/__dolt_remote_info__`;
normal source refs remain unchanged. Local writes do not move the remote ref.
`[measured @Beads 1.2.2 / Dolt 2.2.3]`

A second independently initialized state directory bootstraps from that ref and
adopts the ledger identity. In the measured divergence sequence, clones A and B
both wrote, A pushed, B's stale push failed nonzero with a `non-fast-forward`
diagnostic and pull hint, then B pull/push and A pull preserved all rows and
history. This establishes loud stale-writer failure and explicit recovery; it
does not authorize conflict-resolution strategies that discard either side.
`[measured @Beads 1.2.2 / Dolt 2.2.3]`

## Encrypted-remote options

No hosted, zero-knowledge, dependency-graph agent tracker exists as a product.
The structural reason: server-side merge and query require plaintext, so
anything genuinely end-to-end-encrypted reduces to dumb blob storage with all
compute client-side. Beads already has that shape — remote is blobs, compute is
local — which is why encrypting the _remote_ is tractable and finding a
_different product_ is not.

### Crypt-mount filesystem remote

`rclone mount` with a `crypt` remote (object storage), or `gocryptfs` over a
locally-synced directory, then `dolt remote add origin file:///mnt/crypt/<db>`.

- **Confidentiality:** strong; rclone crypt encrypts filenames as well as
  contents.
- **CAS integrity:** depends on the mount's consistency semantics, not on Dolt.
  A FUSE VFS over an object store is weaker than a real filesystem;
  single-writer is fine, concurrent pushes are the risk case. `gocryptfs` over a
  real local FS is the safer variant.
- **Cost:** ~$5/mo class. **Loses:** git — the honest tension for anyone
  choosing beads partly because it can ride a git remote.

### gcrypt git remote

`git-remote-gcrypt` (GPG-encrypted repos over standard git transports; works
with GitHub; packaged in nixpkgs and Debian) as `gcrypt::git@host:repo` under
Dolt's git remote.

- **Confidentiality:** strong, GPG-based; multiple recipient keys via repeated
  `keyid=`.
- **CAS integrity: this is the problem.** gcrypt rewrites the whole encrypted
  pack and force-pushes; there is no stable per-ref OID for `--force-with-lease`
  to lease against. Layering it under GitBlobstore plausibly destroys exactly
  the mechanism described above. **Unverified assumption — the highest-value
  experiment below.**
- Losing the GPG key means losing the remote; key backup is a prerequisite.

### Self-hosted remote

DoltLab, or a plain `dolt sql-server` exposing remotesapi, reachable over
WireGuard/Tailscale.

- **Confidentiality:** not end-to-end encrypted — but the trust boundary moves
  to hardware you control, which may satisfy the actual threat model at far
  lower complexity.
- **CAS integrity:** native, fully preserved. **Cost:** ops burden instead of
  dollars. Worth taking seriously rather than dismissing: if the adversary is a
  third-party host, removing the third-party host is a valid answer.

### Retarget to an e2ee product

EteSync/Etebase (zero-knowledge, task-model, self-hostable) and Anytype
(local-first, e2ee, API) exist, but both are CalDAV/document-shaped: no
dependency graph, no ready-queue, no cell-level merge. Rebuilding beads' core
value on top of them is the actual cost. Recorded for completeness; not
recommended unless the design goal changes.

## Post-MVP experiments

These are deliberately excluded from the MVP and routed to #997:

1. **Does gcrypt break Dolt's git remote?** Throwaway beads DB against
   `gcrypt::`; force a CAS race with two concurrent `bd dolt push` operations
   from different clones. Outcomes: silent overwrite (worst case — rules the
   path out), clean failure (acceptable), working retry (the assumption was
   wrong and the gcrypt path opens up). **Silent data loss is the outcome to
   rule out**; this single test decides whether "git + e2ee" is viable at all.
   If `bd` rejects or rewrites `gcrypt::` URLs, this experiment cannot run
   unpatched; the measured `file://` pass-through must not be generalized to
   custom schemes.
2. **Manifest CAS on a FUSE crypt mount.** Concurrent `CheckAndPut` against an
   rclone-crypt mount; same failure taxonomy; compare gocryptfs-over-local-FS as
   control.
3. **Conjoin and GC on the encrypted substrate.** Conjoin rewrites large
   tablefiles; `bd admin compact` plus Dolt GC deletes them. Confirm neither
   pathologically re-uploads on a crypt mount (the suspected mechanism is rclone
   crypt's dedup/chunking interaction) nor blows the git object limit.
4. **`maxPartSize` default versus host object limits**, with a DB large enough
   to trigger chunking.
5. **Key-management dry run.** Multi-machine key distribution and a documented
   recovery path, tested by restoring from ciphertext on a clean machine —
   **before** the DB carries anything valuable.

## Known failure modes to design against

- **Silent CAS bypass.** The whole point of the two-layer CAS is that Dolt fails
  loudly on concurrent manifest writes. An encryption layer that turns that into
  silent last-write-wins is worse than no encryption layer, because the failure
  is invisible until work-state is already lost.
- **Key loss = total loss.** No recovery path exists for either GPG or rclone
  crypt. Backup is a prerequisite, not a follow-up.
- **Assuming git-remote means git-visible.** It does not. Anyone expecting to
  see issues in `git log` or code review must have that expectation corrected up
  front.
- **Encrypting the wrong thing.** If the sensitive artifact turns out to be the
  code repo rather than the work-state DB, this entire line of work is
  misaddressed. The threat-model step catches this.

## Sources

- Beads: `github.com/gastownhall/beads`
- Dolt git remotes deep-dive: DoltHub blog, 2026-02-19, "Supporting Git remotes
  as Dolt remotes"
- Dolt remote types: `docs.dolthub.com/sql-reference/version-control/remotes`
- Dolt 2.0: DoltHub blog, 2026-05-11; Doltgres 1.0: DoltHub blog, 2026-06-26 and
  2026-07-30
- git-remote-gcrypt: `spwhitton.name/tech/code/git-remote-gcrypt/`
- EteSync/Etebase: `etesync.com`
