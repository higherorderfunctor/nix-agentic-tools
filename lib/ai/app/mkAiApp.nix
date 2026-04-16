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
# Consumer callbacks receive {cfg, mergedServers, mergedInstructions,
# mergedSkills} and return an attrset of module config attributes
# (home.file.*, programs.claude-code.*, home.activation.*, files.*,
# claude.code.*, etc.) appropriate for their backend.
_: {
  name,
  transformers,
  defaults ? {},
  options ? {},
  hm ? {},
  devenv ? {},
}: {
  inherit name transformers defaults options hm devenv;
}
