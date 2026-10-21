## Binary Cache Maintenance

> **Last verified:** 2026-10-21 — overlay parity uses the ordinary
> `nixpkgs-stable` input; no patched evaluation source needs retention; every
> credentialed push also filters the CodeQL bundle; `unpublishedChecks` build
> outside Hestia.

When adding or removing flake inputs, check whether the input has a public
Cachix cache. If so, add it to:

- `flake.nix` `nixConfig.extra-substituters` and
  `nixConfig.extra-trusted-public-keys`
- `devenv.nix` `cachix.pull`

Current public consumer cache: `nix-agentic-tools`. Consumers must add it
themselves: Nix ignores a flake's `nixConfig` substituters for users who are not
trusted. README's snippet reads the substituter and key from `flake.nix`
`nixConfig` (`natCache` in `dev/generate.nix`), so change them there only. The
`follows` pattern for nixpkgs is intentional — do not remove it to chase
upstream cache hits unless the input provides pre-built binaries independent of
nixpkgs.

Semble is built on this flake's nixpkgs, alongside its three vendored Python
dependencies. The authenticated package matrix publishes those builds through
the Cachix daemon, so consumers need only the project cache and cache.nixos.org.

Extra Semble grammars already in nixpkgs remain direct consumer-owned
`pkgs.tree-sitter-grammars` inputs. Do not re-export them from this flake:
Cachix's nixpkgs follow already supplies those store paths. A future custom
grammar absent from nixpkgs must be exposed as a flake package so the
authenticated package matrix publishes it. The published Semble build always
includes the runtime-config patches. Consumer grammar, mapping and model
selections rebuild only store JSON and a bin-only launcher. The
`module-semble-extra-grammars-load` flake check parses real AWK and jq samples
with that variant's runtime config and exercises mapped-file discovery and
language selection.

This is separate from `devenv test` closure policy.
`ai.programs.semble.install = !isCI` (dev/ai.nix) keeps the interactive package
out of that cold runtime-test shell while every runtime keeps the Semble rule;
it does not remove or weaken the flake check above.

### CI-only check cache

The Linux `test` job installs `.github/actions/check-cache` before warming IFD
sources and still runs `nix flake check`. The helper pins Hestia's action to
v3.1.0 and supplies `ciHestia`, built from that release with a local manifest
scope patch. `dev/scripts/test-ci-cache.py` requires the action and matrix pins
to match the binary's source SHA and version. Supplying `binary:` skips the
action's release attestation; the source hash and in-repo build pin its bytes.
Its post-build hook retains check outputs and runtime closures in GitHub Actions
cache, independently of public Cachix publication. The signature filter excludes
only `cache.nixos.org-1` and `nix-agentic-tools.cachix.org-1`; retaining
devenv-signed paths is intentional.

`publish-hestia` builds `ciHestia` before the test and check evaluator jobs. Its
credentialed Cachix action publishes the Rust binary and keeps the
`pushFilter: kiro-cli|codeql-bundle-javascript` exclusion. The package shards
exclude `ci-hestia` because that early job owns its build. Jobs obtain the
binary from the project Cachix cache, configured before `check-cache`; the daily
GC job also enables that read-only substituter. On a cold main or
same-repository PR run, the early job pays one Rust build before cache consumers
start. Fork PRs have no publication token, so their test job builds the binary
locally if it is absent from Cachix.

Overlay parity imports the ordinary `nixpkgs-stable` flake source directly.
Unlike devenv's patched nixpkgs output, it requires no evaluation-time source
build or explicit Hestia registration. Nix fetches the locked input normally;
its packages use the existing `cache.nixos.org` substituter. This does not
establish a warm-cache result for evaluation-only sources.

