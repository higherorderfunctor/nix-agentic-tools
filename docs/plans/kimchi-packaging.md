# Plan: package Kimchi CLI as a first-class binary package

> Status: **IMPLEMENTED** (binary package + propagation) 2026-06-22. Created:
> 2026-06-22. Branch: `refactor/ai-factory-architecture`.
>
> **Outcome:** `nix build .#kimchi` builds and runs (`--version` → 0.1.34,
> `--help` renders with theme assets). `autoPatchelfHook` repointed both ELFs
> (`bin/kimchi`, `share/kimchi/bin/proxy-helper`) at nix glibc without breaking
> the bun single-exec payload. `nix flake check` → all checks passed;
> `cache-hit-parity` byte-identical across both nixpkgs pins. Open items
> resolved: no launch-time auto-update (only an opt-in `kimchi update`
> subcommand), so **no wrapper needed**. Apache-2.0 → free → passes the unfree
> guard unwrapped. Not committed yet; staged for the stack. Note:
> `generate:repo` is pre-existing BROKEN (see `dev/tasks/generate.nix`), so
> README.md was hand-edited per its documented interim workflow. aarch64-darwin
> not built locally — CI gate.

## Goal

Add `getkimchi/kimchi` (the Kimchi coding-agent CLI) to this repo as a proper,
cache-served, auto-updated binary package — `nix build .#kimchi`,
`nix run .#kimchi`, available through the overlay as `pkgs.ai.kimchi` and
flattened to `self.packages.<system>.kimchi`.

**In scope:** the binary package + full change-propagation (overlay, sources
sidecar, update matrix, cache-hit parity, README/docs data, packaging steering
fragment).

**Explicitly deferred (Phase 2, not this plan):** making Kimchi a configurable
citizen of the `ai.*` factory (HM + devenv modules that manage Kimchi's skills /
MCP / steering / settings / permissions). See "Deferred: factory integration"
below for why and what it would take.

## Upstream facts (verified 2026-06-22, v0.1.34)

- Source: <https://github.com/getkimchi/kimchi>. Latest tag `v0.1.34` (published
  2026-06-22). TypeScript/Node project; binaries built with **bun compile**.
- Distribution: precompiled per-platform tarballs on GitHub Releases:
  `kimchi_{linux,darwin}_{amd64,arm64}.tar.gz` (+ `checksums.txt`,
  `install.sh`). We target the repo's two platforms:
  - `x86_64-linux` → `kimchi_linux_amd64.tar.gz`
  - `aarch64-darwin` → `kimchi_darwin_arm64.tar.gz`
- Tarball layout is **FHS `bin/` + `share/`**, not a lone binary:
  - `bin/kimchi` — 121 MB bun-compiled ELF, dynamically linked (NEEDED: `libc`,
    `ld-linux`, `libpthread`, `libdl`, `libm`; interpreter
    `/lib64/ld-linux-x86-64.so.2`).
  - `share/kimchi/bin/proxy-helper` — small stripped ELF (NEEDED: `libc`).
  - `share/kimchi/{theme,oauth,export-html,package.json}` — runtime resources
    resolved relative to the executable.
- License: **Apache-2.0** (root `LICENSE` + `share/kimchi/package.json`
  `"license": "Apache-2.0"`, © CAST AI Group). → **free**, so it passes
  `ensureUnfreeCheck` unwrapped (simpler than copilot/kiro, which are unfree).
- No auto-update / self-update flag found in README (unlike copilot's
  `--no-auto-update`). Treat a disable-flag wrapper as a low-risk open item to
  confirm at build time.

Prefetched SRI hashes (via `nix store prefetch-file`, to seed
`kimchi-sources.json`; will be re-canonicalized by the updateScript):

- linux_amd64: `sha256-tZZ+/LSlKYUMfBcacgot9oFe+ypIcOknDiFrG5mcnA0=`
- darwin_arm64: `sha256-GiYhlHaL/1cLmOlznwQmBVInUVrhqhS9+Ju2C4zoE+c=`

