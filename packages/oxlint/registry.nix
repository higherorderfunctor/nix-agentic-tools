{repoPath, ...}: {
  # oxlint overrides three hashes: src, cargoDeps (fetchCargoVendor), pnpmDeps
  # (fetchPnpmDeps). The rev-bump pre-step writes the src hash itself, and
  # `--no-src` is REQUIRED so nix-update does not then try to re-derive it.
  #
  # Since 2026-08-04 `src` is an `applyPatches` over the fetch, not the fetch
  # itself (it carries the pnpm patched-dependency metadata that
  # `fetchPnpmDeps` must see). nix-update re-derives a src hash by rebuilding
  # `pkg.src` with `outputHash = ""`, which forces FLAT hashing — and an
  # `applyPatches` output is a DIRECTORY, so the build always dies with
  # `should be a non-executable regular file since recursive hashing is not
  # enabled`. That aborts the run before either dependency hash is touched, so
  # oxlint was held back on EVERY sweep for ten days. `--no-src` skips exactly
  # that pass and leaves `update_dependency_hashes` to do the work we need.
  #
  # The failure was invisible because nix-update reports it as
  # `failed to retrieve hash when trying to update oxlint.src` — the same
  # sentence a patch conflict produces. Measured on the 2026-08-08 sweep, where
  # the patch applied cleanly (`patch_hash stamped on 8 importer + 2 snapshot
  # entries`) and the run still failed on this. Do not read that message as
  # naming a patch problem; check for this one too.
  documentation.devToolDescriptions.oxlint = "Fast JS/TS linter with type-aware (tsgo) linting and JS plugins";
  update.targets.oxlint = {
    file = repoPath ./packages/ai/devTools/oxlint/package.nix;
    flags = ["--version" "skip" "--no-src"];
    git = "https://github.com/oxc-project/oxc.git";
  };
}
