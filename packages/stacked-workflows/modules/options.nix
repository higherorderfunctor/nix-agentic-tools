# `stacked-workflows.gitPreset`, declared once for both backends.
#
# The preset is pure sugar over the `git.*` options (packages/git and the
# git tool owners). Every leaf is set with `mkDefault`, so any explicit value
# — typed, `git.settings`, or Home Manager's raw `programs.git.settings` —
# replaces it key by key:
#
#   - a tool's section (`absorb`, `branchless`, `revise`) → that tool's typed
#     `git.<section>.settings`, whole option values at `mkDefault` (the typed
#     options lower at the priority they are defined at, so the value reaches
#     git configuration still a default). A key that is not a typed option
#     fails evaluation, which is the check that preset data and the census
#     agree;
#   - every other key → `git.settings`, `mkDefault` per leaf;
#   - `scopedSync` → `git.branchless.scopedSync`;
#   - and it enables the three tools (`mkDefault`), which installs them and,
#     on devenv, runs `git branchless init`.
#
# It applies only while `ai.programs.stacked-workflows.enable` is true.
# Per-runtime program overrides control only that runtime's skills and
# routing rule, not this. The `pull.ff` assertion is shared too: both
# backends expose the merged `git.settings`.
{lib}: {
  config,
  options,
  ...
}: let
  presets = import ../lib/git-presets.nix;
  tools = ["absorb" "branchless" "revise"];
  preset = presets.${config.stacked-workflows.gitPreset};
  active = config.ai.programs.stacked-workflows.enable && config.stacked-workflows.gitPreset != "none";

  # mkDefault on each OPTION's value, walking the data alongside the option
  # tree. A name the tree lacks is passed through as-is, so the module system
  # reports it as an undeclared option.
  mkDefaultOptions = opts:
    lib.mapAttrs (name: value:
      if opts ? ${name} && lib.isOption opts.${name}
      then lib.mkDefault value
      else if opts ? ${name} && builtins.isAttrs value
      then mkDefaultOptions opts.${name} value
      else value);
in {
  options.stacked-workflows.gitPreset = lib.mkOption {
    type = lib.types.enum (builtins.attrNames presets);
    default = "none";
    description = ''
      Git configuration preset for stacked workflows.

      - `"minimal"` -- required + strongly recommended settings
      - `"full"` -- all recommended settings (branchless, revise, general
        git) and `git.branchless.scopedSync`
      - `"none"` -- nothing

      The preset only sets `mkDefault` values on the `git.*` options and
      enables `git.branchless`, `git.absorb` and `git.revise`; each backend
      delivers `git.*` as it always does (Home Manager user-global through
      `programs.git.settings`, devenv as a repository-local include). Override
      any key at normal priority through the typed option, `git.settings`, or
      Home Manager's `programs.git.settings`.

      It applies only while `ai.programs.stacked-workflows.enable` is true.
      Per-runtime program overrides control only that runtime's skills and
      routing rule; they do not enable or disable this Git companion.
    '';
  };

  # `pull.ff = "only"` takes priority over `pull.rebase = true` since Git
  # 2.34, so `git pull` fails whenever local commits exist. `git.settings` is
  # the merged attrset on both backends (on Home Manager it reads
  # `programs.git.settings`).
  config.assertions = [
    {
      assertion = !(active && lib.attrByPath ["pull" "ff"] null config.git.settings != null);
      message = ''
        git.settings.pull.ff (programs.git.settings.pull.ff on Home Manager)
        conflicts with stacked-workflows.gitPreset.

        Since Git 2.34, pull.ff = "only" takes priority over
        pull.rebase = true, causing "git pull" to fail when local
        commits exist. Remove pull.ff from your git settings or set
        stacked-workflows.gitPreset = "none".
      '';
    }
  ];

  config.git = lib.mkIf active (lib.mkMerge [
    (lib.genAttrs tools (section: {
      enable = lib.mkDefault true;
      settings = mkDefaultOptions options.git.${section}.settings (preset.settings.${section} or {});
    }))
    {
      settings = lib.mapAttrsRecursive (_: lib.mkDefault) (removeAttrs preset.settings tools);
      branchless.scopedSync = lib.mkIf (preset.scopedSync or false) (lib.mkDefault true);
    }
  ]);
}
