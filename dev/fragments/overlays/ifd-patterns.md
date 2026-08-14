## IFD Patterns and Gotchas

> **Last verified:** 2026-08-14 (commit pending — records the blocker that kept
> oxlint held back on EVERY sweep for ten days and was invisible because it
> spells itself exactly like a patch conflict: an `applyPatches` src cannot be
> re-hashed by nix-update at all, since `outputHash = ""` forces flat hashing
> over a directory, so its update row needs `--no-src`. Measured on the
> 2026-08-08 sweep, where the patch applied cleanly and the run still died. Also
> records how to regenerate the pnpm patch file when upstream repins the
> dependency, that `patchHash` is a plain sha256 of that file, and that
> `pnpm patch-commit` emits content-free stanzas needing removal). Prior:
> 2026-08-10 (commit pending — adds the LOCATE-vs-PROBE split every
> binary-probing extractor now owes its reader. `mkKiroExtract` hardcoded
> `bin/.kiro-cli-chat-wrapped`; when nixpkgs f13ff45a dissolved that name,
> twelve greps failed with "No such file or directory" and the build announced
> "upstream changed the hook-trigger vocabulary". The target is now resolved by
> CONTENT inside the builder through the shared `vu.kiroChatLocatorPy`, and a
> location failure can no longer be spelled as a content failure). Prior:
> 2026-08-04 (commit pending — the pnpm patched-dependency guidance below said
> to "make the minimal lock edit", and a minimal edit expressed as HUNKS is what
> held oxlint back in every sweep once upstream reshuffled its peer variants.
> Records that the metadata is applied by key in `postPatch` instead, and that a
> patch conflict surfaces as nix-update's "failed to retrieve hash" rather than
> as anything naming a patch). Prior: 2026-08-03 (commit pending — records
> Oxlint's source-before-fetcher pattern for pnpm patched dependencies: patch
> the workspace metadata and lock before `fetchPnpmDeps` reads them, keeping a
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

#### Separate LOCATING the artifact from PROBING it — they are different bugs

A shape assertion only helps once you are reading the right file. The step
before it — finding the binary at all — has its own failure mode, and it is the
one that gets misdiagnosed, because both failures surface as "the anchors
matched nothing".

`mkKiroExtract` took `bin = "${finalPackage}/bin/.kiro-cli-chat-wrapped"`. That
name is manufactured by `wrapProgram`, which renames the real ELF and appends
`_` on each collision, so it was already a name nobody owns. nixpkgs f13ff45a
dissolved it entirely by splitting the package (overlay-pattern fragment), and
the resulting build said:

```
grep: /nix/store/…/bin/.kiro-cli-chat-wrapped: No such file or directory   (x12)
kiro-extract: no documented trigger present in the binary
              (upstream changed the hook-trigger vocabulary)
```

**Every word after the greps was false.** Nothing was probed; the vocabulary was
never consulted. The trailing `|| true` that made "grep found no match" a
tolerated outcome also made "grep could not open the file" one. Two rules fall
out, and they apply to any extractor that probes a packaged artifact:

- **Locate by CONTENT, in the builder.** `vu.kiroChatLocatorPy` is the single
  locate rule, shared by the extractor and the rollout patcher so the probe and
  the patch cannot disagree about which file they mean. It anchors on the
  rollout-manifest key AND on a native-executable magic number — the second
  anchor is what stops a ~400-byte shell wrapper that merely mentions the key
  from being selected, which would make every trigger probe come up empty and
  fail for an invented reason. Resolving in the builder rather than at eval also
  keeps the IFD profile unchanged: `passthru.extracted` is still consumed only
  by `nix build`.
- **Classify the tool's exit status; never blanket-tolerate it.** `grep` exits 1
  for "no match" (a real, expected verdict here — it is what populates
  `documentedAbsent`) and 2 for "could not read the file". Tolerate 1, treat 2
  as fatal, and say in the message which of the two you are reporting. Every
  failure message on the locate path now states that it is a LOCATION failure
  and that nothing was probed.

The general form: **an absent anchor and an unreadable artifact must never share
a message.** They have different fixes — one is "re-derive the regex against the
binary", the other is "the package layout moved" — and a build that names the
wrong one sends the next session hunting upstream for a change that never
happened.

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
- **Regenerating the patch when upstream repins the dependency** — the one
  change the awk deliberately fails loud on. Do it with real pnpm, in a
  throwaway project depending on the new version, rather than by hand-editing
  hunks: `pnpm patch <pkg>@<ver> --edit-dir <dir>`, edit,
  `pnpm patch-commit <dir>`. Three mechanics are not guessable from the result:
  - **`patchHash` is a plain `sha256sum` of the pnpm patch file's bytes.**
    Nothing derives it from the dependency; it moves only when that file does,
    which is why the awk can stamp it by key. Verify against the current pin
    before trusting a regenerated one — the 3.8.2 file hashes to the committed
    `0a540bf5…`.
  - **`patch-commit` emits content-free stanzas that must be stripped.** For
    `@napi-rs/cli@3.8.6` it produced 37 `deleted file mode` entries for
    `__tests__` paths that exist in both the tarball and the edit dir, alongside
    the 2 real file diffs. Keep only stanzas containing an `@@` hunk. Left in,
    they are 37 more positional things to break on the next repin, for no
    behavioral change.
  - **Prove it end to end, not by eye.** Point the scratch lock at the stripped
    file's hash, `pnpm install --frozen-lockfile`, and read the patched line out
    of `node_modules/.pnpm/<pkg>@<ver>_patch_hash=…/`. A patch that parses is
    not a patch that applied.
- **Apply that metadata BY KEY in `postPatch`, never as lock hunks.** The patch
  FILE is a new file and never conflicts, but the workspace and lock entries
  pointing pnpm at it track upstream's peer resolution, which reshuffles on its
  own schedule — oxc collapsed five `@napi-rs/cli@3.8.2(…)` snapshot keys to two
  between two revs, and the six dead hunks held oxlint back in EVERY sweep until
  someone realigned them by hand. The edit carries no judgement: it inserts one
  identical `(patch_hash=…)` token wherever pnpm names the resolved dependency,
  so encoding it positionally buys nothing and costs a held-back target per
  reshuffle. `overlays/dev-tools/oxlint-pnpm-patch-meta.awk` does it by key, and
  asserts loudly on the change that IS a judgement call — the dependency moving
  off the pinned version, which invalidates both the patch target and the patch
  hash.
- **An `applyPatches` src needs `--no-src` on its nix-update row, or the sweep
  can never bump it.** nix-update re-derives a src hash by rebuilding `pkg.src`
  with `outputHash = ""`, which forces FLAT hashing; an `applyPatches` output is
  a DIRECTORY, so that build ALWAYS fails with
  `should be a non-executable regular file since recursive hashing is not enabled`
  — regardless of the patch, the rev, or anything upstream did. It aborts
  `update()` before `update_dependency_hashes` runs, so neither `cargoDeps` nor
  `pnpmDeps` is ever touched. The rev-bump pre-step already wrote the src hash,
  so nothing is lost by skipping that pass. This is a property of the SHAPE of
  `src`, so it applies the moment a package moves from a plain fetcher to
  `applyPatches` — oxlint made that move on 2026-08-04 and did not bump once in
  the following ten days.
- **A patch conflict presents two layers from its cause — and it is not the only
  thing that spells itself that way.** `applyPatches` dying in `patchPhase`
  means `nix-build` never emits a hash mismatch, so nix-update reports
  `failed to retrieve hash when trying to update <pkg>.src` and the sweep
  records `HELD BACK: <pkg> (nix-update or build failed)`. Neither names a
  patch. The real `Hunk #N FAILED` lines are in the
  `--- nix stderr (last 20 lines) ---` tail in the update job log.

  **Read that tail before concluding anything**, because the `--no-src` failure
  above produces the IDENTICAL top-level sentence, and the two can stack. On the
  2026-08-08 sweep oxlint's patch applied cleanly — the log even says
  `patch_hash stamped on 8 importer + 2 snapshot entries` — and the run still
  died on the flat-hash error underneath. By 2026-08-12 upstream had moved the
  catalog pin and the awk assertion fired FIRST, so the visible reason changed
  while the older blocker sat unfixed behind it. Fixing only the reason the
  latest log names leaves the package held back with a fresh-looking message.

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
