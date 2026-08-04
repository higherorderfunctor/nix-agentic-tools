## IFD Patterns and Gotchas

> **Last verified:** 2026-08-03 (commit pending — records Oxlint's
> source-before-fetcher pattern for pnpm patched dependencies: patch the
> workspace metadata and lock before `fetchPnpmDeps` reads them, keeping a
> sandboxed dependency fix out of workflow-wide host policy). Prior: 2026-08-03
> (commit pending — moves glab and its committed extracted sidecar together from
> `overlays/generic/` to `overlays/dev-tools/`, preserving the eval-pure read
> and regeneration loop). Prior: 2026-08-02 (commit pending — distinguishes
> Codex's new human-reviewed reverse-coverage gate from generated-sidecar drift
> and shape checks: update automation may refresh extracted facts but cannot
> classify a new command, flag, field, maturity, or config seam). Prior:
> 2026-08-01 (commit pending — documents the sidecar SELF-HEAL loop as a loop:
> which half is the self-heal and which the backstop, that a red drift check
> reports a MECHANISM failure rather than a stale file, that it fires on the
> version-bump path ONLY so an edited extractor does not self-heal, how it
> differs from the `fix_sidecar_hashes` self-heal, and four debugging entry
> points. Names `glab` as the fourth extracted package and records that all four
> now share `vu.mkExtractRegen`; glab had no regeneration at all and proved the
> latency on PR #621). Prior: 2026-08-01 (Codex joins the extracted sidecar
> pipeline with recursive Clap help, feature-list, and bundled-model probes plus
> category-specific shape assertions). Prior: 2026-07-25 (the warm composite now
> forces `drvPath` instead of `version`, so sidecar-versioned packages are
> covered; also corrects the claim that the check job's `nix flake check`
> evaluates ALL systems, which it does not, and the devenv-test job moved to its
> own workflow). If you touch `overlays/lib.nix`, any overlay `.nix` file that
> calls `vu.mkVersion`, the shared `.github/actions/warm-ifd/action.yml`
> composite, or the warm steps that consume it in `.github/workflows/ci.yml` /
> `.github/workflows/update.yml`, and this fragment isn't updated in the same
> commit, stop and fix it.

### What is IFD in this repo

Our overlays compute package versions at eval time by reading manifest files
from fetched sources. `overlays/lib.nix` provides helpers like
`readPackageJsonVersion`, `readCargoVersion`, and `readPyprojectVersion` that
call `builtins.readFile` on paths inside a `fetchFromGitHub` output:

```nix
version = vu.mkVersion {
  upstream = vu.readPackageJsonVersion "${src}/package.json";
  inherit rev;
};
```

This is Import From Derivation (IFD): nix must realize (fetch) the
`fetchFromGitHub` derivation before evaluation can continue. The source tarball
must exist in the local nix store for eval to succeed.

### Why this matters

On a warm machine (prior builds cached), IFD is invisible. On a cold machine
(fresh CI runner, new contributor), evaluation of the flake fails with
`error: path '/nix/store/...-source.drv' is not valid` if the source derivation
hasn't been fetched.

Key properties of IFD in nix:

- **`.drv` files are machine-local.** They are NOT cached by binary substituters
  (cachix). Only build outputs are cached.
- **`fetchFromGitHub` outputs are content-addressed.** Same `rev` + `hash` =
  same store path on any machine. Once fetched, the output IS cached by
  substituters.
- **`builtins.attrNames` is lazy.** It does NOT trigger IFD. Only accessing a
  value that depends on a `builtins.readFile` inside a derivation output forces
  the fetch. This cost hours of debugging — `nix eval .#packages.x86_64-linux`
  with `builtins.attrNames` succeeds on cold runners but produces no source
  fetches.
- **`NIX_CONFIG="eval-cache = false"` does not help.** Tools like
  `nix-instantiate` (used internally by nix-update) predate the eval cache and
  are not affected by it.
- **`--allow-import-from-derivation true` is required** on nix commands when
  `restrict-eval` or sandbox settings would otherwise block IFD.

### CI warm step

The warm logic is a single composite action,
`.github/actions/warm-ifd/action.yml`, consumed by every workflow that evaluates
before it builds:

- `ci.yml` build job — `systems: ${{ matrix.system }}` (defaults: 3 retries,
  best-effort) so a transient fetch doesn't flake the per-system build eval.
