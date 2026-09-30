# The `stacked-workflows.gitPreset` values. `settings` is git-key shaped
# (./git-config*.nix); `scopedSync = true` sets `git.branchless.scopedSync`,
# which is an option rather than a key. A preset without it leaves that
# option alone.
{
  full = {
    settings = import ./git-config-full.nix;
    scopedSync = true;
  };
  minimal.settings = import ./git-config.nix;
  none.settings = {};
}
