## IFD Patterns and Gotchas

> **Last verified:** 2026-09-20 — `fix_sidecar_hashes` also repairs
> `pnpmDepsHash`; Oxlint uses a name-only pnpm patch with behavioral
> verification, with version and calendar gates retired.
>
> **Settled — do not relitigate.** Full lineage:
> `git show 52e86965:dev/fragments/overlays/ifd-patterns.md`.
>
> - **The pnpm 12 swap inside the fetcher stays deferred.** It was attempted and
>   blocked: nixpkgs' fetcher passes an empty registry base, which pnpm 12 does
>   not tolerate. Packaging the major is not the same as making it usable as a
>   fetcher argument, and `checks/packaging/pnpm-fetcher-parity.nix` enumerates
>   only packages that already ship a `pnpmDeps`, so nothing exercised the pair.
> - **An empty capture can be the ANSWER, not a dead anchor.** Demand a
>   non-empty result only where absence is impossible. Where a mechanism can
>   legitimately not exist, assert instead on the thing proving the probe COULD
>   have answered, and let the category be empty — the section below has the
>   worked case.

### What is IFD in this repo

Our overlays compute package versions at eval time by reading manifest files
from fetched sources. `lib/packaging.nix` provides helpers like
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

- `ci.yml` build-packages job — `systems: ${{ matrix.system }}` (defaults: 3
  retries, best-effort) so a transient fetch doesn't flake the per-system build
  eval.
- `devenv-test.yml` — manual-only, `systems: x86_64-linux` (defaults).
  `devenv test` evaluates devenv.nix, which applies the repo overlays, so its
  eval reads the same IFD sources; the fetches are fixed-output, so warming via
  the flake fills the identical store paths devenv's own lock resolves to.
- `ci.yml` test job — `systems: x86_64-linux aarch64-darwin`, and the darwin
  half is NOT there because the check needs it. Plain `nix flake check` reports
  "The check omitted these incompatible systems: aarch64-darwin", and the job
  does not pass `--all-systems`, so it evaluates x86_64-linux ONLY. The repo's
  UNCONDITIONAL darwin coverage — evaluation included — is the required
  `aarch64-darwin` leg of the BUILD job; nothing in the check job covers it.
  (`kiro-patched`'s darwin leg is a second required darwin evaluator, but it is
  scope-gated, so it cannot be relied on for coverage.) The darwin warm entry is
  kept because IFD source fetches are system-agnostic and content-addressed, so
  it is nearly free and stays correct if `--all-systems` is ever adopted.
  Adopting it is an open operator decision, not an oversight: it changes what a
  required check does.

- `ci.yml` kiro-patched job — `systems: ${{ matrix.system }}` (defaults), gated
  on `steps.scope.outputs.needed`. It warms only what its own eval needs; it
  holds no Cachix credentials and its build deliberately drops the project cache
  from its substituters. BOTH of its matrix legs are required status checks, so
  a change to the composite's defaults lands on the merge gate here as well as
  on `build`. This bullet was missing while the list claimed to cover "every
  workflow that evaluates before it builds" — added 2026-08-14.
- `update.yml` — `systems: x86_64-linux`, `retries: "1"`,
  `best-effort: "false"`. CI matrix workers use the separate `source/` checkout
  through the action's `path` input. The update worker cannot proceed without
  warm sources (nix-update crashes), so it keeps the original single-shot,
  fail-hard behavior via the inputs.

Do not reach for `--all-systems` casually — it would turn the required check red
today. Measured 2026-07-25 on a linux host:

- It only EVALUATES the foreign system; it never builds it. Verified on a
  throwaway two-system flake, where `checks.aarch64-darwin.foreign` reports
  `derivation evaluated to …drv` and the run then says `running 0 flake checks`.
  So its whole cost is evaluation.