- `devenv-test.yml` — `systems: x86_64-linux` (defaults). `devenv test`
  evaluates devenv.nix, which applies the repo overlays, so its eval reads the
  same IFD sources; the fetches are fixed-output, so warming via the flake fills
  the identical store paths devenv's own lock resolves to.
- `ci.yml` test job — `systems: x86_64-linux aarch64-darwin`, and the darwin
  half is NOT there because the check needs it. Plain `nix flake check` reports
  "The check omitted these incompatible systems: aarch64-darwin", and the job
  does not pass `--all-systems`, so it evaluates x86_64-linux ONLY. The repo's
  darwin coverage — evaluation included — is the required `aarch64-darwin` leg
  of the BUILD job; nothing in the check job covers it. The darwin warm entry is
  kept because IFD source fetches are system-agnostic and content-addressed, so
  it is nearly free and stays correct if `--all-systems` is ever adopted.
  Adopting it is an open operator decision, not an oversight: it changes what a
  required check does.

- `update.yml` — `systems: x86_64-linux`, `retries: "1"`,
  `best-effort: "false"`. The ninja pipeline cannot proceed without warm sources
  (nix-update crashes), so it keeps the original single-shot, fail-hard behavior
  via the inputs.

Do not reach for `--all-systems` casually — it would turn the required check red
today. Measured 2026-07-25 on a linux host:

- It only EVALUATES the foreign system; it never builds it. Verified on a
  throwaway two-system flake, where `checks.aarch64-darwin.foreign` reports
  `derivation evaluated to …drv` and the run then says `running 0 flake checks`.
  So its whole cost is evaluation.
- That cost is roughly +43s wall and a ~7.8 GB RSS ceiling for the darwin check
  set, against 36s / 6.2 GB for the linux one (282 checks, eval cache disabled,
  warm store).
- But instantiating the darwin checks on a linux host FAILS, twice over. Two
  checks perform IFD on derivations that must be BUILT for `aarch64-darwin`
  (`living-workflow-skill.drv` via
  `module-living-workflow-kiro-hm-writes-skill-dir`, and
  `stacked-workflows-skills.drv`), which a linux runner cannot do without a
  darwin builder; and `module-mcp-services-rotation-restart-entry` is a genuine
  darwin assertion failure. `builtins.tryEval` does not catch the first class,
  so they surface as hard eval errors.

Fixing those is the prerequisite. The flag is the last step, not the first.

The composite runs, per system with backoff:

```bash
nix eval --json \
  --option allow-import-from-derivation true \
  --apply 'pkgs: builtins.mapAttrs (_: p: p.drvPath or p.name or "unknown") pkgs' \
  ".#packages.${system}" >/dev/null
```

`builtins.mapAttrs` forcing `p.drvPath` puts every package through
`derivationStrict`, which forces every IFD on its path — the `builtins.readFile`
version extractors AND anything else that reads a file out of a fetched source.
The cachix daemon pushes fetched sources so subsequent evaluations (PR CI) can
substitute them. The `--apply` expression is the load-bearing detail — keep the
composite and this fragment in sync.

**It forces `drvPath` and not `version`, deliberately.** `version` only reaches
an IFD when the version is itself `readFile`-derived FROM the source; a package
versioned from a `-sources.json` sidecar resolves it out of the sidecar and
short-circuits, leaving IFD elsewhere on its path — `cargoLock.lockFile` on
`fblog` and `git-branchless` — never forced, and so never warmed. Measured on
`fblog` under `--option allow-import-from-derivation false`: `.version`
evaluates clean while `.drvPath` fails with
`cannot build '…-source.drv^out' during evaluation`, and the same split holds
for the two `--apply` expressions scoped to that one package. `drvPath` subsumes
`version` (the derivation name embeds it), so the narrower form buys nothing.

The cost is real and was measured before adopting it: eval cache disabled, warm
store, 2026-07-25 — `version` 1.2s / 0.9 GB RSS versus `drvPath` 19.2s / 3.0 GB
on `x86_64-linux`, and 23.4s / 3.8 GB for the `aarch64-darwin` set evaluated on
a linux host. Both evaluate clean: `allowUnfree` is set by `pkgsFor` so the
unfree guard does not throw, and the one genuinely Linux-only package
(`gluetun`) is gated out of the darwin attrset entirely rather than left to
throw on `drvPath`.

