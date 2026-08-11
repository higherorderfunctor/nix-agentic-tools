# Generic AI-app factory (backend-agnostic record producer).
#
# Returns a pure data record describing an AI app. Backend-specific
# module functions are produced by applying `hmTransform` or
# `devenvTransform` to the record.
#
# Factory-of-factory pattern: outer call supplies package-specific
# name + shared option schemas + per-backend config callbacks.
# Returns a record that per-backend transformers project into
# module functions consumed by the HM / devenv module systems.
#
# Returned record shape:
#   {
#     name;                          # app identifier (used for ai.<name>.* paths)
#     transformers;                  # { markdown = <lib.ai.transformers.<ecosystem>>; }
#     defaults ? {};                 # {package?, outputPath?} — shared across backends
#     options ? {};                  # shared option declarations (both backends see these)
#     supportsShell ? false;         # opt in to ai.<name>.shell + the `resolvedShell`
#                                    # callback argument. Set it ONLY when the backend
#                                    # callbacks actually deliver the value to a knob
#                                    # the runtime reads; an app that leaves it false
#                                    # gets no option at all, so a consumer setting one
#                                    # gets an eval error instead of a silent no-op.
#     hm = {
#       options ? {};                # HM-only option additions
#       defaults ? {};               # HM-only default overrides
#       config ? _: {};              # consumer callback projecting merged view → module attrs
#     };
#     devenv = {
#       options ? {};                # devenv-only option additions
#       defaults ? {};               # devenv-only default overrides
#       config ? _: {};              # consumer callback
#     };
#   }
#
# Consumer callbacks receive ONE attrset and return module config attributes
# (home.file.*, programs.claude-code.*, home.activation.*, files.*,
# claude.code.*, etc.) appropriate for their backend.
#
# That attrset is assembled in exactly one place — `customConfig` in
# `mkBackendTransform.nix` — and read it rather than trusting a list here.
# It currently carries `cfg`, `config`, every `merged*` pool,
# `resolvedShell`, `topContext`, `topHooks` and `topSettings`. This comment
# used to enumerate four of them and had silently drifted from the real
# call, which is the failure mode a second copy of the list invites; every
# callback takes `...` anyway, so a stale list here misleads without ever
# breaking a build.
_: {
  name,
  transformers,
  defaults ? {},
  options ? {},
  hm ? {},
  devenv ? {},
  # See the record-shape note above: opt-in, and only honest when the
  # backend callbacks consume `resolvedShell`.
  supportsShell ? false,
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
  # `checks/options-doc.nix`. Passing it as data sidesteps the module
  # argument system entirely.
  #
  # Optional so a record built without it still evaluates; features that
  # need it must degrade rather than throw.
  pkgs ? null,
}: {
  inherit name transformers defaults options hm devenv pkgs supportsShell;
}
