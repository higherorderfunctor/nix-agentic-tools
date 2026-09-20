# How a file lands, and the one rule that decides it.
#
# The vocabulary lives here rather than in `delivery-options.nix` because the
# rule below is what produces its values: a method the rule can never return is
# a method nothing delivers.
{lib}: rec {
  methods = [
    # A real file this runtime owns and prunes, written at activation.
    "copy-ro"
    # Declared leaves inside a document the harness also writes.
    "shared"
    # The backend's own store-symlink primitive.
    "symlink"
    # Handed to another module's option instead of written here.
    "upstream"
  ];

  # A consumer fact usually holds on both backends. When it does not — Claude
  # follows a store symlink for user-global config and not for a repo-local
  # one — the fact is stated per backend instead of as a bare bool.
  factValue = backend: value:
    if lib.isAttrs value
    then value.${backend}
    else value;

  # THE RULE: `shared` for a file the harness itself rewrites, otherwise a
  # symlink, otherwise — when the consumer cannot follow one — the read-only
  # copy. A runtime states only the FACT that forces a departure from the
  # default; it never states a method and never a reason.
  byRule = {
    backend,
    facts,
    ...
  }:
    if factValue backend facts.harnessWrites
    then "shared"
    else if factValue backend facts.symlinkReadable
    then "symlink"
    else "copy-ro";
}