## Template

`overlays/copilot-cli.nix` is the closest existing pattern: a **standalone
`ourPkgs.stdenv.mkDerivation`** over a per-platform GitHub tarball, with a
`*-sources.json` sidecar and a `mkUpdateScript`. Kimchi differs in three ways:

1. Install must **preserve the `bin/` + `share/` tree** (copy both into `$out`),
   not `install -Dm755` a single file — the binary resolves `share/kimchi/...`
   relative to itself.
2. `autoPatchelfHook` must patch **two** ELFs on Linux (`bin/kimchi` and
   `share/kimchi/bin/proxy-helper`); `autoPatchelfHook` scans all of `$out`, so
   this is automatic once the hook + `buildInputs` are set.
3. Free license → no unfree handling.

## Work items (binary package + propagation)

### New files

1. **`overlays/kimchi.nix`** — standalone derivation. Shape:
   - `ourPkgs = import inputs.nixpkgs { inherit system; config.allowUnfree = true; }`
     (cache-hit parity rule — all build inputs via `ourPkgs`).
   - `sources = fromJSON (readFile ./kimchi-sources.json)`; select `platformSrc`
     by `system`.
   - `src = fetchurl { inherit (platformSrc) url hash; }`.
   - `sourceRoot = "."`, `dontStrip = true`.
   - `nativeBuildInputs = [makeWrapper] ++ optionals isLinux [autoPatchelfHook]`.
   - `buildInputs = optionals isLinux [stdenv.cc.cc.lib]` (covers
     libstdc++/libgcc defensively; glibc core comes from stdenv).
   - `autoPatchelfIgnoreMissingDeps = true` (bun binaries reference optional
     libs).
   - `installPhase`: `mkdir -p $out && cp -r bin share $out/` (preserve layout);
     ensure `+x` on `bin/kimchi` and `share/kimchi/bin/proxy-helper`.
   - Wrapper: only if a build-time check shows Kimchi needs an update-disable
     flag or a resource-dir env var. Default: none (the patched
     `$out/bin/kimchi` is the entry point; relative `../share` resolves
     correctly since it stays under `$out/bin`).
   - `passthru.updateScript = vu.mkUpdateScript { pname = "kimchi"; versionCheck.cmd = curl .../releases/latest | jq tag_name ltrimstr "v"; platforms = { x86_64-linux = ver: ".../v${ver}/kimchi_linux_amd64.tar.gz"; aarch64-darwin = ver: ".../v${ver}/kimchi_darwin_arm64.tar.gz"; }; pkgs = ourPkgs; }`.
   - `meta`: description "Kimchi — coding agent CLI powered by Cast AI",
     homepage `https://github.com/getkimchi/kimchi`,
     `license = lib.licenses.asl20`,
     `platforms = attrNames (removeAttrs sources ["version"])`,
     `mainProgram = "kimchi"`.

2. **`overlays/kimchi-sources.json`** —
   `{ version, aarch64-darwin:{url,hash}, x86_64-linux:{url,hash} }`. Seed with
   v0.1.34 URLs + prefetched hashes; then run the updateScript to canonicalize.

### Edits (Bucket A — all alphabetically placed)

3. **`overlays/default.nix`** — add
   `kimchi = import ./kimchi.nix { inherit inputs final; };` to `flatDrvs`
   (between `copilot-cli` and `kiro-cli`). Guard is applied automatically; free
   → unwrapped.
4. **`config/update-matrix.nix`** — under "Binary packages" add
   `kimchi = {flags = "--use-update-script --override-filename overlays/kimchi.nix";};`
   (after `copilot-cli`).
5. **`checks/cache-hit-parity.nix`** — add `"kimchi"` to `aiCliPackages` (after
   `copilot-cli`). It lives at `consumerPkgs.ai.kimchi`.
6. **`overlays/README.md`** — add a Kimchi row to the package index table.
7. **`dev/data.nix`** — add `kimchi = "Kimchi CLI";` to `aiCliDescriptions` and
   `"kimchi"` to `overlayPackages.ai-clis.packages`.

