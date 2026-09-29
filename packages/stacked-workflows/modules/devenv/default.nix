# Stacked-workflows devenv module — project-local scope.
#
# Delegates to the shared skill-packaging factory (lib/ai/mkSkillPackageModule):
# `ai.programs.stacked-workflows.enable = true` fans the unprefixed stack-*
# skills and the skill-routing rule into the PER-RUNTIME
# `ai.<runtime>.{skills,rules}` pools at project-local (devenv) scope —
# NOT the consumer-owned root pools, which would fan the package out beyond its
# runtime ownership. Those pools are per-`evalModules`, so this contribution is
# independent of the HM module's.
#
# Skills come from `pkgs.stacked-workflows-content.passthru.skills` — the
# deref'd, self-contained skill dirs (real reference files bundled inside each,
# so they resolve in every scope). Values are store-path strings, accepted by
# the skills fanout helpers.
#
# `stacked-workflows.gitPreset` mirrors the Home Manager option. devenv has no
# declarative repository Git-settings surface, so this module renders the shared
# preset through `files.*` and adds one include to the common repository config.
# It then initializes git-branchless before devenv installs prek's hooks.
#
# Picked up by `native devenv module discovery` in flake.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.ai.programs.stacked-workflows;
  gitPreset = config.stacked-workflows.gitPreset;
  gitSettings = import ../../lib/git-presets.nix;
  gitHooksEnabled = lib.attrByPath ["git-hooks" "enable"] false config;
  presetEnabled = cfg.enable && gitPreset != "none";
  presetPath = ".devenv/stacked-workflows.gitconfig";
  lockCommonGitState = ''
    exec {stacked_workflows_lock_fd}>"$git_common_dir/.devenv-stacked-workflows.lock"
    ${lib.getExe' pkgs.util-linux "flock"} "$stacked_workflows_lock_fd"
  '';
in {
  imports = [
    (import ../../../../lib/ai/mkSkillPackageModule.nix {
      name = "stacked-workflows";
      enableDescription = "stacked workflow skills + skill-routing rule (project-local devenv scope)";
      skills = {pkgs, ...}: pkgs.stacked-workflows-content.passthru.skills;
      rules = {
        lib,
        pkgs,
        ...
      }:
        import ../../router.nix {inherit lib pkgs;};
    })
  ];

  options.stacked-workflows.gitPreset = lib.mkOption {
    type = lib.types.enum (builtins.attrNames gitSettings);
    default = "none";
    description = ''
      Repository-local Git configuration preset for stacked workflows.

      - `"minimal"` -- required + strongly recommended settings
      - `"full"` -- all recommended settings (branchless, revise, general git)
      - `"none"` -- no Git configuration or branchless initialization

      The preset is applied only when
      `ai.programs.stacked-workflows.enable` is true. Per-runtime program
      overrides control only that runtime's skills and routing rule; they do
      not enable or disable this repository-level Git companion.

      devenv has no declarative repository Git-settings option. The module
      therefore writes a read-only config fragment with `files.*`, adds it to
      the common repository config with `include.path`, and initializes
      git-branchless before devenv installs Git hooks. Repository-local values
      override identical Home Manager values without changing the result.
    '';
  };

  config = lib.mkMerge [
    {
      tasks."stacked-workflows:git-config" = {
        description = "Reconcile the stacked-workflows Git preset in the common repository config";
        after = ["devenv:files"];
        before = lib.optional presetEnabled "stacked-workflows:branchless-init";
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          git_common_dir="$(${lib.getExe pkgs.git} -C "$DEVENV_ROOT" rev-parse --path-format=absolute --git-common-dir)"
          repository_config="$git_common_dir/config"
          preset_path="$git_common_dir/stacked-workflows.gitconfig"
          ${lockCommonGitState}

          if ${lib.boolToString presetEnabled}; then
            tmp="$(${lib.getExe' pkgs.coreutils "mktemp"} "$git_common_dir/.stacked-workflows.gitconfig.XXXXXX")"
            trap '${lib.getExe' pkgs.coreutils "rm"} -f "$tmp"' EXIT
            ${lib.getExe' pkgs.coreutils "install"} -m 0600 \
              "$DEVENV_ROOT/${presetPath}" "$tmp"
            ${lib.getExe' pkgs.coreutils "mv"} -f "$tmp" "$preset_path"
            trap - EXIT
            if ! ${lib.getExe pkgs.git} config --file "$repository_config" \
              --fixed-value --get-all include.path "$preset_path" >/dev/null; then
              ${lib.getExe pkgs.git} config --file "$repository_config" \
                --add include.path "$preset_path"
            fi
          else
            if ${lib.getExe pkgs.git} config --file "$repository_config" \
              --fixed-value --unset-all include.path "$preset_path" 2>/dev/null; then
              :
            else
              unset_status="$?"
              if [ "$unset_status" -ne 5 ]; then
                exit "$unset_status"
              fi
            fi
            ${lib.getExe' pkgs.coreutils "rm"} -f "$preset_path"
          fi
        '';
      };
    }

    (lib.mkIf presetEnabled {
      files.${presetPath}.text = lib.generators.toGitINI gitSettings.${gitPreset};

      packages = [pkgs.ai.gitTools.git-branchless];

      tasks = {
        "stacked-workflows:branchless-init" = {
          description = "Initialize git-branchless before devenv installs Git hooks";
          after = ["stacked-workflows:git-config"];
          before = lib.optional gitHooksEnabled "devenv:git-hooks:install";
          exec = ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :

            git_common_dir="$(${lib.getExe pkgs.git} -C "$DEVENV_ROOT" rev-parse --path-format=absolute --git-common-dir)"
            ${lockCommonGitState}
            if [ ! -d "$git_common_dir/branchless" ]; then
              primary_worktree="$(${lib.getExe' pkgs.coreutils "dirname"} "$git_common_dir")"
              PATH=${lib.makeBinPath [pkgs.git pkgs.ai.gitTools.git-branchless]} \
                ${lib.getExe pkgs.git} -C "$primary_worktree" branchless init
            fi
          '';
        };
      };
    })
  ];
}
