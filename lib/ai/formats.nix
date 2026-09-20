# How structured content becomes bytes, as a lookup rather than a fold.
#
# A factory writes `content.value = {…}; format = "json";` and is done: the
# router calls the renderer, and nothing below the delivery layer calls
# `builtins.toJSON` again. `sharedOk` is the other half of the same table —
# whether a format names a container the reconciler can own individual leaves
# inside, which is what makes a whole-file surface whole-file by statement
# rather than by which helper a factory happened to reach for.
{
  lib,
  pkgs,
}: rec {
  # A renderer returns CONTENT, in the same two tags an entry carries: literal
  # bytes, or a store path holding them. Returning a store path for toml and
  # yaml is deliberate — reading a generated file back at evaluation is
  # import-from-derivation, which this repository does not do, and the sinks
  # take a path just as happily as a string.
  table = {
    json = {
      render = _name: value: {text = builtins.toJSON value;};
      sharedOk = true;
    };
    # Markdown bodies are composed by lib/ai/transformers/ and arrive as
    # `content.text`; there is no value shape to render here.
    markdown = {
      render = null;
      sharedOk = false;
    };
    raw = {
      render = null;
      sharedOk = false;
    };
    toml = {
      render = name: value: {source = (pkgs.formats.toml {}).generate name value;};
      sharedOk = true;
    };
    yaml = {
      render = name: value: {source = (pkgs.formats.yaml {}).generate name value;};
      sharedOk = false;
    };
  };

  # devenv has no recursive symlink primitive, so the router walks the tree
  # itself and emits one entry per leaf. This is the ONE walk: it replaced the
  # skill-entry helper, its devenv twin, and kiro's inline agents-directory
  # copy of the same recursion.
  #
  # `builtins.readDir` is type-agnostic about its argument, which is why both
  # Nix path literals and absolute path STRINGS work — a skill that comes from
  # a package is `"${pkg}/share/skill"`, and treating that as a file writes the
  # path itself as the file's content.
  walk = path: source: let
    walkDir = prefix: directory:
      lib.concatMapAttrs (
        name: kind:
          if kind == "directory"
          then walkDir "${prefix}/${name}" (directory + "/${name}")
          else if kind == "regular" || kind == "symlink"
          then {"${prefix}/${name}" = directory + "/${name}";}
          # Anything else — a socket, a device node — is not a file this layer
          # can deliver, and silently skipping it is what the helper it
          # replaced did.
          else {}
      )
      (builtins.readDir directory);
  in
    if (builtins.readFileType source) == "directory"
    then walkDir path source
    else
      throw ''
        ai delivery: "${path}" sets `recursive`, but its `content.source` is
        not a directory. A single file is delivered by naming its own path.
      '';

  # A store name for a rendered file, derived from the target path. The `ai-`
  # prefix is not decoration: a store name may not begin with a period, and
  # plenty of these paths do.
  storeName = path: "ai-delivery-" + lib.replaceStrings ["/"] ["-"] path;

  # The interpreter a writer's plan pins. `tomlkit` is what keeps comments and
  # key order in a TOML document the harness also edits; nothing else needs it,
  # and carrying it everywhere would put a package in every closure that owns a
  # JSON file.
  pythonFor = ledgers:
    if lib.any (ledger: ledger.codec == "toml") (lib.attrValues ledgers)
    then pkgs.python3.withPackages (python: [python.tomlkit])
    else pkgs.python3;

  render = {
    format,
    path,
    value,
  }:
    if table.${format}.render == null
    then
      throw ''
        ai delivery: "${path}" sets `content.value`, but format `${format}` has
        no renderer — its bytes come from `content.text` or `content.source`.
      ''
    else table.${format}.render (storeName path) value;
}
