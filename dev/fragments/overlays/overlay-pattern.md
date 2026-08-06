## Overlay Grouping under `pkgs.ai`

> **Last verified:** 2026-08-05 (commit pending — the Go toolchain floor is now
> DERIVED from the pinned source's go.mod rather than hand-written, is carried
> by ALL SEVEN Go packages rather than two, and is reached through the new
> `vu.mkGoBuilder`; adds `checks/go-floor-drift.nix` as the loud half and
> records that the toolchain is a BUILDER argument only `.override` can reach.
> Measured: `gh` had ALREADY silently required Go >= 1.26.5, so it was the next
> package to break after `glab`). Prior: 2026-08-03 (commit pending — records
> the property used to associate versioned derivations with a flake-input update
> owner or a reasoned local-source exemption). Prior: 2026-08-03 (commit pending
> — makes `pkgs.ai` the single binary-package namespace, retains `generic` as a
> temporary nested bucket, and moves the two forge CLIs into `ai.devTools`).
> Prior: 2026-08-03 (commit pending — makes overlay-owned local implementation
> sources a boundary invariant and relocates the auto-memory helper and
> distiller sources accordingly). Prior: 2026-08-02 (commit pending — adds
> Semble's direct external-flake derivation pattern and identity-preserving MCP
> role). Prior: 2026-08-01 (commit pending — records that `glab`'s
> `extraExtract` also regenerates its `passthru.extracted` sidecar, via the new
> shared `vu.mkExtractRegen`, and that glab is the one extracted package where
> the fixer-then-extract ORDER is forced. It had NO regeneration at all until
> now, which nothing caught until its first version bump reddened
> `checks.<system>.glab-extracted` on PR #621). Prior: 2026-07-28 — the commit
> adding THAT line lands `glab`: the first Go package whose SRC hash also lives
> in the sidecar (`vu.mkGoSrcVendorFix`), the first GitLab-hosted version check
> (`vu.glLatestVersionCmd`), and the collapse of the three sidecar hash fixers
> onto one `vu.mkHashFix` body driven by `hashFixTargets`. It also corrects the
> thin-override list, which now has to distinguish the SIDECAR contract (where a
> hash comes from) from the OVERRIDE SEAM (`.override` vs `overrideAttrs`) —
> `glab` shares bruno's former but not its latter. Prior: 2026-07-27 retired the
> "bruno is the ONLY worked example" claim (`overlays/git-tools/git-absorb.nix`
> is a second one and PREDATES it), replaces the heuristic with the
> INPUT-vs-OUTPUT rule read out of the pinned nixpkgs' `lib.extendMkDerivation`,
> and corrects "the failure is SILENT … shape-independent" — silent for
> `buildNpmPackage`, LOUD for `buildRustPackage`. Prior: 2026-07-25 wired
> `passthru.fixVendorHash` / `passthru.fixNpmDepsHash` to a real caller
> (`fix_sidecar_hashes`) for the first time and corrected the `overlays/lib.nix`
> comment that claimed a re-run which did not exist; see the Go-vendorHash
> section below. Before that: two changes, both wanted. `bc23e34b` (LANDED)
> records that the CI warm step now forces `drvPath` and therefore DOES cover
> sidecar-versioned packages; the commit adding this line (pending) adds the
> sidecar-vs-inline decision rule and the `.override`-vs-`overrideAttrs` rule
> for `lib.extendMkDerivation` builders. Both sit on top of the Go
> sidecar-`vendorHash` mechanism, the derived-Go-toolchain seam, and the
> platform-gated-attribute rule, on top of the multi-major-attribute shape, the
> namespaced-only rule and the store-path-parity expectation for thin nixpkgs
> overrides. If you add, remove or rename an overlay namespace, move a package
> between namespaces, or change how a `generic` package relates to its nixpkgs
> original, and this section isn't updated in the same commit, stop and fix it.

`overlays/default.nix` aggregates every binary package under the single
`pkgs.ai` namespace. Flat AI CLIs live directly below it; supporting categories
are `devTools`, `generic`, `gitTools`, `lspServers`, and `mcpServers`. Every
group is built the same way — an attrset of
`import ./<dir>/<name>.nix {inherit inputs final;}` entries, passed through
`guard` (the unfree wrapper) in the output set, and flattened into
`packages.<system>` in `flake.nix` for CLI ergonomics. The overlay never writes
a bare `pkgs.<name>` attribute.

Keeping every group below `pkgs.ai` is deliberate while this repository is the
only consumer. Whether selected packages should eventually merge into the plain
nixpkgs namespace is a later policy decision, not something individual package
moves decide implicitly.

`generic` is a temporary category for supporting packages that have not yet
earned a clearer role. It is not a claim that they belong in a permanent
"non-agentic" product namespace. The physical `overlays/generic/` subtree stays
split-ready: it must not acquire dependencies on the rest of the repo beyond
`overlays/lib.nix`, so it can be regrouped or extracted without archaeology.
Obvious classifications should move out incrementally; `gh` and `glab` are the
worked example, living together under `overlays/dev-tools/` and
`pkgs.ai.devTools`.

Repo-local implementation sources consumed by an overlay derivation belong
beside that derivation under `overlays/`, even when a package module is their
only runtime consumer. An overlay must not import build sources from
`packages/`: that outbound edge prevents lifting the overlay tree as a clean
directory move. The auto-memory sources are the worked examples:
`overlays/kiro-memory-distiller/` and `overlays/mcp-servers/openmemory-mem/`.

### Direct external-flake derivations

Semble is the external pinned-package exception to the local-build patterns
below. `overlays/semble.nix` returns
`inputs.llm-agents.packages.${system}.semble` directly. It does not apply the
input's `overlays.shared-nixpkgs`, rebuild with this repository's `ourPkgs`, or
call `overrideAttrs`; any of those would replace the upstream cache identity
that this export promises to preserve. A plain attrset extension adds
`passthru.updateFlakeInput = "llm-agents"`; the reverse update-target check
validates that named input exists and treats its normal input bump as Semble's
update path without changing the upstream `drvPath` or `outPath`.

When one upstream derivation ships multiple role binaries, expose secondary
roles with a plain attrset/meta overlay. `semble-mcp` changes only
`meta.mainProgram`, so `lib.getExe` selects the MCP binary while `drvPath` and
`outPath` remain identical to the CLI and upstream output. The cache-hit-parity
check locks all three identities.

Two mechanical consequences of living in a subdirectory rather than at the
`overlays/` root:

- `vu = import ../lib.nix` (one level up), not `./lib.nix`.
- The update helpers default `sourcesFile` to `overlays/<pname>-sources.json`,
  which is wrong here, so grouped packages pass `sourcesFile` explicitly. The
  sidecar lives beside the package file.

Nothing else is relaxed: cache-hit parity applies in full (see that fragment —
shipping data files is NOT the same as being content-only), each package gets a
`config.checks.cacheHitParity` row, and each version-tracked one must be covered
by the bidirectional update-target check. Locally pinned packages normally own a
same-name `config.update.targets` row; direct external derivations name their
flake-input owner instead.

These are package properties, not a second name registry:
`passthru.updateFlakeInput = "<input>"` is accepted only when the named root
flake input exists, while `passthru.updateTargetExempt = "<reason>"` must carry
a non-empty explanation. The latter is for derivations such as the
repository-local `kiro-memory-distiller`, whose version labels its in-tree
implementation but has no upstream release to sweep.

### Thin overrides of a nixpkgs package

Most supporting entries (`btop`, `bun`, `fblog`, `gh`, `glab`, `oh-my-posh`,
`otel-tui`, `pnpm_10`, `pnpm_11`) are not fresh derivations but
`ourPkgs.<name>.overrideAttrs` over the nixpkgs one, moving only `version`,
`src`, `passthru.updateScript` and — for the Go ones — `vendorHash`. `gluetun`
is the exception, and only because nixpkgs does not carry it at all; `bruno` is
deliberately absent from that list because `overrideAttrs` cannot express its
override at all (see the `.override` section below). `glab` IS on the list and
belongs there — `buildGoModule` reads `vendorHash` and `src` off `finalAttrs`,
so composing on the output works — even though it shares bruno's SIDECAR
contract, because that contract is about where the hash comes from, not about
which override seam is correct. Two rules that are not obvious from reading such
a file:

- **Namespaced-only.** The overlay writes `pkgs.ai.<group>.<name>` and NEVER a
  top-level `pkgs.<name>`. Shadowing a nixpkgs attribute would turn this from an
  additive overlay into one that silently re-points every unrelated consumer of
  that package; the additive contract is what lets consumers apply the overlay
  without auditing it.
- **An identical store path is EXPECTED, not a bug.** While our sidecar pin and
  nixpkgs' pin name the same version, a thin override yields the byte-identical
  derivation — a fixed-output `src` path follows its hash, not its fetcher, so a
  `fetchzip` of the repo-archive tarball lands on the same path
  `fetchFromGitHub` does. The package still earns its place: it rides this
  repo's 4x/day update sweep instead of a nixpkgs channel bump, and the paths
  diverge the moment upstream moves. Do not "clean up" such a package on parity
  grounds.

Measured for `pnpm_10` at landing: `pkgs.ai.generic.pnpm_10` and plain
`pkgs.pnpm_10` share both `drvPath` and `outPath` (`…-pnpm-10.34.5.drv` /
`…-pnpm-10.34.5`), and `nix build .#pnpm_10` substitutes straight from
`cache.nixos.org`. That is the parity rule above working exactly as designed,
not a redundant package.

`passthru` is NOT a derivation input, which is what lets a thin override add an
`updateScript` without moving the store path. Merge it
(`passthru = (prev.passthru or {}) // { … }`) rather than replacing it: nixpkgs
hangs real API there (pnpm alone carries `configHook`, `fetchDeps`,
`majorVersion`, `nodejs-slim` and `tests`) and replacing the set drops all of
it.

### `.override` the builder, never `overrideAttrs`, on an `extendMkDerivation`

The thin-`overrideAttrs` shape above works because `cmake`/`buildGoModule` read
`version` and `src` as ordinary attrs. It does NOT transfer to a builder written
with `lib.extendMkDerivation`.

**Sort the attr into INPUT or OUTPUT — that makes the rule decidable in advance
instead of a per-package surprise.** `lib.extendMkDerivation`
(`lib/customisation.nix`) builds the derivation as
`constructDrv (final: removeAttrs previous excludeDrvArgNames // extendDrvArgs final previous)`,
so `extendDrvArgs` runs exactly ONCE, at call time, over the INCOMING args;
`overrideAttrs` is plain `stdenv.mkDerivation`'s and only ever composes on the
merged result. Therefore:

- An attr the builder **derived** (`cargoDeps`, `npmDeps`) IS movable through
  `overrideAttrs` — you are replacing the finished value.
- An attr the builder **consumed** to derive one (`cargoHash`, `npmDepsHash`) is
  NOT: the derived value already exists, computed from the old input. Neither
  hash is listed in `excludeDrvArgNames`, so the new value is not even dropped —
  it lands in the final attrs as a dead env var nothing reads.

Read out of the pinned nixpkgs (26.11) rather than inferred:
`pkgs/build-support/rust/build-rust-package/default.nix` and
`pkgs/build-support/node/build-npm-package/default.nix` are both
`lib.extendMkDerivation`, and each computes its vendor derivation inside
`extendDrvArgs` — `fetchCargoVendor { … hash = args.cargoHash; }` and
`fetchNpmDeps { … hash = npmDepsHash; }` respectively.

**How that failure PRESENTS is builder-specific — do not generalize one
measurement.** Both take the hash from the incoming args, but they differ in
where the vendor derivation's OTHER inputs come from:

- `buildNpmPackage` reads `src`, `postPatch` and `name` for `fetchNpmDeps` from
  the destructured **args** as well, so an `overrideAttrs` bump moves NOTHING in
  the deps derivation and the build succeeds SILENTLY against the old dependency
  set. Measured on bruno:

  ```nix
  pkgs.bruno.overrideAttrs (_: { version = "4.0.0"; npmDepsHash = <fake>; })
  #  version              = "4.0.0"                  <- moved
  #  npmDeps.name         = "bruno-3.5.2-npm-deps"   <- did NOT
  #  npmDeps.outputHash   = sha256-4VsSXiHj/…        <- 3.5.2's hash
  ```

  That builds 4.0.0 source against 3.5.2's dependency set and reports no error
  at all.

- `buildRustPackage` reads `name`/`pname`/`version`/`src`/`sourceRoot` for
  `fetchCargoVendor` from **`finalAttrs`** — the overridden fixed point — while
  still taking `hash` from `args.cargoHash`. The same bump therefore vendors the
  NEW source against the OLD hash and fails LOUDLY on the mismatch.

The seam is the same either way: wrap the BUILDER —
`pkg.override (_: { buildNpmPackage = args: realBuilder (finalAttrs: (lib.toFunction args) finalAttrs // { … }); })`
— which puts the new values in the incoming args where `extendDrvArgs` reads
them.

`lib.toFunction` is load-bearing in that snippet: upstream expressions come in
both `attrs` and `finalAttrs: attrs` flavors, and it normalizes them.

Two worked examples in this tree, both moving an INPUT hash — cite either:

- `overlays/git-tools/git-absorb.nix` — `cargoHash`, via
  `ourPkgs.git-absorb.override (_: { rustPlatform.buildRustPackage = … })`. It
  PREDATES bruno.
- `overlays/generic/bruno.nix` — `npmDepsHash`, via
  `ourPkgs.bruno.override (_: { buildNpmPackage = … })`.

`overlays/git-tools/git-branchless.nix` is a plain `overrideAttrs` and is
CORRECT as one: it sets `cargoDeps` — an `ourPkgs.rustPlatform.importCargoLock`
over the pinned src, i.e. the derived OUTPUT — and never `cargoHash`. Do not
cite it as a builder-wrap example, and do not "fix" it into one.

One trap in the git-absorb spelling:
`.override (_: { rustPlatform.buildRustPackage = … })` REPLACES the whole
`rustPlatform` argument with a one-key attrset. It is safe there only because
nixpkgs' `git-absorb` expression reads nothing else off `rustPlatform`. Check
the package's argument list before copying that shape.

### Sidecar or inline: what actually decides it

A version-tracked overlay records its pin either INLINE in its `.nix` file
(bumped by plain `nix-update` — the shape most `config.update.targets` rows use)
or in a `<name>-sources.json` SIDECAR written by a custom `updateScript`. The
choice usually gets read as a question about the source shape. It mostly is not.

- **HARD CONSTRAINT, decides by itself: per-platform fanout.** `nix-update`
  models exactly ONE `src` and structurally cannot express N systems, so a
  package needing per-platform sources REQUIRES a sidecar. Not a preference —
  there is no inline form of it.
- **Otherwise it is a COST TRADE on the NO-OP sweep**, not a shape mismatch.
  Both shapes are correct. They differ in what a sweep that finds nothing costs.
  Inline + `nix-update` re-derives every hashed dependency on EVERY run, because
  it prefetches with `outputHash = ""`, which normalizes to an all-zeros hash
  whose store path is never registered valid — uncacheable by construction, so
  nothing carries over between sweeps. A sidecar's version-equality early exit
  pays zero: one HEAD against `releases/latest` and it stops.
- **So the deciding variable is the SIZE of the fetched dependency tree**, not
  the source shape. Measured on bruno, whose npm dependency set is 607 MB
  (roughly 40x anything else here): ~28 s and ~642 MB per sweep inline, against
  ~1 s and 0 bytes on the sidecar. At 4x/day that is ~2.5 GB/day for zero
  information, which is what tipped it. A package whose only hash is a small
  `src` is fine inline and costs less code — the inline rows here are not an
  oversight.
- **State the counter-cost honestly.** A sidecar does NOT self-heal a hash
  invalidated WITHOUT a version bump — a nixpkgs-side fetcher or builder change,
  say. It early-exits on version equality and never re-derives, so the build
  fails LOUDLY on a hash mismatch until someone runs the standalone fixer by
  hand (`passthru.fixVendorHash`, `passthru.fixNpmDepsHash` — which exist for
  exactly this). Inline re-derives every sweep and therefore self-heals that
  case. **Neither shape fails silently**; do not write that one does.
- **Record the inversion.** It corrects a belief this repo held: the rows still
  on plain `nix-update` are paying that uncacheable per-sweep cost TODAY, so
  "sidecars are legacy overhead from an older design" is close to backwards.
  Noted as unexamined rather than as a migration proposal — for a small `src`
  the cost is small, and the counter-cost above is real.

One sidecar consequence worth knowing before reaching for
`ghArchiveUpdateScript`: it records the hash of a `nix-prefetch-url --unpack`,
which is only the right value when the src is a plain fetch of that URL. An
overlay that re-points an upstream fetcher carrying a `postFetch` gets a hash
over the POST-`postFetch` tree, and the two differ — measured on bruno v4.0.0,
where `postFetch` runs `npm-lockfile-fix`: `sha256-uZsw…` from the prefetch
versus `sha256-M4oN…` from the fetcher. Recording the prefetch value puts a
plausible, wrong hash in the sidecar. Such a package passes `platforms = {}`
(version only) and lets an `extraExtract` fixer scrape both hashes out of a real
build.

### Carrying several majors of one package

`pnpm` is carried at two majors (`pkgs.ai.generic.pnpm_10`,
`pkgs.ai.generic.pnpm_11`) and the shape generalizes to any versioned attribute
family:

- One shared builder (`overlays/generic/pnpm-major.nix`) takes the major as an
  argument; the per-major files are two-line delegations. They exist because
  each major needs its own path for `--override-filename` in
  `config/update-targets.nix` and its own sidecar beside it — not because the
  logic differs.
- The version check reads the registry's PER-MAJOR channel (npm's `latest-<N>`
  dist-tag), not the global latest, so a major never bumps itself out of its own
  attribute.