- That cost is roughly +43s wall and a ~7.8 GB RSS ceiling for the darwin check
  set, against 36s / 6.2 GB for the linux one (282 checks, eval cache disabled,
  warm store).
- But instantiating the darwin checks on a linux host FAILS, twice over. The
  `stacked-workflows-skills.drv` check performs IFD on a derivation that must be
  BUILT for `aarch64-darwin`, which a linux runner cannot do without a darwin
  builder; and `module-mcp-services-rotation-restart-entry` is a genuine darwin
  assertion failure. `builtins.tryEval` does not catch the first class, so they
  surface as hard eval errors.

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

`mkClaudeExtract`, `mkCodexExtract`, and `mkKiroExtract` in each CLI owner's
`lib/packaging.nix` probe a packaged binary at BUILD time (`passthru.extracted`)
and emit a JSON sidecar that is COMMITTED (`packages/<owner>/extracted.json`).
Modules `builtins.readFile` the committed file, never the derivation, so option
surfaces derived from a binary cost no IFD. `checks/<pkg>-extracted.nix` then
compares committed against freshly-built to catch a stale sidecar.

Kiro's `models` field is the exception to the binary source: it is derived from
the committed public documentation snapshot, refreshed by the update job even
without a CLI release. Its live model list requires authentication and varies by
account. See `packages/kiro-cli/docs/settings-shape.md` for the source boundary
and measured exclusions.

**Two of the four are no longer greps, and that is the direction of travel.**
`glab`'s extract is a Go program compiled against upstream's own
`internal/config.KeySchema`, inline in
`packages/glab/packages/ai/devTools/glab/package.nix`. `mkClaudeExtract` unpacks
the Bun single-exec's module graph
(`packages/claude-code/extract/bununpack.py`), imports the settings chunk out of
it and calls the binary's OWN schema builder, its OWN zod→JSON-Schema converter
and its OWN `@internal` filter (`packages/claude-code/extract/census.mjs`), so
the sidecar's `settings` block is upstream's own description of itself rather
than anything this repo recognizes by eye. Everything located by that path is
located by CONTENT — never a chunk filename, a minified identifier or a byte
offset, none of which the macOS and Linux builds of one version agree on. That
is what lets ONE sidecar be committed for both platforms; the darwin `build` job
is the only place that claim is ever tested by a build.

Reach for a grep only for facts that are genuinely outside the artifact's own
schema. Two survive in `mkClaudeExtract` for exactly that reason: the launch-pin
keys are local-config keys, and the model catalog is a separate module.

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
  `mkClaudeExtract`'s remaining grep anchors or its census walker, or glab's Go
  dump, moves the extracted output while the version stands still, so nothing
  regenerates and the drift check is the only signal. That case IS the
  hand-regeneration case — the command is in each check's failure message.
- Do not confuse this with the OTHER self-heal in this repo.
  `fix_sidecar_hashes` (`dev/scripts/update-common.sh`) re-derives a
  `vendorHash`, `npmDepsHash` or `pnpmDepsHash` invalidated by a nixpkgs or
  toolchain bump at an unchanged version, through `passthru.fixVendorHash`,
  `passthru.fixNpmDepsHash` and `passthru.fixPnpmDepsHash`. Hashes have that
  standalone escape hatch; extracts deliberately do not, because a changed
  extract means someone edited the extractor and should look at the diff.

Debugging entry points when a bump PR still goes red:

- **Read the emitted script**:
  `nix build .#<pkg>.updateScript --no-link --print-out-paths`, then read its
  tail. The regeneration lines are the last thing in it. Absent means the
  package never wired `extraExtract`; present means it ran and something inside
  it failed.
