## Overlay Grouping under `pkgs.ai`

> **Last verified:** 2026-09-12 — native owner recipes replace grouped overlay
> barrels; StrictDoc joins the upstream package exports, preserving pinned build
> identity and consumer guards.
>
> Full lineage: `git show 4705317b:dev/fragments/overlays/overlay-pattern.md`.

`lib/facets/repository.nix` discovers native package trees below
`packages/<owner>/packages/` and exposes them through `overlays.default`. AI
CLIs live directly below `pkgs.ai`; supporting categories are `devTools`,
`generic`, `gitTools`, `lspServers`, and `mcpServers`. Content packages keep
their existing top-level names. Flat flake outputs come from leaf basenames with
collision validation; adding a recipe requires no root import entry.

The outer directory is ownership; the inner tree is the public namespace.
`generic` remains a temporary category for supporting packages awaiting a
clearer role. A later namespace change should move the inner recipe path, while
renaming the outer owner leaves the public namespace unchanged.

Recipes receive this flake's pinned `pkgs`, `inputs`, shared `packageLib`, and
`repoPath`. Keep source sidecars, patches, extraction helpers, and declarative
registrations with the owner. `registry.nix` declares update/cache/doc entries;
`repoPath ./relative/path` derives mutable paths from their actual location. The
shared composer owns consumer unfree policy. See the package-ownership fragment
for the native composition boundaries.

### Absorption is about CADENCE. Never re-open it on a version comparison

**A package is absorbed so it tracks upstream on this repo's 4x/day sweep. That
is the entire justification. It is never a version delta, a store-path delta, or
a derivation-quality delta against nixpkgs — and "nixpkgs already has this
version" is NOT a reason to skip, defer, or drop an overlay.**

This is a STOP rule, not a consideration to weigh. If you find yourself writing
"nixpkgs is already at the same version, so this may not be worth carrying",
delete the sentence and build the overlay.

The reasoning, once, so it does not need re-deriving: parity today is a
SNAPSHOT. What absorption buys is bounded LATENCY on the _next_ release, and
that latency can be weeks regardless of where the two happen to sit right now.
The measurement and the property are different quantities, and only one of them
is the decision.

A parity measurement is still worth taking — it tells you what carrying the
package costs, and whether nixpkgs' derivation is worth overriding rather than
reimplementing. Those are the only two questions it may open. It may not open
"should we carry this at all".

Corollaries, each learned the hard way:

- **Override, do not copy.** When nixpkgs has the better derivation, take it — a
  thin `overrideAttrs` carrying `version`/`src`/hash from our sidecar. We get
  their implementation and our cadence. See "Thin overrides of a nixpkgs
  package" below.
- **Our `src` and `version` always win**, whoever owns the rest. That is the one
  thing an overlay may never inherit from nixpkgs.
- **Assume the latest release is in hand** when assessing anything. Do not build
  a decision table around whether to own a package, and do not report a fix as
  unavailable because nixpkgs has not picked it up. Take upstream's latest
  release (or main HEAD where that is the tracking choice) as the version you
  are designing against.
- **Build it, do not note it.** Write the overlay in the same change when the
  package is already CONSUMED here — it appears in `devenv.nix` `packages`, in a
  module's or wrapper's package / `runtimeInputs` list, as an `ai.*` option
  default, or in owner `registry.nix` — or when the operator named it. Being a
  transitive dependency alone does not qualify. If it fails all of those, say
  which one it fails and stop. A version or store-path comparison against
  nixpkgs is never a ground to decline, defer or drop an overlay.

`pnpm_10` / `pnpm_11` are the worked example: one sat at exact nixpkgs parity at
landing and was absorbed anyway, precisely so the pair is carried the same way
when the channel next moves. The several-majors section below repeats the rule
for majors of one package; this is the general form.

### Direct external-flake derivations