- **Guard the major at eval time.** Anything in the upstream expression that
  reads the ARGUMENT `version` rather than `finalAttrs.version` does not follow
  an `overrideAttrs` bump — for pnpm that is `passthru.majorVersion`, the
  `postInstall` completion branch, and nixpkgs' own `updateScript`. A sidecar
  pointed at the wrong major would therefore build a working derivation that
  lies about which major it is. `pnpm-major.nix` throws instead.
- Expect exactly one of the majors to sit at nixpkgs parity and the others to
  carry a delta; which one is which rotates as channels move. Parity is not
  evidence that a major should be dropped.

Rust packages on this pattern have one extra constraint. `ghArchiveUpdateScript`
refreshes only the src hash in the sidecar, so an inline `cargoHash` would go
stale on every bump — the known transitive-hash gap. Override `cargoDeps` with
`rustPlatform.importCargoLock { lockFile = "${src}/Cargo.lock"; }` against the
PINNED src instead, so one hash covers both and the vendor set self-updates.

### Go packages: the vendorHash goes in the SIDECAR

Go has the same transitive-hash problem and no `importCargoLock` equivalent —
`go.sum` records module hashes, not a Nix-fetchable vendor tree — so
`vendorHash` must be recorded somewhere. It goes in the sidecar (`gh`, `glab`,
`gluetun`, `oh-my-posh`, `otel-tui`), never inline, and the mechanism is worth
understanding before touching it:

