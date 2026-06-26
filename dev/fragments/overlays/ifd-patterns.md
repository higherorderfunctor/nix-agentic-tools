## IFD Patterns and Gotchas

> **Last verified:** 2026-06-26. If you touch
> `overlays/lib.nix`, any overlay `.nix` file that calls
> `vu.mkVersion`, the shared `.github/actions/warm-ifd/action.yml`
> composite, or the warm steps that consume it in
> `.github/workflows/ci.yml` / `.github/workflows/update.yml`, and
> this fragment isn't updated in the same commit, stop and fix it.

### What is IFD in this repo

Our overlays compute package versions at eval time by reading
manifest files from fetched sources. `overlays/lib.nix` provides
helpers like `readPackageJsonVersion`, `readCargoVersion`, and
`readPyprojectVersion` that call `builtins.readFile` on paths
inside a `fetchFromGitHub` output:

```nix
version = vu.mkVersion {
  upstream = vu.readPackageJsonVersion "${src}/package.json";
  inherit rev;
};
```

This is Import From Derivation (IFD): nix must realize (fetch)
the `fetchFromGitHub` derivation before evaluation can continue.
The source tarball must exist in the local nix store for eval to
succeed.

### Why this matters

On a warm machine (prior builds cached), IFD is invisible.
On a cold machine (fresh CI runner, new contributor), evaluation
of the flake fails with `error: path '/nix/store/...-source.drv'
is not valid` if the source derivation hasn't been fetched.

Key properties of IFD in nix:

- **`.drv` files are machine-local.** They are NOT cached by
  binary substituters (cachix). Only build outputs are cached.
- **`fetchFromGitHub` outputs are content-addressed.** Same
  `rev` + `hash` = same store path on any machine. Once fetched,
  the output IS cached by substituters.
- **`builtins.attrNames` is lazy.** It does NOT trigger IFD.
  Only accessing a value that depends on a `builtins.readFile`
  inside a derivation output forces the fetch. This cost hours
  of debugging — `nix eval .#packages.x86_64-linux` with
  `builtins.attrNames` succeeds on cold runners but produces
  no source fetches.
- **`NIX_CONFIG="eval-cache = false"` does not help.** Tools
  like `nix-instantiate` (used internally by nix-update) predate
  the eval cache and are not affected by it.
- **`--allow-import-from-derivation true` is required** on
  nix commands when `restrict-eval` or sandbox settings would
  otherwise block IFD.

### CI warm step

The warm logic is a single composite action,
`.github/actions/warm-ifd/action.yml`, consumed by every workflow
that evaluates before it builds:

- `ci.yml` build job — `systems: ${{ matrix.system }}` (defaults:
  3 retries, best-effort) so a transient fetch doesn't flake the
  per-system build eval.
- `ci.yml` test job — `systems: x86_64-linux aarch64-darwin`
  because `nix flake check` evaluates ALL systems on one runner; IFD
  source fetches are system-agnostic, so cross-system eval on a
  linux runner is fine.
- `update.yml` — `systems: x86_64-linux`, `retries: "1"`,
  `best-effort: "false"`. The ninja pipeline cannot proceed
  without warm sources (nix-update crashes), so it keeps the
  original single-shot, fail-hard behavior via the inputs.

The composite runs, per system with backoff:

```bash
nix eval --json \
  --option allow-import-from-derivation true \
  --apply 'pkgs: builtins.mapAttrs (n: p: p.version or p.name or "unknown") pkgs' \
  ".#packages.${system}" >/dev/null
```

`builtins.mapAttrs` with `p.version` forces evaluation of each
package's version attribute, which triggers `builtins.readFile`
on the fetched source, which triggers the fetch. The cachix
daemon pushes fetched sources so subsequent evaluations (PR CI) can
substitute them. The `--apply` expression is the load-bearing
detail — keep the composite and this fragment in sync.

### Gotchas when adding new packages

- If a new overlay uses `vu.mkVersion` with a `readFile`-based
  version extractor, its source must be fetchable at eval time.
  The warm step handles this automatically for CI.
- `nix flake check` and `nix flake show` both trigger full eval,
  which means they trigger IFD. A cold machine running these
  commands will fetch all sources.
- `nix-update` internally runs `nix-instantiate`, which also
  triggers IFD. If the source isn't in the store, nix-update
  crashes. The update pipeline handles this by committing the
  rev+hash first, then running nix-update from a clean state.

### Alternatives considered and rejected

1. **Literal version strings** written by the update script
   (eliminates IFD). Loses auto-computed version feature. Would
   require the update script to also write version strings, adding
   another sed target per package.
2. **`passthru.version` instead of top-level `version`.**
   Still IFD — just moves where it triggers.
3. **`--impure` on CI eval.** Weakens eval purity guarantees.
