# The top-level options of the pinned kiro-cli that consume the next argv
# token, spelled every way the parser accepts: long name, short name and
# aliases. `measured` reads the `--help` table of the committed facts.
# `kiro-cli --agent acp` is a bare launch, so every scan that finds the
# subcommand (the launcher's in wrapPackage.nix and `kiro-usage exec`'s in
# usage/runtime.py) skips these options' values.
{lib}: let
  extracted = import ../../../lib/extracted/facts.nix {inherit lib;};
  spellings = option: [option.long] ++ lib.optional (option.short != null) option.short ++ option.aliases;
  # `table` is `{ "<long name>" = option record; }`, as extracted.
  valueOptions = table: lib.sort builtins.lessThan (lib.concatMap spellings (lib.filter (option: option.takesValue) (lib.attrValues table)));
in {
  inherit valueOptions;
  measured = valueOptions (extracted.children (import ./kiroAggregate.nix {inherit lib;}).aggregate "cli.options.top.<name>");
}