- `mkUpdateScript` rebuilds the sidecar FROM SCRATCH on every write
  (`jq -n --arg v "$latest" '{version: $v}'`), so any key it does not itself
  produce is DESTROYED. `vendorHash` is exactly such a key.
- Therefore each Go overlay reads `sources.vendorHash or lib.fakeHash` — the
  `or` covers the window between the sidecar write and the fix — and threads
  `extraExtract = "${fixVendorHash}"` so `vu.mkGoVendorFix` runs immediately
  after. The fixer builds `<attr>.goModules` through the flake's own `packages`
  output (this repo has NO `legacyPackages`) and writes back the `got:` hash
  from a `-go-modules` mismatch only.
- It is also `passthru.fixVendorHash`, because a nixpkgs or Go-toolchain bump
  can invalidate a vendor hash with no version bump at all — and `extraExtract`
  fires only on a VERSION bump, so nothing else would re-derive it.
  `fix_sidecar_hashes` (`dev/scripts/update-common.sh`) discovers this attr
  across `packages.<system>` and runs it when an input bump's build verification
  fails, so that case self-heals into the same commit instead of parking the
  input update as HELD BACK. Until 2026-07-25 the standalone had NO caller and
  `overlays/lib.nix` claimed a re-run that did not exist; if you unwire it, fix
  both.