### Generated outputs (do NOT hand-edit; regenerate)

8. Regenerate front-door + steering after the data/fragment edits:
   - `devenv tasks run --mode before generate:repo` → `README.md`,
     `CONTRIBUTING.md`.
   - `devenv tasks run --mode before generate:instructions` → `AGENTS.md`
     - per-ecosystem steering (`.claude/rules`, `.github/instructions`,
       `.kiro/steering`).
   - Review the generated diffs; commit them with the source change.

### Steering fragment maintenance (mandatory per AGENTS.md)

9. **`dev/fragments/ai-clis/packaging-guide.md`** — currently describes the
   existing CLIs ("binary fetch" / "Python application"). Add Kimchi's pattern:
   bun-compiled binary + FHS `bin/`+`share/` tree + dual-ELF autoPatchelf +
   Apache-2.0/free. Update any "three CLIs" count. Then regenerate (covered by
   step 8's `generate:instructions`).

## Validation

- `git add` the new files first — **flake only sees tracked files**.
- `nix build .#kimchi` (x86_64-linux): confirm autoPatchelf patches both ELFs
  and `result/bin/kimchi --version` (or `--help`) runs and prints `0.1.34`.
  Confirm `proxy-helper` is patched (`file`/`patchelf --print-interpreter` on
  `result/share/kimchi/bin/proxy-helper`).
- `nix build .#checks.x86_64-linux.cache-hit-parity` → "ok — no drift".
- `nix flake check` (structural cross-refs + parity + module-eval + formatting).
- `treefmt` on every changed file (Nix + markdown + JSON).
- `aarch64-darwin` cannot be built on this linux-x64 host — CI covers it; note
  as a checkpoint, do not claim darwin verified locally.

## Proposed commit breakdown (stacked)

1. `feat(kimchi): package Kimchi CLI binary` — `overlays/kimchi.nix` +
   `kimchi-sources.json` + `overlays/default.nix` registration.
2. `feat(kimchi): wire update matrix + cache-hit parity` —
   `config/update-matrix.nix`, `checks/cache-hit-parity.nix`.
3. `docs(kimchi): document + propagate` — `overlays/README.md`, `dev/data.nix`,
   packaging-guide fragment, regenerated README/CONTRIBUTING/AGENTS/steering.

(Use the `/stack-*` skills for the actual stacking/submit, per repo routing
rules.)

## Open items / risks

- **Update-disable flag**: confirm at build time whether Kimchi runs an update
  check or telemetry that warrants a `makeWrapper --add-flags` / env. README
  suggests none. Low risk.
- **Resource resolution under wrapping**: if a wrapper is later needed, verify
  `share/kimchi` still resolves (set a resource-dir env if the binary uses
  `process.execPath`-relative lookup and the wrapper breaks it). Default plan
  avoids the wrapper entirely.
- **Closure size**: ~150 MB (121 MB binary). Acceptable; comparable to the other
  bundled CLIs. Cachix serves it.
- **bun specifics**: we repackage the upstream prebuilt binary, so bun's
  single-exec internals only matter for autoPatchelf (handled). No
  rebuild-from-source, no buddy-style patching.

## Deferred: factory integration (Phase 2, only if requested)

Making Kimchi a configurable `ai.*` citizen (the way claude-code / kiro are,
with declarative skills/MCP/steering/settings/permissions fanout) is a separate,
much larger effort. It would add `packages/kimchi/` (`default.nix`,
`lib/mkKimchi.nix`, `modules/{devenv,homeManager}`, `models.json`, `fragments`,
`docs`) and touch `lib/ai/*`, `lib/options-doc.nix`, `checks/module-eval.nix`,
plus the `ai.*` module fanout and its narrative docs/instructions. It first
requires reverse-engineering Kimchi's config surface (settings file format, how
it discovers skills/MCP/steering, its permissions model) — none of which is
known yet. Estimated multi-day, greenfield, like the kiro-cli factory work. Not
started here.
