# Generic AI-app factory (backend-agnostic record producer).
#
# Returns a pure data record describing an AI app. Backend-specific
# module functions are produced by applying `hmTransform` or
# `devenvTransform` to the record.
#
# Factory-of-factory pattern: outer call supplies package-specific
# name + shared option schemas + one delivery transformer.
# Returns a record that per-backend transformers project into
# module functions consumed by the HM / devenv module systems.
#
# Returned record shape:
#   {
#     name;                          # app identifier (used for ai.<name>.* paths)
#     transformers;                  # { markdown = <lib.ai.transformers.<ecosystem>>; }
#     defaults ? {};                 # {package?, outputPath?} — shared across backends
#     options ? {};                  # shared option declarations (both backends see these)
#     supportedPools ? [];           # normalized ai.* pools the runtime consumes.
#                                    # Unsupported per-runtime pool options are absent;
#                                    # root values for them degrade instead of fanning out.
#                                    # Same-named native options in `options` are independent.
#     contextDescription ? null;     # runtime-specific option description override
#     rulesDescription ? null;       # runtime-specific option description override
#     config ? _: {};                # ONE delivery transformer for BOTH backends;
#                                    # receives normalized pools and describes files
#                                    # and activation writers rather than lowering them.
#     hm = {
#       installPackage ? (_: cfg.package);
#                              # callback (same args as `config`) returning the
#                              #   derivation to install. OMIT to install the plain
#                              #   `cfg.package`; `null` opts out entirely. The
#                              #   transform owns the `home.packages` / `packages`
#                              #   lowering, so a factory never writes either.
#       options ? {};                # HM-only option additions
#       defaults ? {};               # HM-only default overrides
#       migrationConfig ? _: {};     # bounded cleanup outside runtime enable
#     };
#     devenv = {
#       installPackage ? (_: cfg.package);
#                              # callback (same args as `config`) returning the
#                              #   derivation to install. OMIT to install the plain
#                              #   `cfg.package`; `null` opts out entirely. The
#                              #   transform owns the `home.packages` / `packages`
#                              #   lowering, so a factory never writes either.
#       options ? {};                # devenv-only option additions
#       defaults ? {};               # devenv-only default overrides
#       migrationConfig ? _: {};     # bounded cleanup outside runtime enable
#     };
#   }
#
# The delivery transformer receives the arguments assembled in
# mkBackendTransform.nix, including `normalized` and compatibility aliases for
# its pools. Backend specs retain options, defaults, installation and bounded
# migration hooks; they cannot replace the delivery transformer.
{lib}: {
  name,
  transformers,
  defaults ? {},
  options ? {},
  supportedPools ? [],
  contextFilename ? null,
  contextDescription ? null,
  ruleModule ? null,
  rulesDescription ? null,
  config ? (_: {}),
  hm ? {},
  devenv ? {},
  # The package set the factory was built with, carried on the record so
  # backend transforms can build derivations WITHOUT taking `pkgs` as a
  # module argument.
  #
  # That distinction is load-bearing, not stylistic. A module function
  # that names `pkgs` in its formals resolves it through `_module.args`,
  # which requires `config`; a factory whose options use
  # `pkgs.formats.json` for a freeform type then closes the loop and
  # evaluation dies with "infinite recursion encountered" while
  # evaluating `_module.freeformType`. It does NOT reproduce through
  # ordinary HM evaluation, where the wrapper applies the transform to
  # its own args and `pkgs` is externally provided — only through
  # harnesses that call `lib.evalModules` directly, such as
  # `checks/modules/options-doc.nix`. Passing it as data sidesteps the module
  # argument system entirely.
  #
  # Optional so a record built without it still evaluates; features that
  # need it must degrade rather than throw.
  pkgs ? null,
}:
assert lib.assertMsg (!(hm ? config) && !(devenv ? config))
"mkAiApp: backend config callbacks are retired; declare one record-level delivery transformer";
  {
    inherit name transformers defaults options supportedPools config hm devenv pkgs;
  }
  // lib.optionalAttrs (contextFilename != null) {inherit contextFilename;}
  // lib.optionalAttrs (contextDescription != null) {inherit contextDescription;}
  // lib.optionalAttrs (ruleModule != null) {inherit ruleModule;}
  // lib.optionalAttrs (rulesDescription != null) {inherit rulesDescription;}