- `passthru` must be MERGED. `buildGoModule` hangs `goModules` and
  `overrideModAttrs` there, `build-support/go/module.nix` warns loudly when an
  overlay drops them, and the fixer resolves `.goModules` through that very
  attrset.

`glab` is the one Go package where the SRC hash goes in the sidecar too, and it
is `vu.mkGoSrcVendorFix` rather than `mkGoVendorFix` for exactly the reason
bruno is not on the plain prefetch path: nixpkgs' `glab` fetches with
`leaveDotGit = true` and a `postFetch` that records the short commit into
`COMMIT` and then strips `.git`, so the recorded hash is over the
POST-`postFetch` tree and `nix-prefetch-url --unpack` cannot reproduce it. It
pairs `platforms = {}` with an `extraExtract` that restores `srcHash` then
`vendorHash` — **that order is forced**, because `goModules` derives FROM `src`,
so a stale `srcHash` fails the vendor build on the src mismatch and never
reaches the vendor one.

`glab` also carries a `passthru.extracted` sidecar, so the SAME `extraExtract`
runs `vu.mkExtractRegen` after the hash fixer — and it is the only extracted
package whose ordering matters. The other three (`chatgpt-codex`, `claude-code`,
`kiro-cli`) fetch a prebuilt binary and have no hash to restore, so they pass
`mkExtractRegen` alone; glab's extract BUILDS `src` and `goModules`, so running
it before the fixer would hit `lib.fakeHash` instead of producing a schema.

