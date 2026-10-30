# Semble's language knowledge, read from the drift-checked sidecar
# `packages/semble/extracted/` facts.
#
# The sidecar is read as an ordinary committed file. Never read the check's
# `passthru.extracted` derivation here: that is import-from-derivation and
# poisons evaluation for every consumer. Freshness belongs to PR CI
# and the `semble-extracted` drift check, not to evaluation.
#
# Two layers decide how Semble treats a file, and they come from different
# packages:
#
#   extensions     semble: file suffix → language name. A file whose suffix is
#                  absent is not indexed at all.
#   bundledGrammars semble-grammars: the tree-sitter parsers actually shipped.
#                  A language is parsed when its name, after semble-grammars'
#                  alias table, is bundled; every other indexed language falls
#                  back to line chunking.
#
# `contentTypes` holds the language sets behind `--content code|docs|config`.
# `code` is upstream's remainder: every extension-map language that is not
# docs, config or data. `dataLanguages` (csv, json, …) are indexed under no
# content type.
{lib}: let
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) children get load;
  inherit (load {dir = ../extracted;}) aggregate;
  bundledGrammars = get aggregate "grammars.bundled";
  contentTypes = children aggregate "contentTypes.<name>";
  dataLanguages = get aggregate "dataLanguages";
  extensions = get aggregate "extensions";
  grammarAliases = get aggregate "grammars.aliases";
  grammarsVersion = get aggregate "grammarsVersion";
  instructions = get aggregate "instructions";
  mcpTools = get aggregate "mcpTools";
  templates = get aggregate "templates";
  version = get aggregate "version";

  # attrNames de-duplicates and sorts.
  languages = builtins.attrNames (builtins.listToAttrs (map (name: {
    inherit name;
    value = null;
  }) (builtins.attrValues extensions)));
  grammarFor = language: grammarAliases.${language} or language;
in {
  inherit bundledGrammars contentTypes dataLanguages extensions grammarAliases grammarsVersion instructions languages mcpTools templates version;
  # Extension-map languages that get real tree-sitter parsing.
  parsedLanguages = builtins.filter (language: builtins.elem (grammarFor language) bundledGrammars) languages;
}