Note the `or` chain does NOT swallow a throwing `drvPath` — it only covers a
MISSING attribute. That is intended: a fetch failure must fail the warm so the
retry/backoff loop sees it. In `update.yml`, which runs this fail-hard, it also
means an unrelated eval error now surfaces at the warm step rather than a few
minutes later inside `nix-update`.

### Extracted sidecars are the IFD-free path — and their drift check is not a correctness gate

`mkClaudeExtract`, `mkCodexExtract`, and `mkKiroExtract` in `overlays/lib.nix`
probe a packaged binary at BUILD time (`passthru.extracted`) and emit a JSON
sidecar that is COMMITTED (`overlays/<pkg>-extracted.json`). `glab` is the
fourth such package and the odd one out: its extract is a Go program compiled
against upstream's own `internal/config.KeySchema` rather than a binary grep,
and it lives inline in `overlays/dev-tools/glab.nix`. Modules
`builtins.readFile` the committed file, never the derivation, so option surfaces
derived from a binary cost no IFD. `checks/<pkg>-extracted.nix` then compares
committed against freshly-built to catch a stale sidecar.

#### The sidecar SELF-HEAL loop, and how to debug it when it does not fire

The invariant is that a committed `*-extracted.json` always describes the
CURRENTLY pinned artifact. Nothing enforces that continuously. Two halves
cooperate, and it is worth knowing which is which before reaching for a fix:

1. **The self-heal** — `mkUpdateScript`'s `extraExtract`, which every extracted
   package supplies via the shared `vu.mkExtractRegen`. It rebuilds
   `passthru.extracted` and copies it over the committed path, so a version bump
   carries its own new sidecar and the drift check never sees a stale one.
2. **The backstop** — `checks/<pkg>-extracted.nix`, which compares committed
   against freshly-built.

So **a red drift check is not primarily "this file is stale" — it is a report
that the self-heal did not run.** Regenerating the JSON by hand turns the check
green while leaving the mechanism broken, and it will be red again on the next
bump. Fix the wiring; the file is a symptom.

**A `passthru.extracted` with no matching `extraExtract` is therefore a LATENT
bump failure**, not a cosmetic gap: it is guaranteed red the first time the
version moves, and completely silent before that. glab shipped that way and the
gap sat invisible from #560 until its first-ever bump (#621). If you add a fifth
extracted package, wire the regeneration in the same commit.

Where it runs, which is what determines when it CANNOT run: `extraExtract` is
spliced into `mkUpdateScript`'s `commitCandidate`, immediately after the sidecar
`mv`. That is on the VERSION-BUMP path only. Consequences:

- **An extract that changes with no version bump does NOT self-heal.** Editing
  the grep anchors in `mkClaudeExtract`, or glab's Go dump, moves the extracted
  output while the version stands still, so nothing regenerates and the drift
  check is the only signal. That case IS the hand-regeneration case — the
  command is in each check's failure message.
- Do not confuse this with the OTHER self-heal in this repo.
  `fix_sidecar_hashes` (`dev/scripts/update-common.sh`) re-derives a
  `vendorHash` / `npmDepsHash` invalidated by a nixpkgs or toolchain bump at an
  unchanged version, through `passthru.fixVendorHash` and friends. Hashes have
  that standalone escape hatch; extracts deliberately do not, because a changed
  extract means someone edited the extractor and should look at the diff.

Debugging entry points when a bump PR still goes red:

- **Read the emitted script**:
  `nix build .#<pkg>.updateScript --no-link --print-out-paths`, then read its
  tail. The regeneration lines are the last thing in it. Absent means the
  package never wired `extraExtract`; present means it ran and something inside
  it failed.
- **Check ordering** for a package whose extract builds from source rather than
  probing a prebuilt binary. glab is the only one today: its extract realizes
  `src` and `goModules`, which hold `lib.fakeHash` until `fixHashes` has run, so
  `mkExtractRegen` must come AFTER it. Reversed, it fails on the hash mismatch
  instead of producing a schema.