Wiring that regeneration is not optional for an extracted package, and glab
demonstrates the cost of missing it: it was the one such package that never had
it, which nothing caught until its first-ever version bump (PR #621) turned
`checks.<system>.glab-extracted` red on a sidecar that still described 1.110.0.

The three fixers (`mkGoVendorFix`, `mkGoSrcVendorFix`, `mkNpmDepsFix`) are now
one body — `vu.mkHashFix` — parameterized by an ordered list of `hashFixTargets`
entries, each a `(attrPath, drvPattern, key)` triple. Add a target to that
attrset rather than open-coding a fourth `writeShellScript`; the derivation-name
patterns are load-bearing (see `fodHashFixFn`) and a copy is how they drift.

`glab` also does NOT use the `gh` shape for its version check: it is hosted on
gitlab.com, which has no `releases/latest` redirect to read a tag out of, so
`vu.glLatestVersionCmd` makes an unauthenticated API call to
`releases/permalink/latest` (which, like GitHub's "latest", excludes upcoming
releases) and reads `.tag_name`. It takes a URL-ENCODED project path —
`owner%2Frepo` — and does not encode for you, so that a caller which already
encoded is not silently mangled.

Two traps, both measured on `oh-my-posh` while landing it:

- **`postPatch` is an INPUT to `goModules`.** module.nix threads it into the
  vendor derivation, so which test files you remove changes the vendor set —
  nixpkgs' list drops `cli/image/image_test.go`, the only importer of
  `golang.org/x/image/font/gofont/gomono`, and `vendor/modules.txt` loses that
  line. A vendorHash therefore does NOT transfer across a `postPatch` change.
- **"It built" does not validate a vendorHash.** A fixed-output path is
  content-addressed, so an identically-named path already in the local store
  (e.g. built by a sibling repo with a different `postPatch`) is accepted
  without building anything. That is precisely how a wrong vendorHash passed a
  full local build and would then have failed CI on a clean store. Force the
  real computation: perturb the sidecar's version so `mkUpdateScript` takes the
  prefetch-and-write path, run the update script, and confirm the regenerated
  file is byte-identical.

### Go toolchains are DERIVED from a floor, never pinned

`vu.goToolchainForFloor` takes the package's own go.mod `go` directive (or a
higher `toolchain` directive) as a FLOOR and returns `ourPkgs.go` whenever our
pin satisfies it, otherwise the lowest `go-bin` RELEASE that does
(`purpleclay/go-overlay`, applied inside `ourPkgs` the way `rust-overlay`
already is), otherwise a throw naming package, floor and newest available.