StrictDoc uses the same external-flake package contract as Semble. Its native
recipe at `packages/strictdoc/packages/ai/devTools/strictdoc/package.nix`
re-exports `inputs.strictdoc.packages.${system}.default`; the input keeps its
own nixpkgs and dependency lock. The package is published as
`ai.devTools.strictdoc`, while the grammar module owns interpreter wrapping
through `packages/strictdoc-grammar/lib/mkExtract.nix`.

Semble is the external pinned-package exception to the local-build patterns
below. `packages/semble/packages/ai/semble/package.nix` returns
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

Shared update helpers require an explicit `sourcesFile`. Pass
`sourcesFile = repoPath ./relative/sources.json`; there is no
directory-dependent default. Use the injected `packageLib` rather than importing
a root-relative helper path from a deeply nested recipe.

Nothing else is relaxed: cache-hit parity applies in full (see that fragment —
shipping data files is NOT the same as being content-only), each package gets a
`config.checks.cacheHitParity` row, and each version-tracked one must be covered
by the bidirectional update-target check. Locally pinned packages normally own a
same-name `config.update.targets` row; direct external derivations name their
flake-input owner instead.

These are package properties, not a second name registry:
`passthru.updateFlakeInput = "<input>"` is accepted only when the named root
flake input exists, while `passthru.updateTargetExempt = "<reason>"` must carry
a non-empty explanation. The latter is for a derivation whose version labels an
in-tree implementation with no upstream release to sweep. Its only instance, the
repository-local `kiro-memory-distiller`, was removed on 2026-09-01, so
`updateTargetExempt` currently has no consumer.

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

- `packages/git-absorb/packages/ai/gitTools/git-absorb/package.nix` —
  `cargoHash`, via
  `ourPkgs.git-absorb.override (_: { rustPlatform.buildRustPackage = … })`. It
  PREDATES bruno.
- `packages/bruno/packages/ai/generic/bruno/package.nix` — `npmDepsHash`, via
  `ourPkgs.bruno.override (_: { buildNpmPackage = … })`.

Bruno 4.1.0 adds a second builder-ordering constraint to that same wrapper. Its
new `packages/bruno-sqlite` workspace declares `prepare = "npm run generate"`;
npm invokes it during `npmConfigHook`'s dependency installation, before the hook
patches the freshly installed `node_modules/.bin/tsx` shebang. The sandbox then
fails on tsx's `/usr/bin/env node`. The overlay version-gates two coupled
changes at 4.1.0: `postPatch` replaces only that early `prepare` with a no-op,
and `preBuild` invokes the workspace's normal build after the npm hooks have
patched shebangs. Its upstream `prebuild` regenerates the artifacts before
Rollup. Do not keep only half: suppressing `prepare` without the later build
ships a workspace without build artifacts, while moving the build before shebang
patching restores the failure. The shim is active only while the desired version
is 4.1.0+ and the nixpkgs base is older than 4.1.0. Once the base crosses that
boundary, the overlay delegates lifecycle handling to it and full build
verification remains authoritative; the version is a retirement boundary, not
proof that the base adaptation works. The threshold also keeps 4.0.0's builder
inputs unchanged; the update script, not this compatibility shim, continues to
derive both hashes.

`packages/git-branchless/packages/ai/gitTools/git-branchless/package.nix` is a
plain `overrideAttrs` and is CORRECT as one: it sets `cargoDeps` — an
`ourPkgs.rustPlatform.importCargoLock` over the pinned src, i.e. the derived
OUTPUT — and never `cargoHash`. Do not cite it as a builder-wrap example, and do
not "fix" it into one.

One trap in the git-absorb spelling:
`.override (_: { rustPlatform.buildRustPackage = … })` REPLACES the whole
`rustPlatform` argument with a one-key attrset. It is safe there only because
nixpkgs' `git-absorb` expression reads nothing else off `rustPlatform`. Check
the package's argument list before copying that shape.

### When the attribute stops being the derivation

The two sections above both assume `pkgs.<name>` IS the derivation carrying
`src` — they only disagree about which seam reaches an attr. A third failure
mode breaks that assumption outright: upstream splits the package and leaves the
public name pointing at a **wrapper**.

