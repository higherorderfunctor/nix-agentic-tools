# Factory for a skill-packaging module.
#
# Declares `<name>.enable` and, when enabled, contributes skills (and optionally
# a router rule) to the PER-RUNTIME `ai.<runtime>.*` pools of every
# runtime present in the evaluation — never to the root `ai.*` pools. See
# "Contributions land PER RUNTIME" below for why that distinction is load-
# bearing rather than stylistic.
#
# Both backends of a skill package — the home-manager (user-global) module and
# the devenv (project-local) module — share this exact shape. The `ai.*` pools
# are per-`evalModules`, so each backend imports its OWN instance of this
# factory; an HM contribution is invisible to the devenv eval and vice-versa.
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
#   rules             : moduleArgs -> attrsOf rule. OPTIONAL router entries for
#                       ai.rules. These are ALWAYS-LOADED in every
#                       ecosystem, so they are a per-turn tax on every session
#                       and the bar is high: provide one only for a rule that
#                       must hold BEFORE the model considers a skill at all,
#                       since that is the one thing skill-description matching
#                       cannot express. Sibling disambiguation is NOT such a
#                       reason — the descriptions already do that.
#                       living-workflow omits it (one skill, nothing a stray
#                       command reaches). stacked-workflows provides one because
#                       its skills wrap git commands a model can equally well
#                       run by hand, so "check for a skill first" has to be
#                       unconditional.
#
# ── Contributions land PER RUNTIME, never on the root pool ──
#
# Each skill value is wrapped in `lib.mkDefault`, so a consumer can override an
# individual key at normal priority. Override skills through
# `ai.<runtime>.skills.<name>` and router rules through
# `ai.<runtime>.rules.<name>` — NOT the corresponding root key, which is a hard
# evaluation error rather than an override. That is worth stating plainly
# because the failure is counter-intuitive: `mergeWithCollisionCheck`
# (lib/ai/ai-common.nix) decides collisions with `builtins.intersectAttrs`,
# which sees KEY PRESENCE and knows nothing about priorities. A consumer's
# root `mkForce` therefore does not outrank this module's `mkDefault`; it
# collides with it, and the assertion fires outside every `mkIf`, so it fires
# even for runtimes that are merely imported.
#
# Writing the ROOT pool is what this module used to do, and it is banned by
# the provenance guard in `checks/module-eval.nix`. The reason is not
# tidiness: root pools are
# ADDITIVE and cannot be retracted per runtime, so once per-runtime negation
# exists, a root contribution makes a consumer's negation evaluate perfectly
# cleanly and silently fail to negate anything.
#
# ── Two consequences of the move, both deliberate ──
#
# 1. THE WRITE IS GATED ON OPTION PRESENCE. A per-runtime write requires that
#    runtime's module to be in the SAME evaluation, and nothing guarantees it:
#    `flake.nix` collects every facet so the published module set has all five,
#    but a consumer importing modules individually may have fewer, and the
#    repo's own `devenv.nix` imports four of the five runtime modules (kimchi
#    is absent). Writing an undeclared option is an eval error, so the fanout
#    is filtered by what is actually declared.
spec: {
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  cfg = config.${spec.name};
  moduleArgs = {inherit config lib pkgs;};

  skillEntries = lib.mapAttrs (_: lib.mkDefault) (spec.skills moduleArgs);
  ruleEntries = lib.mapAttrs (_: lib.mkDefault) ((spec.rules or (_: {})) moduleArgs);

  # Runtimes whose per-runtime pools exist in THIS evaluation. Probing
  # `options` rather than a hardcoded list keeps the module honest about what
  # it can actually write to; the same shape is used by
  # `lib/ai/sharedOptions.nix` to detect Home Manager's Git surface.
  #
  # Safe against the `_module.args` recursion that this repo has hit before:
  # the per-runtime `skills` / `rules` options come from the shared
  # baseline in `lib/ai/app/mkBackendTransform.nix`, which derives its option
  # surface from the app RECORD at build time and never reads `config`.
  presentSkillRuntimes =
    lib.filter
    (runtime: lib.hasAttrByPath ["ai" runtime "skills"] options)
    (import ./runtimes.nix);
  presentRuleRuntimes =
    lib.filter
    (runtime: lib.hasAttrByPath ["ai" runtime "rules"] options)
    (import ./runtimes.nix);
in {
  options.${spec.name}.enable = lib.mkEnableOption spec.enableDescription;

  config = lib.mkIf cfg.enable {
    ai = lib.mkMerge [
      (lib.genAttrs presentSkillRuntimes (_runtime: {skills = skillEntries;}))
      (lib.genAttrs presentRuleRuntimes (_runtime: {rules = ruleEntries;}))
    ];
  };
}