Do not "clean up" a floor that currently resolves to our own `go` — it is the
mechanism, not a leftover. And do not replace it with a pinned toolchain
version: a pin cannot distinguish "still filling a real gap" from "nixpkgs
caught up and this is now a DOWNGRADE". The sibling repo demonstrates the
failure — it pins oh-my-posh to Go 1.26.0, a gap-filler when written and a
downgrade against our pin's 1.26.5. Prereleases are filtered out of the
candidate set on purpose: `go-bin.latest` is currently a prerelease, and Nix
sorts `1.27rc1` ABOVE `1.27.0`. `checks/go-toolchain-floor.nix` exercises all
three branches plus two positive controls, which is also what keeps the input
from shipping dormant.

**ALL SEVEN Go packages carry the seam**, not just the two that once needed it —
`gh`, `glab`, `github-mcp`, `gluetun`, `mcp-language-server`, `oh-my-posh`,
`otel-tui`. Scoping it to "whatever broke most recently" is how the same defect
gets rediscovered per package: when `glab` broke, `gh` had ALREADY silently
required Go >= 1.26.5 and would have been next.

Reach it through **`vu.mkGoBuilder`**, which composes floor -> toolchain ->
`buildGoModule.override` in one call. Do not re-expand that chain per package;
that three-line repeat across three sites is what the helper replaced. `glab` is
the one legitimate exception — it needs the TOOLCHAIN itself a second time, for
its schema-dump extract (which compiles upstream's `internal/config` and is
subject to the same floor), so it calls `goToolchainForFloor` directly and binds
the result once.

