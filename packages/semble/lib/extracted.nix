# Semble's language knowledge, read from the drift-checked sidecar
# `packages/semble/extracted.json`.
#
# The sidecar is read as an ordinary committed file. Never read the check's
# `passthru.extracted` derivation here: that is import-from-derivation and
# poisons evaluation for every consumer. Freshness belongs to the update job
# and the `semble-languages-extracted` drift check, not to evaluation.
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
let
  extracted = builtins.fromJSON (builtins.readFile ../extracted.json);
  inherit (extracted) contentTypes dataLanguages extensions provenance;
  bundledGrammars = extracted.grammars.bundled;
  grammarAliases = extracted.grammars.aliases;

  # attrNames de-duplicates and sorts.
  languages = builtins.attrNames (builtins.listToAttrs (map (name: {
    inherit name;
    value = null;
  }) (builtins.attrValues extensions)));
  grammarFor = language: grammarAliases.${language} or language;
in {
  inherit bundledGrammars contentTypes dataLanguages extensions grammarAliases languages provenance;
  # Extension-map languages that get real tree-sitter parsing.
  parsedLanguages = builtins.filter (language: builtins.elem (grammarFor language) bundledGrammars) languages;
}
