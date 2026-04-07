## Binary Cache Maintenance

When adding or removing flake inputs, check whether the input has a
public Cachix cache. If so, add it to:

- `flake.nix` `nixConfig.extra-substituters` and
  `nixConfig.extra-trusted-public-keys`
- `devenv.nix` `cachix.pull`

Current upstream caches: `nix-agentic-tools`. The `follows` pattern
for nixpkgs is intentional — do not remove it to chase upstream cache
hits unless the input provides pre-built binaries independent of
nixpkgs.