**The toolchain is a BUILDER argument, so `.override` is the only seam that
reaches it.** `overrideAttrs` cannot: `version`/`src`/`vendorHash` are attrs
`buildGoModule` reads off `finalAttrs`, but `go` is consumed when the builder is
called. Packages needing both do
`(pkgs.<name>.override { buildGoModule = …; }).overrideAttrs (…)`, in that
order. `gh`, `glab` and `otel-tui` all gained the `.override` layer for exactly
this reason.

#### The floor itself is DERIVED, never hand-written

A hand-maintained floor literal is still a pin — it just rots more slowly. The
update pipeline bumps these packages 4x/day and would never touch it, and a
stale-LOW floor is the dangerous direction: `versionAtLeast ourGo floor` then
returns `ourGo` and the seam **silently does nothing**.

So the floor is extracted from the pinned source's go.mod, by mechanism:

- **Release mode (sidecar-versioned: `gh`, `glab`, `gluetun`, `oh-my-posh`,
  `otel-tui`)** — `vu.mkGoFloorFix` runs as `extraExtract` and writes a
  `goFloor` key into the sidecar. Correct home for it because the floor is a
  function of the pinned version, so it changes only when the version does —
  unlike `vendorHash`, which can be invalidated with no version bump and
  therefore also needs a standalone `passthru` escape hatch.
- **Trunk mode (rev-pinned: `github-mcp`, `mcp-language-server`)** — a literal
  in the overlay. These have no sidecar and are bumped by `nix-update` (`git`
  targets in `config/update-targets.nix`), so there is no repo-owned update
  script to hook a rewrite into.

**ORDER: hash fixers first, then the floor.** `mkGoFloorFix` builds `.src`, so a
package whose `srcHash` also lives in the sidecar (`glab`) must have that
restored first. For `glab` the floor then precedes `mkExtractRegen`, because the
schema dump compiles the module and needs the toolchain the fresh floor selects.

Reading the floor is **silent by construction** — overlays read
`sources.goFloor or vu.goFloorUnknown`, and `goFloorUnknown` (`"0"`) is
satisfied by everything. That is deliberate and not a hole: `mkGoFloorFix` must
evaluate the package to build its `.src`, so a `throw` on the missing key would
deadlock the fixer that repairs it. `checks/go-floor-drift.nix` is the loud half
— it compares every recorded floor against the real go.mod and fails naming the
package, the actual requirement, and the remedy (fixer vs. literal).

That check takes **NO REGISTRY**: it filters `self.packages.<system>` for
`passthru.goFloor`. A list of Go packages would be a second source of truth a
new package could be added without touching, which is exactly how one ends up
unprotected. It shares `vu.goModFloorFn` with the writer, so gate and writer
cannot disagree about what the floor is. `goModPath` is a parameter, not a
constant — `oh-my-posh` keeps its module under `src/`.

### A genuinely platform-specific package is gated at the ATTRIBUTE

`gluetun` is the only one so far: `internal/routing` uses `unix.RT_TABLE_MAIN` /
`RT_TABLE_LOCAL`, Linux-only constants (measured by cross-compiling
`GOOS=darwin GOARCH=arm64`). A restrictive `meta.platforms` is NOT sufficient —
the attribute still exists on darwin and forcing its `drvPath` throws "not
available on the requested hostPlatform", which both `nix flake check` (it
evaluates every system) and the required darwin CI leg do. So
`overlays/default.nix` wraps the entry in
`lib.optionalAttrs final.stdenv.hostPlatform.isLinux`, and the package is simply
absent elsewhere.

