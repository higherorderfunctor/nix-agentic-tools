# Generic AI runtime factory (backend-agnostic record producer).
#
# Returns a pure data record describing an AI runtime, not a module. Backend-specific
# module functions are produced by applying `hmTransform` or
# `devenvTransform` to the record.
#
# Factory-of-factory pattern: outer call supplies package-specific
# name + shared option schemas + one delivery callback for both backends.
# Returns a record that per-backend transformers project into
# module functions consumed by the HM / devenv module systems.
#
# Returned record shape:
#   {
#     name;                          # app identifier (used for ai.<name>.* paths)
#     defaults ? {};                 # {package?} — shared across backends
#     options ? {};                  # shared option declarations (both backends see these)
#     supportedPools ? [];           # normalized ai.* pools the runtime consumes.
#                                    # Unsupported per-runtime pool options are absent;
#                                    # root values for them degrade instead of fanning out.
#                                    # Same-named native options in `options` are independent.
#     contextDescription ? null;     # runtime-specific option description override
#     rulesDescription ? null;       # runtime-specific option description override
#     config ? _: {};                # ONE delivery callback for BOTH backends; it
#                                    #   receives `backend` and describes delivery
#                                    #   rather than lowering it.
#     installPackage ? (_: cfg.package);
#                                    # callback (same args as `config`) returning the
#                                    #   derivation to install. OMIT to install the plain
#                                    #   `cfg.package`; `null` opts out entirely. The
#                                    #   transform owns the `home.packages` / `packages`
#                                    #   lowering, so a factory never writes either.
#     migrationConfig ? _: {};       # bounded cleanup emitted outside runtime enable
#     hm = {                         # Home Manager only; each field overrides the
#       installPackage ? <record>;   #   record-level one of the same name
#       migrationConfig ? <record>;
#       options ? {};                # HM-only option additions
#     };
#     devenv = { … };                # the same three fields, for devenv
#   }
#
# A backend spec carries no delivery callback and no defaults: delivery is
# described once, and a runtime states a per-backend difference by reading
# `backend`. The assertion below rejects any other backend key, so a record
# written against the retired per-backend seam fails instead of silently
# delivering nothing.
#
# The callbacks receive ONE attrset, assembled in exactly one place —
# `callbackArgs` in `mkBackendTransform.nix` — and read it rather than
# trusting a list here. It carries `backend`, `cfg`, `config`, `normalized`,
# every `merged*` pool, `resolvedSettings`, `resolvedShell`, `mergedContext`,
# and `topHooks`; every callback takes `...`, so a stale list here would
# mislead without ever breaking a build.
{lib}: {
  name,
  defaults ? {},
  options ? {},
  supportedPools ? [],
  contextFilename ? null,
  contextDescription ? null,
  ruleModule ? null,
  rulesDescription ? null,
  config ? null,
  # Presence matters: `null` is the documented opt-out, so an absent callback
  # is told apart from it through `args` below.
  installPackage ? null,
  migrationConfig ? null,
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
} @ args: let
  backendKeys = ["installPackage" "migrationConfig" "options"];
  checkBackend = backend: spec: let
    unknown = lib.subtractLists backendKeys (builtins.attrNames spec);
  in
    lib.assertMsg (unknown == [])
    "mkRuntime ${name}: ${backend} spec carries ${lib.concatStringsSep ", " unknown}; a backend spec takes only ${lib.concatStringsSep ", " backendKeys}. Describe delivery once in the record-level `config`, which receives `backend`.";
  unknownDefaults = lib.subtractLists ["package"] (builtins.attrNames defaults);
in
  assert checkBackend "hm" hm;
  assert checkBackend "devenv" devenv;
  assert lib.assertMsg (unknownDefaults == [])
  "mkRuntime ${name}: defaults carries ${lib.concatStringsSep ", " unknownDefaults}; it takes only `package`.";
    {
      inherit name defaults options supportedPools hm devenv pkgs;
    }
    // lib.optionalAttrs (config != null) {inherit config;}
    // lib.optionalAttrs (args ? installPackage) {inherit installPackage;}
    // lib.optionalAttrs (migrationConfig != null) {inherit migrationConfig;}
    // lib.optionalAttrs (contextFilename != null) {inherit contextFilename;}
    // lib.optionalAttrs (contextDescription != null) {inherit contextDescription;}
    // lib.optionalAttrs (ruleModule != null) {inherit ruleModule;}
    // lib.optionalAttrs (rulesDescription != null) {inherit rulesDescription;}