nixpkgs f13ff45a (2026-08) did exactly that to `kiro-cli`. The real
`mkDerivation` moved to `kiro-cli-unwrapped`, and `kiro-cli` became a
`symlinkJoin` over three `buildFHSEnv` sandboxes (upstream's fix for the TUI
extracting a generic-glibc `bun` at runtime). nixpkgs 9ddfd8a later consolidated
those into one shared FHS environment behind three thin command wrappers. Both
topologies leave the source-owning derivation under `kiro-cli-unwrapped`. Our
overlay kept calling `ourPkgs.kiro-cli.overrideAttrs`, and **everything it set
became a no-op**:

- `src` / `version` — a `symlinkJoin` has neither attr, so the nightly pin was
  simply discarded. Measured 2026-08-10: `.#kiro-cli` produced upstream's
  **2.16.1** while `kiro-cli-sources.json` said **2.16.2**.
- `postFixup` — stdenv returns from `genericBuild` the moment it sees a
  `buildCommand`, so `fixupPhase` never runs. The TERM default, the darwin argv0
  fix and the rollout patch all vanished.

**The build stayed GREEN through all of it.** No seam on the public attribute
could have helped: `.override` reaches the wrapper's arguments, not the
unwrapped derivation's attrs, and `overrideAttrs` reaches a derivation that has
nothing we wanted to change. The fix is to re-point the BASE:

```nix
# packages/kiro-cli/packages/ai/kiro-cli/package.nix
hasUnwrapped = ourPkgs ? kiro-cli-unwrapped;
basePackage =
  if hasUnwrapped then ourPkgs.kiro-cli-unwrapped else ourPkgs.kiro-cli;
# … pinned = basePackage.overrideAttrs (…) …
# then hand it back to upstream's wrapper, preserving the FHS sandbox and the
# route in both directions (metadata/name handling omitted here):
rewrap = payload:
  (ourPkgs.kiro-cli.override {kiro-cli-unwrapped = payload;}).overrideAttrs
  (attrs: {
    passthru = (attrs.passthru or {}) // pinned.passthru // {
      kiroFhsSandbox = ourPkgs.stdenv.hostPlatform.isLinux;
      unwrapped = pinned;
      withFhsPayload = rewrap;
    };
  });
in rewrap pinned
```

Three properties of that shape are deliberate:

- **Feature-detect the ATTRIBUTE, never gate on a nixpkgs version.** One
  expression stays correct on both sides of the split, and the branch retires
  itself when the pin floor moves past it. A version gate would need a human to
  notice and delete it.
- **Re-wrap through upstream's own expression** rather than exporting the
  unwrapped derivation directly. Silently opting out of an upstream RUNTIME fix
  while still publishing the attribute under its normal name is the invisible
  divergence this fragment family exists to prevent — and re-wrapping means
  whatever upstream adds to that wrapper next comes along for free. A named
  consumer option may deliberately select `passthru.unwrapped`, but the public
  package must not change meaning implicitly.
- **Merge `passthru` onto the wrapper, do not replace it.** `passthru` is not a
  derivation input, so re-attaching ours moves neither `drvPath` nor `outPath`,
  and the wrapper's `unwrapped` key is the only supported route from the public
  attribute back to the real binaries. `withFhsPayload` is the corresponding
  route forward: it places a configured payload inside upstream's wrapper while
  retaining the pinned package's metadata and passthru contract.
  `kiroFhsSandbox` disambiguates that contract on darwin and pre-split nixpkgs,
  where the public package is already direct and `unwrapped` is a valid no-op
  selection rather than evidence of an FHS layer.

**How to detect this class before it costs a release.** A silent-drop split
produces no error anywhere; the only tell is that the package's own facts stop
matching its sidecar. Two cheap probes:

