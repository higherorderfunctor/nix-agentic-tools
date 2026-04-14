## IFD Patterns and Gotchas

> **Last verified:** 2026-04-13. If you touch
> `overlays/lib.nix`, any overlay `.nix` file that calls
> `vu.mkVersion`, or the CI eval/warm steps in
> `.github/workflows/update.yml`, and this fragment isn't updated
> in the same commit, stop and fix it.

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

The CI update workflow (`.github/workflows/update.yml`) includes
a "Warm flake eval" step that forces all IFD fetches before the
ninja pipeline runs:

```yaml
- name: Warm flake eval (prefetch all sources)
  run: |
    nix eval --json \
      --option allow-import-from-derivation true \
      --apply 'pkgs: builtins.mapAttrs (n: p: p.version or p.name or "unknown") pkgs' \
      .#packages.x86_64-linux > /dev/null
```

`builtins.mapAttrs` with `p.version` forces evaluation of each
package's version attribute, which triggers `builtins.readFile`
on the fetched source, which triggers the fetch. The cachix
daemon pushes fetched sources so subsequent evaluations (PR CI) can
substitute them.

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
