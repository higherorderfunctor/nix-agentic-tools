# Factory for a skill-packaging module.
#
# Declares `<name>.enable` and, when enabled, contributes skills (and optionally
# a router instruction) to the cross-ecosystem `ai.*` pools. Both backends of a
# skill package — the home-manager (user-global) module and the devenv
# (project-local) module — share this exact shape. The `ai.*` pools are
# per-`evalModules`, so each backend imports its OWN instance of this factory;
# an HM contribution is invisible to the devenv eval and vice-versa.
#
# The returned value IS a module (a function of the standard module args), so a
# backend's `modules/<backend>/default.nix` can be:
#
#   - exactly this module — `import .../mkSkillPackageModule.nix spec`
#     (living-workflow HM + devenv, stacked-workflows devenv); or
#   - `imports = [ (import .../mkSkillPackageModule.nix spec) ]` alongside extra
#     options — stacked-workflows HM, which adds its `gitPreset` on top.
#
# spec:
#   name              : option namespace; declares `<name>.enable` (string).
#   enableDescription : mkEnableOption description (string).
#   skills            : moduleArgs -> attrsOf (path | str). The skill dirs to
#                       fan out. Values may be `./` path literals (static skill
#                       trees) OR generated store-path strings (skills baked at
#                       eval, e.g. living-workflow's XDG state base) — the
#                       ai.skills fanout helpers (upstream `mkSkillEntry`, our
#                       `mkSkillEntries` / `mkDevenvSkillEntries`) materialize
#                       both as recursive directories.
#   instructions      : moduleArgs -> listOf attrs. OPTIONAL router entries for
#                       ai.instructions. Omit for single-skill packages that
#                       need no routing table (living-workflow); provide for
#                       packages shipping several sibling skills that need
#                       disambiguation (stacked-workflows).
#
# Each skill value is wrapped in `lib.mkDefault` so a consumer can override an
# individual key at normal priority.
spec: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.${spec.name};
  moduleArgs = {inherit config lib pkgs;};
in {
  options.${spec.name}.enable = lib.mkEnableOption spec.enableDescription;

  config = lib.mkIf cfg.enable {
    ai.skills = lib.mapAttrs (_: lib.mkDefault) (spec.skills moduleArgs);
    ai.instructions = lib.optionals (spec ? instructions) (spec.instructions moduleArgs);
  };
}