```bash
# Does the exported version still match the pin we wrote?
nix eval --raw .#kiro-cli.version
jq -r .version packages/kiro-cli/sources.json

# Did our postFixup actually run? (no wrappers => fixupPhase never happened)
ls -a "$(nix build .#kiro-cli --no-link --print-out-paths)/bin"
```

The derived lesson generalizes past kiro: **a thin `overrideAttrs` does NOT
"pick up upstream changes automatically" — it picks up upstream changes to the
attribute it was written against.** When upstream restructures which attribute
that is, a thin override degrades to a no-op rather than to an error. Anything
downstream that reads the package's own binaries (`passthru.extracted` here)
should therefore locate them by content, not by a name the wrapper chain owns.

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
- **State the counter-cost honestly.** A sidecar's package update script alone
  does NOT self-heal a hash invalidated WITHOUT a version bump: it early-exits
  on version equality and never re-derives. An input update follows a separate
  repair path: failed verification discovers `fix_sidecar_hashes`, derives the
  hashes through the package's passthru fixers, and retries once. An out-of-band
  same-version change still needs the standalone fixer
  (`passthru.fixVendorHash`, `passthru.fixNpmDepsHash`) as an explicit escape
  hatch. Hashes are derived by those fixers, never edited by hand. Inline
  re-derives every sweep and therefore self-heals without that repair path.
  **Neither shape fails silently**; do not write that one does.
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

`pnpm` is carried at three majors (`pkgs.ai.generic.pnpm_10`,
`pkgs.ai.generic.pnpm_11`, `pkgs.ai.generic.pnpm_12`) and the shape generalizes
to any versioned attribute family:

- One shared builder (`packages/pnpm/lib/mkMajor.nix`) takes the major as an
  argument; the per-major files are two-line delegations. They exist because
  each major needs its own path for `--override-filename` in owner
  `registry.nix` and its own sidecar beside it — not because the logic differs.
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
- **A shared builder is only correct while every major is the SAME KIND of
  artifact.** The moment upstream changes its distribution model, the newest
  major stops being expressible as an override of the old one and has to leave
  the family. `pnpm_12` is that case and is deliberately not a `pnpm-major.nix`
  caller: through pnpm 11 the npm `pnpm` package WAS pnpm (a JavaScript bundle
  at `dist/pnpm.cjs`, then `dist/pnpm.mjs`), and in 12 the published tarball's
  `package/pnpm` is a placeholder TEXT FILE whose contents say the native binary
  replaces it at install time. The implementation now ships as eight
  per-platform npm packages (`@pnpm/exe.linux-x64`, `@pnpm/exe.darwin-arm64`, …)
  pinned in `optionalDependencies`, so `pnpm_12` is a standalone prebuilt-binary
  derivation on the
  `packages/chatgpt-codex/packages/ai/chatgpt-codex/package.nix` shape with a
  per-platform sidecar like
  `packages/bun/packages/ai/generic/bun/package.nix`'s.
- **Two signals say the family has to split, and the second one is the trap.**
  The first is that nixpkgs has no attribute for the new major to override —
  easy to spot, since the overlay simply fails to evaluate. The second is that
  nixpkgs' own generic expression cannot build the new major EITHER, so reaching
  past the missing attribute and calling that expression directly looks like the
  escape hatch and is not one. For pnpm 12 its `postUnpack` runs
  `rm -r package/dist/reflink.*node package/dist/vendor` against a tarball that
  ships neither path, and its `installPhase` would then symlink the Corepack
  entry `bin/pnpm.mjs`, which only SPAWNS a native binary that is not in the
  closure. Check the second signal before writing a `callPackage` against a
  nixpkgs-internal path.
- **Version lockstep across the split artifacts is the wrapper's to declare.**
  Read the version from the package the release actually tracks, not from the
  per-platform ones. `@pnpm/exe.linux-x64`'s own `dist-tags.latest` reads 12.0.0
  while 12.2.1 is published and pinned by the wrapper's `optionalDependencies`,
  so a version check pointed at the platform package would pin the attribute
  backwards.

