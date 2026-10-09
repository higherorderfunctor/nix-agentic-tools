# Factory for a skill-packaging module.
#
# Uses `lib.ai.program.mkProgram` to declare
# `ai.programs.<name>.enable` plus capability-gated
# `ai.programs.<name>.runtimes.<runtime>.enable` overrides. Each resolved runtime that is
# enabled receives skills (and optionally a router rule) in its PER-RUNTIME
# `ai.<runtime>.*` pools — never in the root `ai.*` pools. See "Contributions
# land PER RUNTIME" below for why that distinction is load-bearing rather than
# stylistic.
#
# Both backends of a skill package — the home-manager (user-global) module and
# the devenv (project-local) module — share this exact shape. The `ai.*` pools
# are per-`evalModules`, so each backend imports its OWN instance of this
# factory; an HM contribution is invisible to the devenv eval and vice-versa.
#
# The returned value IS a module (a function of the standard module args), so a
# backend's `modules/<backend>/default.nix` can be:
#
#   - exactly this module — `import .../mkSkillPackageModule.nix spec`; or
#   - `imports = [ (import .../mkSkillPackageModule.nix spec) ]` alongside extra
#     modules — stacked-workflows, whose backends add the shared `gitPreset`
#     module on top.
#
# spec:
#   name              : program key; declares `ai.programs.<name>.enable`
#                       plus per-runtime overrides (string).
#   enableDescription : mkEnableOption description (string).
#   enableDefault     : default of `ai.programs.<name>.enable`. OPTIONAL;
#                       false when omitted, so a package stays opt-in. Set it
#                       true only for a package every session should carry
#                       unless the consumer turns it off.
#                       The per-runtime overrides still default to null and
#                       inherit it, so `runtimes.<runtime>.enable = false`
#                       turns a default-on program off for one runtime.
#   supportedRuntimes : runtime capability set. OPTIONAL; defaults to every
#                       registered runtime.
#   skills            : moduleArgs -> attrsOf (path | str). The skill dirs to
#                       fan out. moduleArgs includes `runtime`, the runtime
#                       being written, for per-runtime content. Callers that
#                       ignore it are unaffected. Values may be `./` path literals (static skill
#                       trees) OR generated store-path strings — the ai.skills
#                       fanout helpers materialize both forms. Most
#                       runtimes use recursive per-file links; Codex uses a
#                       whole-directory link because that is the layout its
#                       discovery scanner recognizes.
#   rules             : moduleArgs -> attrsOf rule. OPTIONAL router entries for
#                       ai.rules; moduleArgs also includes `runtime`.
#                       These are ALWAYS-LOADED in every
#                       ecosystem, so they are a per-turn tax on every session
#                       and the bar is high: provide one only for a rule that
#                       must hold BEFORE the model considers a skill at all,
#                       since that is the one thing skill-description matching
#                       cannot express. Sibling disambiguation is NOT such a
#                       reason — the descriptions already do that.
#                       stacked-workflows provides one because its skills wrap
#                       git commands a model can equally well run by hand, so
#                       "check for a skill first" has to be unconditional.
#
# ── Contributions land PER RUNTIME, never on the root pool ──
#
# `ai.programs.<name>.enable = true` enables every supported runtime by default.
# `ai.programs.<name>.runtimes.<runtime>.enable = false` disables only that runtime; a
# null override inherits the portable value through B4 `resolveOverride`.
#
# Each skill value is wrapped in `lib.mkDefault`, so a consumer can override an
# individual key at normal priority. Override skills through
# `ai.<runtime>.skills.<name>` and router rules through
# `ai.<runtime>.rules.<name>`. A same-key root consumer entry is a portable
# default: this module's per-runtime value replaces it after ordinary module
# priority has selected the value at each level. Consumers can also set the
# per-runtime skill key to null, or a rule's `enable = false`, to suppress
# the root value.
#
# Writing the ROOT pool is what this module used to do, and it is banned by
# the provenance guard in `checks/module-provenance/helpers.nix`. Root pools belong to
# consumers as portable defaults; a package write there would fan out beyond
# the package's runtime ownership and force consumers to retract it themselves.
#
# ── Two consequences of the move, both deliberate ──
#
# 1. THE WRITE IS GATED ON OPTION PRESENCE. A per-runtime write requires that
#    runtime's module to be in the SAME evaluation, and nothing guarantees it:
#    `flake.nix` collects every facet so the published module set has all five,
#    but a consumer importing modules individually may have fewer. Writing
#    an undeclared option is an eval error, so the fanout is filtered by what
#    is actually declared.
spec: {
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  moduleArgs = {inherit config lib pkgs;};
  programFactory = import ./program.nix {inherit lib;};
  program = programFactory.mkProgram {
    inherit (spec) name;
    supportedRuntimes = spec.supportedRuntimes or (import ./runtimes.nix);
    options.enable =
      lib.mkEnableOption spec.enableDescription
      // {default = spec.enableDefault or false;};
  };

  skillEntries = runtime: lib.mapAttrs (_: lib.mkDefault) (spec.skills (moduleArgs // {inherit runtime;}));
  ruleEntries = runtime: lib.mapAttrs (_: lib.mkDefault) ((spec.rules or (_: {})) (moduleArgs // {inherit runtime;}));

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
    program.supportedRuntimes;
  presentRuleRuntimes =
    lib.filter
    (runtime: lib.hasAttrByPath ["ai" runtime "rules"] options)
    program.supportedRuntimes;
in {
  imports = [program.module];

  config.ai = lib.mkMerge [
    (lib.genAttrs presentSkillRuntimes (runtime:
      lib.mkIf (program.resolve config runtime).enable {
        skills = skillEntries runtime;
      }))
    (lib.genAttrs presentRuleRuntimes (runtime:
      lib.mkIf (program.resolve config runtime).enable {
        rules = ruleEntries runtime;
      }))
  ];
}