Cold or changed inputs, eviction, and inaccessible GitHub cache scopes still
require upstream substitution or a local build. The default branch continues to
read and write `m3#N`. Other refs read its newest entry plus their own `m3pr#N`
entry and write only `m3pr#N`. GitHub's PR-first lookup can shadow an identical
prefix, so the distinct prefixes make new reads unambiguous. Refs that already
hold PR-scoped `m3#` entries keep loading those as their base until every such
entry is deleted; the orchestrator performs a one-time deletion after merge. The
merged view takes main's path and pack entries where present, keeps PR-only
entries, and merges roots with Hestia's upstream rule. For differing chunk
locations only, family loads check main's pack: live main still wins regardless
of repack counters; if main's pack is absent and own's is live, own wins. Equal
own-index published refreshes preserve those resolved locations over stale
repack counters. Reservation and wait indices count only the own family.

Drains check packs used by existing paths they would skip and chunk locations
they would reuse for newly prepared paths, through Twirp and a one-byte blob
read. Dedup does not scan unrelated manifest packs; family conflicts use the
checks above. Results are memoized within the drain. One lookup miss is
insufficient: absence requires two responses indicating a miss or blob 404,
separated by 100 ms. Other errors propagate after normal URL refresh/retry.
Known-missing locations and their dependent paths are pruned from working and
commit snapshots before merging fresh uploads, so old repack counters cannot
defeat those repairs. This applies to evaluator registration and worker drains
without relying on background verification, which runs after manifest readiness.
A later family load preserves the repaired own location while main remains
stale, and closure export can read those packs. These are checks at the time of
reuse/load, not a guarantee against subsequent eviction or locations introduced
by concurrent writers after the checks.

GC cleanup retains the highest numeric index per ref in each of `m3#` and
`m3pr#`, restricted to Hestia's cache version namespace. Superseded entries are
deleted by cache ID, since key deletion spans refs and namespaces. In both
families, an older entry is deleted only when the next-higher index in the same
family, ref and version namespace has a known creation time older than `min_age`
(one hour by default). An unknown successor creation time or missing identity
keeps the entry. A fresh higher index, including a REST-visible reservation not
yet finalized, keeps its predecessor. Cleanup runs before planning and
repacking, so slow pack work cannot starve metadata reclamation or force
planning to download the entire manifest backlog. It preserves heads and
measures reader grace from the successor's creation; planning and commit reload
their inputs. Dry runs never delete.

Pack handling still runs on the default branch, whose token cannot read
PR-scoped caches: packs only a PR references remain orphans to upstream GC and
are deleted after `min_age`; the next PR run re-uploads only paths it has
locally and supplies to the drain (including expanded local dependencies),
through the healing above. Unrelated missing paths are not reconstructed. That
was already true of PR-scoped `m3#` manifests before this patch. The daemon logs
both loaded keys. Fork PRs explicitly use read-only mode. They can restore
accessible entries or fall back upstream without needing cache write access. No
live warm-cache result or speedup is established by local validation.
`hestia-gc.yml` runs daily on the default branch with the helper in read-only
mode and `actions: write` for garbage collection, limiting stale roots and packs
within GitHub's shared cache quota. It has no explicit job timeout, matching
upstream's GC workflow: repacking and the one-second REST mutation spacing can
exceed 15 minutes. Garbage collection does not prevent GitHub's own expiry or
LRU eviction. This cache carries no Cachix publishing token.

Hestia's post-build hook uploads EVERY path a writing job builds, build-time
inputs included, and v3.1.0 has no path exclusion: only `read-only` disables the
hook. So a check whose closure may reach no cache, such as one built from the
CodeQL bundle, whose terms forbid distributing it, names itself in
`unpublishedChecks` (`lib/testing/check-options.nix`). `ciChecks` leaves it out
of the matrix, and ci.yml's `checks-unpublished` job builds
`ciUnpublishedChecks` with no Hestia and no Cachix token, as `kiro-patched`
does; `checks-matrix` requires that job. A Cachix `pushFilter` does not cover
this: PR #2771's first run uploaded the bundle through a matrix worker's Hestia
drain while every credentialed Cachix step filtered it.

The `checks-eval` job registers every evaluated `.drv` closure in the same
cache. Its workers pass the eval job's `manifest-version` through the helper's
`wait-manifest-version` input and run `hestia prefetch` before building: with
`filter-drv-closures`, the public references are omitted from the closure and
prefetch prepares them. Fork PRs skip that matrix, since a read-only cache
cannot register the closures the workers need.