Rust packages on this pattern have one extra constraint. `ghArchiveUpdateScript`
refreshes only the src hash in the sidecar, so an inline `cargoHash` would go
stale on every bump — the known transitive-hash gap. Override `cargoDeps` with
`rustPlatform.importCargoLock { lockFile = "${src}/Cargo.lock"; }` against the
PINNED src instead, so one hash covers both and the vendor set self-updates.

### Go packages: the vendorHash goes in the SIDECAR

Go has the same transitive-hash problem and no `importCargoLock` equivalent —
`go.sum` records module hashes, not a Nix-fetchable vendor tree — so
`vendorHash` must be recorded somewhere. It goes in the sidecar (`beads`, its
nested paired Dolt, `gh`, `glab`, `gluetun`, `oh-my-posh`, `otel-tui`), never
inline, and the mechanism is worth understanding before touching it:

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
  `lib/packaging.nix` claimed a re-run that did not exist; if you unwire it, fix
  both.
- `passthru` must be MERGED. `buildGoModule` hangs `goModules` and
  `overrideModAttrs` there, `build-support/go/module.nix` warns loudly when an
  overlay drops them, and the fixer resolves `.goModules` through that very
  attrset.

Beads is the one grouped owner. Its public `fixVendorHash` runs the normal Beads
and nested Dolt fixers in sequence, so an input bump repairs both sidecars
before retrying the package build. Its public `updateScript` likewise runs two
ordinary `ghArchiveUpdateScript` children. Each child performs its own
latest-version check, so a Dolt-only release does not wait for a Beads release;
the grouping is at the target/branch/PR boundary, not at upstream change
detection. The Dolt helper paths use `beads.dolt` through the flake package,
which is the exact dependency nixpkgs' inherited Beads wrapper puts on `PATH`.

### The update chain of a sidecar-pinned Go package is generated, not written

`vu.mkGoUpdateExtract` emits the whole `extraExtract` chain in the one legal
order, and every Go overlay calls it instead of composing fixers by hand:

    [src fixer] -> floor fixer -> guard -> vendor fixer -> [extraAfter]

**Both edges are real, and the second one is the one that was missing.** The
vendor fixer builds `goModules`, which COMPILES Go under the toolchain
`goToolchainForFloor` picks from the sidecar's `goFloor` — and the floor fixer
is what writes that key. `mkUpdateScript`'s `buildCandidate` rebuilds the
sidecar from scratch (`jq -n '{version: $v}'`), so during `extraExtract` the
floor is not stale, it is **absent**; it reads as `goFloorUnknown` ("0"), which
every toolchain satisfies, so the selector returns `ourGo`. Until 2026-09-01 all
seven chains hand-wrote `fixVendorHash` then `fixGoFloor`, so a release raising
its go.mod floor past our pin died inside the vendor fixer with
`go.mod requires go >= X` before the floor fixer that would have fixed it ever
ran. glab 1.116.0 and oh-my-posh 31.1.x (both `go 1.27.0`, against `pkgs.go`
1.26.7) were held back on every sweep for it.

Note what is NOT a fix: preserving `goFloor` across the sidecar rewrite. The
committed floors were 1.26.5 and 1.26.0 and **both still select 1.26.7**. Only
deriving the floor from the fresh source before the vendor build changes the
outcome. `checks/packaging/go-floor-extract-order.nix` gates the order, with a
positive control, and fails a package that carries `fixGoFloor` but no
`goUpdateExtract` — i.e. one that went back to hand-rolling the chain.

`glab` is the one Go package where the SRC hash goes in the sidecar too, so it
is the only `srcFromSidecar = true` caller. The reason is the one that also
keeps bruno off the plain prefetch path: nixpkgs' `glab` fetches with
`leaveDotGit = true` and a `postFetch` that records the short commit into
`COMMIT` and then strips `.git`, so the recorded hash is over the
POST-`postFetch` tree and `nix-prefetch-url --unpack` cannot reproduce it. It
pairs `platforms = {}` with a chain that restores `srcHash`, derives the floor,
then restores `vendorHash` — all three edges forced, which is precisely what the
old welded `mkGoSrcVendorFix` (src+vendor in ONE script) could not express.

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