- **Check ordering** for a package whose extract builds from source rather than
  probing a prebuilt binary. glab is the only one today: its extract realizes
  `src` and `goModules`, which hold `lib.fakeHash` until the src and vendor
  fixers have run, so `mkExtractRegen` must come AFTER them — it is passed as
  `mkGoUpdateExtract`'s `extraAfter` for exactly that reason. Reversed, it fails
  on the hash mismatch instead of producing a schema.
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
distinct match (now `census.mjs`'s `effortLevelEnumsSeen`, asserted in the
extract body rather than by a grep's match count); the model catalog requires an
id from each of the opus / sonnet / haiku families; the settings census requires
at least 100 public keys, because a schema builder that runs and returns almost
nothing is the same defect as a dead anchor. Codex requires its recursive tree
to retain the root and at least 20 commands, asserts the exact sandbox enum and
the exact approval enum for the pinned version, and rejects empty feature/model
results. The version qualification is narrow rather than an either-set
allowance: releases before 0.149.0 require `untrusted`, while 0.149.0 and newer
reject it, matching upstream's explicit removal. When you add a key or category,
add its shape assertion in the same commit.

#### But sometimes an empty capture is the ANSWER, not a dead anchor

The rule above says a non-empty guard is worthless. It does not say every
extractor must demand a non-empty result, and kiro's
`workspaceOverridableSettings` is the case that separates the two.

That field lists the `cli.json` keys a project-local settings file may override.
The mechanism is NEW in kiro-cli 2.21.1: measured across the store, 2.18.1,
2.19.0, 2.20.2 and 2.21.0 carry no such set and no workspace-merge code at all,
so for those releases the honest answer is "this kiro honors no workspace
override" — an empty list, not a failure. Hard-failing there would wedge the
update pipeline the first time upstream reverted a release-old mechanism, which
is a merge-blocking liability rather than a signal.

So when a captured category can legitimately be absent, assert on the thing that
proves the probe COULD have answered, and let the category itself be empty:

- kiro's probe fails if the bundle's `SCREAMING -> "dotted.key"` settings
  registry has no `CHAT_DEFAULT_MODEL` entry. That registry is what the members
  resolve through, so its absence means the JS payload is not what we think it
  is and "no allowlist" would be a guess.
- It fails on MORE than one candidate set (ambiguous — the extract describes
  one), mirroring `kiroLocateChatScript`'s own ambiguity refusal.
- It fails on a member that resolves to nothing or to two different keys. A
  PARTIAL allowlist is worse than none here, because the module uses it to
  REJECT keys: a short list rejects settings kiro actually honors.

The distinction to keep is the same one the locator draws between a location
failure and a content failure. "Upstream does not have this" and "we can no
longer tell what upstream has" are different findings, and an extractor that
collapses them into one empty list is the dead-anchor failure wearing a
different hat.

One consumer-side consequence, worth stating because it is where the empty case
actually lands: an empty allowlist makes EVERY key invalid at that scope, so the
assertion that reads it must say "this kiro honors no workspace override at all"
rather than listing the allowed keys and printing nothing.

#### An anchor can lose its TYPE information without losing its match

The shape assertions above all assume the anchor still says what it captured.
Some of them said it only because upstream's minifier happened to keep a method
name, and that is not a property you own.

claude-code 2.1.232 moved its whole settings schema off namespaced method
constructors onto bare standalone factories — the zod-mini calling convention.
Every registration changed shape, not merely spelling:

```text
2.1.222  effortLevel:w.enum(["low","medium","high","xhigh"])   ultracode:w.boolean()
2.1.232  effortLevel:Or(["low","medium","high","xhigh"])       ultracode:jt()
```

Both anchors went to ZERO matches, so this one failed loud and held the package
back — the good outcome, and the reason the sweep surfaced it at all. But the
two halves need DIFFERENT repairs, and only one of them is a regex edit:

- **The effort enum was fine.** It extracts the `[…]` payload, and the payload
  is identical in both forms, so making the `.enum` segment optional restores it
  with no loss. An anchor that validates through its PAYLOAD survives a
  calling-convention change.
- **The boolean guard was not.** It validated the type for free, out of the
  literal token `.boolean`. In the bare form `jt()` names nothing — it is
  indistinguishable at the call site from `B()` (string) or `at()` (number) — so
  the obvious repair, relaxing the anchor to `<key>:<ident>()`, silently demotes
  a type assertion to a presence check. That is the model-catalog failure mode
  arriving by a different road: the anchor keeps matching, and what it PROVES
  quietly drops to nothing.

The type was recovered by QUORUM instead — capture the constructor token per
guarded key, require all of them to resolve to exactly one and the SAME one,
then require that token to register at least 50 settings keys. It held for
thirteen releases and is now RETIRED: 2.1.245 code-split the bundle into
`chunk-*.js` modules and the quorum grep went to zero, which is where the whole
settings extraction moved off greps and onto the binary's own schema emitter.

That is the ending worth taking from this section. **Each repair bought roughly
one release cycle, and the next reshape invalidated it.** Payload-validating
anchors bought a bit more than name-validating ones, but the arms race only
actually ends when the extraction stops recognizing upstream's code and starts
CALLING it — at which point a refactor that would have broken an anchor is just
a refactor, and a genuine schema change is the only thing that can move the
sidecar.

The generalizable rule, for the anchors that must remain: **when an anchor stops
matching, ask what it was PROVING, not just what it was matching.** Restoring
the match is the easy half and can look complete while the assertion underneath
is gone. Prefer anchors that validate through an extracted payload; where the
only evidence was a name upstream chose, re-derive it from a property of the
corpus — and where the artifact can be made to describe itself, prefer that to
any anchor at all.

**A guard's diagnostic is only useful if the guard is REACHABLE.** The effort
enum's assignment was the one in `mkClaudeExtract` without a trailing `|| true`,
so a zero-match pipeline exited 1, `pipefail` promoted it, and `errexit` killed
the script at the assignment — the `matchCount` branch and its message were
unreachable in precisely the case they exist for. That is why 2.1.232 surfaced
as a bare `builder failed with exit code 1` with no `claude-extract:` line
anywhere. That particular assignment is gone with the effort grep, but the
hazard is a property of the shell, not of that anchor, so it applies to every
`$(...)` capture in every extractor: under `set -euETo pipefail` +
`inherit_errexit`, `var=$(cmd | cmd)` is FATAL, not falsy. Pair each `|| true`
with a single up-front readability check on the probed path, so "no match" stays
the only thing it can hide.

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
`packages/chatgpt-codex/checks/chatgpt-codex-coverage.nix` compares the
generated vocabulary with the human-authored categorical partition in
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
- **Repins are not patch conflicts.** Oxlint registers its patch under the
  name-only `"@napi-rs/cli"` key, so pnpm tries the same diff against each newly
  resolved version. Pnpm 11 fails incompatible patches; the package's behavioral
  probe also requires every installed peer variant to handle a synchronous
  `execFile` exception and preserve normal callback results. The probe runs
  after dependency fetching and after cached dependencies are materialized,
  before Rust compilation. Missing variants, a changed function shape, or an
  ineffective patch fail loudly.
- **Regenerate only when the content needs changing.** Use a throwaway project
  depending on the new version: `pnpm patch <pkg>@<ver> --edit-dir <dir>`, edit,
  then `pnpm patch-commit <dir>`. Keep only diff stanzas containing real `@@`
  hunks: pnpm has emitted content-free `deleted file mode` entries for unchanged
  test paths. Commit the inner diff directly as
  `packages/oxlint/patches/oxlint-napi-rs-cli.patch`; the recipe copies those
  exact bytes to the metadata path and derives the SHA-256 with
  `builtins.hashFile`. There is no outer patch, independent hash literal, or
  versioned filename to keep in sync.
- **Prove patching with the selected pnpm.** Run
  `pnpm install --frozen-lockfile` without `--ignore-workspace` (which discards
  the patch configuration), then inspect the installed peer variants.
  `checks.oxlint-napi-patch` applies the same diff to real 3.10.1 and 3.10.4
  tarballs, verifies behavior, and rejects pristine, partially patched, and
  empty peer sets. `checks.oxlint-napi-materialization` exercises the real
  offline pnpm configure hook and the production `preBuild` probe without
  compiling Rust. Full dependency fetching additionally validates pnpm's own
  application. If upstream implements the fallback, inspect and retire the patch
  when it conflicts; do not automatically skip a failed patch.

<!-- cspell:ignore andrewbranch Funtar -->

- **The pnpm MAJOR is a second, unguarded pin — and upstream moving it does NOT
  oblige this repo to follow.** Upstream's `packageManager` is the authority for
  what upstream uses: oxc went `pnpm@11.25.0` -> `pnpm@12.3.2` in the same
  window that moved the `@napi-rs/cli` catalog pin. Patch compatibility says
  nothing about the pnpm major; validate that independently.

  **Do not chase it reflexively.** As of 2026-09-08 pnpm 12 CANNOT drive
  `fetchPnpmDeps` at this nixpkgs pin, and the reason is a nixpkgs defect rather
  than anything about pnpm 12: `fetch-pnpm-deps/default.nix:149` interpolates
  `--registry="$NIX_NPM_REGISTRY"` unconditionally, and that variable has no
  default anywhere in nixpkgs — it appears only twice, both in that file. pnpm
  11 falls back to the default registry when handed an empty base; pnpm 12's
  Rust rewrite treats `""` as the base and every request becomes a relative URL.
  Measured: metadata fetches against bare paths (`/@andrewbranch%2Funtar.js`),
  ~28 minutes of retry backoff over 1004 lockfile entries, then
  `ERR_PNPM_META_FETCH_FAIL`.

  **The supply-chain banner is a symptom, and silencing it does not help.** The
  failure is preceded by `✗ Lockfile failed supply-chain policy check`, because
  pnpm's verification pass re-fetches registry metadata for every lockfile entry
  even when resolution is skipped (`minimumReleaseAge` defaults to 1440 minutes
  — since pnpm **11**, not 12). `trustLockfile` silences that pass, and measured
  with an empty registry the build then dies one stage later at the tarball
  endpoint with `relative URL without a base`. Turning off a supply-chain check
  to fix a misconfigured registry buys nothing and costs a real check.

  So oxlint deliberately stays on `pnpm_11` while upstream declares 12. Revisit
  when the nixpkgs pin carries a registry guard; the swap then needs a
  `NIX_NPM_REGISTRY` default supplied in the same change, and BOTH pnpm sites
  must move together or `checks/packaging/pnpm-fetcher-parity.nix` fails on the
  store-path mismatch. Leave `fetcherVersion = 4` alone: 4 is the maximum the
  pinned nixpkgs supports.

- **A multi-document `pnpm-lock.yaml` is fine for the awk.** pnpm 12 writes a
  leading `---` document carrying its own self-management deps
  (`packageManagerDependencies`) ahead of the real lock, and oxc's lock has that
  shape from `d198982c` on even though we build it with pnpm 11. The insert
  anchor still lands correctly — the first top-level key after `overrides:` —
  and the counters traverse both documents without false matches. Measured:
  `patch_hash stamped on 10 importer + 4 snapshot entries`. **That stderr line
  is the receipt**; its absence, or any END assertion from the awk, is the
  multi-document path failing.

- **`fetchPnpmDeps` reads `pnpm.nodejs-slim`**, via
  `pnpm-fixup-state-db.override {inherit (pnpm) nodejs-slim;}`. Any pnpm handed
  to that fetcher must carry the passthru, or evaluation dies with a bare
  `attribute 'nodejs-slim' missing` that names neither pnpm nor the fetcher.
  nixpkgs' own pnpm exposes it from `generic.nix`'s argument of the same name; a
  hand-built one does not get it for free.

  Counter-intuitive for pnpm 12, which ships as a self-contained native binary
  and needs no Node to RUN — the Node is for the fetcherVersion-4 SQLite
  state-db fixup helper, which is a JS program. So "this pnpm needs no Node" is
  true of the tool and false of the fetcher contract.

  **Packaging a pnpm major is not the same as proving it usable as a fetcher
  argument.** This was latent in
  `packages/pnpm/packages/ai/generic/pnpm_12/package.nix` from the day it was
  written: `checks/packaging/pnpm-fetcher-parity.nix` enumerates only packages
  that already ship a `pnpmDeps`, and none of them used pnpm 12, so nothing
  evaluated the combination. The passthru is not a derivation input — the
  `pnpm_12` outPath is byte-identical with and without it — so adding it is
  inert for existing consumers and cannot be validated by any build product.

  `checks/packaging/pnpm-fetcher-contract.nix` now enforces this across every
  `pnpm_<major>` the flake exposes, discovering them by name so a future major
  is covered the day it is added.

- **Apply patch metadata by key, not as lockfile hunks.** Upstream can reshuffle
  peer variants without changing the patched code.
  `packages/oxlint/src/oxlint-pnpm-patch-meta.awk` inserts the name-only patch
  key, then stamps the patch hash on resolved importer versions, snapshot keys,
  and transitive dependency references. It scopes importers separately from
  catalog metadata, covers peerless resolutions, and rejects missing coverage or
  an existing top-level `patchedDependencies` block. The source copier also
  rejects an upstream file at our patch destination. Pnpm's frozen install
  validates the resulting lock.

  **Settled — do not restore a version or calendar gate.** The September 18–20
  UTC sweeps were held back by the 3.10.1 catalog guard even though the
  unchanged diff applied to 3.10.4. The old `assertPatchTargetsPin` kept a
  versioned outer patch filename consistent with a separate version literal;
  copying a plain patch to its derived basename and hashing those bytes removes
  that disagreement by construction. Behavioral verification replaces both that
  gate and `config/oxlint-napi-patch-tripwire.json`. An upstream version change
  alone is not evidence of a broken patch.

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
- **A stale `pnpmDeps` hash SUBSTITUTES instead of failing, so a hand-driven
  repin can ship the PREVIOUS rev's dependencies.** `fetchPnpmDeps` names its
  output `${pname}-pnpm-deps` (`fetch-pnpm-deps/default.nix:77`) with no version
  in it, so the FOD store path is a function of `pname` and the DECLARED hash
  alone. Leave that hash untouched across a rev bump and any machine already
  holding the old path — cachix included — hands it straight back: no build, no
  mismatch, exit 0. Measured 2026-09-10 on the 3.9.1 repin, where
  `nix build .#…oxlint.pnpmDeps` fetched `…-oxlint-pnpm-deps` from cachix while
  the new source in fact hashes to
  `sha256-bIbBs6+QYoJsRqCV2q7enpw5UIw1ugzRJff4OUOGQ+s=`. Force the real value by
  writing a fake hash and reading `got:` — the same trick nix-update performs
  with `outputHash = ""`, which is why the sweep gets this right and a manual
  repin has to ask for it.

  `cargoDeps` cannot be masked this way: `fetchCargoVendor` names its staging
  output `${pname}-${version}-vendor-staging`, and `vu.mkVersion` puts the short
  rev in `version`, so every bump moves that path and the build always happens.

- **A patch conflict presents two layers from its cause — and it is not the only
  thing that spells itself that way.** `applyPatches` dying in `patchPhase`
  means `nix-build` never emits a hash mismatch, so nix-update reports
  `failed to retrieve hash when trying to update <pkg>.src` and the sweep
  records `HELD BACK: <pkg> (nix-update, formatter or commit failed)`. Neither
  names a patch. The real `Hunk #N FAILED` lines are in the
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