- **Check visibility of the new sources.json.** The regeneration `nix build`s
  against the dirty worktree, so flake eval only sees the just-written sidecar
  because it is a TRACKED file that has been modified. An untracked one is
  invisible to eval, and the extract would silently describe the OLD version —
  the same class of trap as "Flake Source Visibility" in the nix-standards
  fragment.
- **A green drift check but a red `checks.formatting`** means the `nix fmt` step
  is what is missing, not the extraction. See `mkExtractRegen`'s comment for why
  that pass is load-bearing rather than tidiness.

**That drift check does not tell you the extraction is CORRECT.** The update
pipeline's `extraExtract` hook regenerates the sidecar inside the same bump PR,
so an anchor that has gone stale and now matches the wrong structure is simply
committed as the new truth — and the drift check goes green over it. The sidecar
keys are module option surfaces, so the visible result is HM/devenv options
quietly out of sync with the binary.

This is not hypothetical. The model-catalog grep anchored on camelCase
`firstParty:"claude-…"`; the catalog spells that key `first_party:` inside
`provider_ids`, and the only camelCase site in the binary belongs to an
unrelated table. It matched exactly one stray id from 2.1.207 through 2.1.219,
and the `model` option missed the entire Opus 5 / Sonnet 5 / Fable 5 generation
without a single red build.

So every extractor asserts the SHAPE of what it captured, not merely that it
captured something — a non-empty guard is worthless here, because a dead anchor
still matched one token. Concretely: the effort enum requires exactly one
distinct match; the model catalog requires an id from each of the opus / sonnet
/ haiku families. Codex requires its recursive tree to retain the root and at
least 20 commands, asserts the exact sandbox and non-deprecated approval enums,
and rejects empty feature/model results. When you add a key or category, add its
shape assertion in the same commit.

Codex additionally carries a different kind of gate:
`checks/chatgpt-codex-coverage.nix` compares the generated vocabulary with the
human-authored categorical partition in
`packages/chatgpt-codex/lib/extractedCoverage.nix`. Shape checks prove the
extractor still recognizes upstream; this reverse check proves every recognized
surface has an explicit Nix disposition. Keep those sources separate. If the
update hook generated the classification too, the exact change needing review
would bless itself. Model IDs and feature names may be policy-covered rather
than copied item-for-item, but new command/flag identities, record fields,
feature maturities, and config-key extraction fail closed.

### Gotchas when adding new packages

- Package-manager dependency fetchers consume the source tree before normal
  build phases run. If a pnpm dependency needs a downstream patch, patching
  materialized `node_modules` in `preBuild` hides ownership at the final-package
  layer. Instead, use `applyPatches` to add pnpm `patchedDependencies` metadata,
  its patch file, and the corresponding lock entries to the upstream source;
  pass that same patched source to both `fetchPnpmDeps` and the final package.
  Pnpm then applies it at dependency materialization and reaches every peer
  variant. The fetcher FOD caches the original registry bytes, while the patched
  source is a separate final-derivation input that tells pnpm how to transform
  them. Its hash can still change when the fetcher mechanism changes (for
  example pnpm 10/fetcher v3 to pnpm 11/fetcher v4); that does not mean the
  dependency tarball was replaced.
- Do not regenerate a pnpm lock with a different pnpm major just to add that
  metadata. It can silently re-resolve unrelated peers and even change major
  dependency selections. Make the minimal lock edit, then prove it with
  `pnpm install --frozen-lockfile` using the exact pnpm selected by the Nix
  fetcher. Oxlint's `@napi-rs/cli` patch is the reference implementation.
- If a new overlay uses `vu.mkVersion` with a `readFile`-based version
  extractor, its source must be fetchable at eval time. The warm step handles
  this automatically for CI.
- `nix flake check` and `nix flake show` both trigger full eval, which means
  they trigger IFD. A cold machine running these commands will fetch all
  sources.
- `nix-update` internally runs `nix-instantiate`, which also triggers IFD. If
  the source isn't in the store, nix-update crashes. The update pipeline handles
  this by committing the rev+hash first, then running nix-update from a clean
  state.

### Alternatives considered and rejected

1. **Literal version strings** written by the update script (eliminates IFD).
   Loses auto-computed version feature. Would require the update script to also
   write version strings, adding another sed target per package.
2. **`passthru.version` instead of top-level `version`.** Still IFD — just moves
   where it triggers.
3. **`--impure` on CI eval.** Weakens eval purity guarantees.