The hash fixers (`mkGoVendorFix`, `mkNpmDepsFix`, and the src-only fixer
`mkGoUpdateExtract` builds internally) are one body — `vu.mkHashFix` —
parameterized by an ordered list of `hashFixTargets` entries, each a
`(attrPath, drvPattern, key)` triple. Add a target to that attrset rather than
open-coding a fourth `writeShellScript`; the derivation-name patterns are
load-bearing (see `fodHashFixFn`) and a copy is how they drift.

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
sorts `1.27rc1` ABOVE `1.27.0`. `checks/packaging/go-toolchain-floor.nix`
exercises all three branches plus two positive controls, which is also what
keeps the input from shipping dormant.

**ALL EIGHT exported Go packages carry the seam**, not just the two that once
needed it — `beads`, `gh`, `glab`, `github-mcp`, `gluetun`,
`mcp-language-server`, `oh-my-posh`, `otel-tui`. Beads' nested paired Dolt
derivation carries it too; its floor is checked by the Beads contract because
the top-level discovery check intentionally enumerates exported packages.
Scoping it to "whatever broke most recently" is how the same defect gets
rediscovered per package: when `glab` broke, `gh` had ALREADY silently required
Go >= 1.26.5 and would have been next.

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
  targets in owner `registry.nix`), so there is no repo-owned update script to
  hook a rewrite into.

**ORDER: hash fixers first, then the floor.** `mkGoFloorFix` builds `.src`, so a
package whose `srcHash` also lives in the sidecar (`glab`) must have that
restored first. For `glab` the floor then precedes `mkExtractRegen`, because the
schema dump compiles the module and needs the toolchain the fresh floor selects.

Reading the floor is **silent by construction** — overlays read
`sources.goFloor or vu.goFloorUnknown`, and `goFloorUnknown` (`"0"`) is
satisfied by everything. That is deliberate and not a hole: `mkGoFloorFix` must
evaluate the package to build its `.src`, so a `throw` on the missing key would
deadlock the fixer that repairs it. `checks/packaging/go-floor-drift.nix` is the
loud half — it compares every recorded floor against the real go.mod and fails
naming the package, the actual requirement, and the remedy (fixer vs. literal).

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
evaluates every system) and the required darwin CI leg do. So the recipe's
sibling `platforms.nix` declares `["x86_64-linux"]`. Native discovery excludes
the leaf on other systems, from both scopes and outputs.

Two registries have to agree with that:
`config.checks.cacheHitParity.<name>.platforms` (or the check aborts on darwin
looking up a package that is not there) and, if a future case needs it, anything
else that enumerates packages per system. This is the exception, not a licence
to platform-gate anything inconvenient. Before adding a `platforms.nix`
restriction, prove the package genuinely cannot build on the excluded system, as
`gluetun` was proved by cross-compiling `GOOS=darwin GOARCH=arm64`. A sidecar
whose per-system keys omit a system the upstream release actually ships for is a
STALE SIDECAR: add the missing `{url, hash}` entry and the matching
`config.checks.cacheHitParity.<name>.platforms` row, do not gate the attribute.

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

## Recipe and overlay signatures

Native package recipes take named arguments, for example
`{pkgs, packageLib, repoPath, ...}: ...`, and return one derivation. Named
formals matter: native `callPackage` discovers dependencies with `functionArgs`;
a bare `args:` lambda receives no implicit dependencies. A multi-role owner can
use one native package as the source build and sibling recipes as selectors.

An ordinary overlay contribution is different: `overlay.nix` declares static
`claims` and an `overlay = final: prev: ...` extension. Keep claim discovery
independent of package evaluation, and let the shared composer handle ordering,
exclusive ownership, and consumer policy. Package recipes do not use the former
three-argument overlay curry.