Two registries have to agree with that:
`config.checks.cacheHitParity.<name>.platforms` (or the check aborts on darwin
looking up a package that is not there) and, if a future case needs it, anything
else that enumerates packages per system. This is the exception, not a licence
to platform-gate anything inconvenient — a sidecar merely missing a platform is
still the bug rule 6 describes.

**The CI IFD warm step DOES cover that kind of IFD — since it started forcing
`drvPath`.** `.github/actions/warm-ifd` pre-realizes sources by evaluating
`p.drvPath or p.name or "unknown"` across the package set, which puts every
package through `derivationStrict` and so forces every IFD on its path,
`cargoLock.lockFile` included.

It used to force `p.version` instead, and that left this exact shape uncovered:
a package versioned from a `-sources.json` sidecar resolves `.version` out of
the sidecar and short-circuits before `drvPath` (and therefore `cargoDeps`) is
ever forced. Measured on `fblog` with
`--option allow-import-from-derivation false`: `.version` evaluates clean,
`.drvPath` fails with `cannot build '…-source.drv^out' during evaluation`. That
was never a build break — the later eval simply fetched the source itself, just
without the warm step's retry/backoff — but it meant a sidecar-versioned package
was NOT warmed merely by being in `packages`. See the ifd-patterns fragment for
the measured cost of the wider forcing and for why the `or` chain does not
swallow a throw.

## Overlay Lambda Signature

All overlays in this repo use a **three-argument signature** with the first
argument typically discarded:

```nix
_: final: _prev: { ... }
```

This is **deliberate**, not a typo. Reviewers (especially automated ones)
frequently flag this as "atypical" because the standard nixpkgs overlay
convention is `final: prev:` (two arguments). Both forms work, but the
three-argument form is the convention here.

### Why three arguments

The first argument is reserved for an **inputs blob** that some overlays may
need (e.g., a future AI CLI overlay that consumes `inputs.rust-overlay` for Rust
toolchain pinning, or a git-tools overlay that pulls version data from external
inputs). To keep all overlays uniformly callable from `flake.nix`, every overlay
takes the same three-argument shape regardless of whether it actually uses the
inputs.

After the factory rollout (Milestones 1–10), the overlays at the flake level are
split between the unified binary-package overlay (`./overlays`, which consumes
`inputs` for cache-hit parity via per-package `ourPkgs`) and the content-only
overlays under `packages/` (which don't need extra flake inputs and are called
with an empty `{}`). All keep the same three-argument shape so all overlays
remain uniformly callable from `flake.nix`'s `bind-once → reuse` composition
pattern:

```nix
# flake.nix
aiOverlay = import ./overlays {inherit inputs;};           # every grouped drv namespace
codingStandardsOverlay = import ./packages/coding-standards {};
stackedWorkflowsOverlay = import ./packages/stacked-workflows {};

overlays.default = lib.composeManyExtensions [
  aiOverlay                 # every binary-package group under pkgs.ai.*
  codingStandardsOverlay    # content package
  stackedWorkflowsOverlay   # content package
];
```

The content overlays (`codingStandardsOverlay`, `stackedWorkflowsOverlay`) are
called with an empty `{}` first argument because they don't need flake inputs.
The binary overlay (`aiOverlay`) consumes `{inherit inputs;}` because its
per-package files in `overlays/<name>.nix` need `inputs.nixpkgs` for cache-hit
parity and `inputs.rust-overlay` for Rust toolchain pinning. The first `_:` (or
`{...}:`) swallows the import-time argument so the resulting function is the
standard `final: prev:` shape `composeManyExtensions` expects regardless.
Without this, overlays that need inputs would have a different binding pattern
at the call site than overlays that don't, breaking the DRY composition.

### Why `_prev`

The vast majority of overlays in this repo only **add** packages (via
`passthru`-rich derivations) and never **modify** existing ones. When you don't
read from `prev`, leading-underscore-prefix it as `_prev` so deadnix and human
reviewers see at a glance "this overlay doesn't depend on the previous overlay's
state". The few overlays that DO read from `prev` (e.g., to wrap an upstream
package) drop the underscore prefix and inherit from `prev` explicitly.

### Don't "fix" the signature

If you see a Copilot or human reviewer suggest changing `_: final: _prev:` →
`final: prev:`, **decline**. The three-argument form is the established
convention and is required for the bind-once overlay composition pattern in
`flake.nix`.
