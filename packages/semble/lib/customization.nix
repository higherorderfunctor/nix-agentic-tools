# Semble package customization: extra grammars, path mappings and
# content-routed embedding models. Validation, the vanilla test, and the data
# baked into a customized package. Shared by `customizePackage` (direct
# callers, which throw) and the convenience module (which reports the same
# messages as assertions and warnings).
#
# A spec is `{ grammars ? []; pathMappings ? []; models ? []; defaultContent ?
# ["code"]; defaultModel ? null; }`, shaped like the module's options. Model
# entries may omit `enable` and `description`, and content may be a scalar.
{lib}: let
  contentScope = import ./contentScope.nix {inherit lib;};
  extracted = import ./extracted.nix;
  inherit (import ./contentCategories.nix) categories expand;

  # model2vec's accepted folder layouts (persistence/datamodels.py
  # FOLDER_LAYOUTS in model2vec 0.8.1). A model directory must hold every file
  # of at least one of them.
  layouts = [
    ["config.json" "model.safetensors" "tokenizer.json"]
    ["config_sentence_transformers.json" "model.safetensors" "tokenizer.json"]
    ["config_sentence_transformers.json" "0_StaticEmbedding/model.safetensors" "0_StaticEmbedding/tokenizer.json"]
  ];

  # Names semble-grammars already answers for: its bundled parsers and the
  # aliases it resolves to them. An extra grammar under one of these names
  # would never be asked for.
  bundledLanguages = extracted.bundledGrammars ++ builtins.attrNames extracted.grammarAliases;

  normalize = spec: {
    defaultContent = lib.toList (spec.defaultContent or contentScope.default);
    defaultModel = spec.defaultModel or null;
    grammars = spec.grammars or [];
    models =
      map (entry: {
        content = lib.toList (entry.content or []);
        description = entry.description or null;
        enable = entry.enable or true;
        model = entry.model or null;
      })
      (spec.models or []);
    pathMappings = spec.pathMappings or [];
  };

  enabledModels = spec: builtins.filter (entry: entry.enable) spec.models;

  layoutErrors = optionPath: model:
    lib.optional (model != null && model ? passthru.files && !(lib.any (layout: lib.all (file: lib.elem file model.passthru.files) layout) layouts)) ''
      Semble `${optionPath}` does not hold a model2vec model: its files must include one of these sets:
      ${lib.concatMapStringsSep "\n" (layout: "  - ${lib.concatStringsSep ", " layout}") layouts}
      Files given: ${lib.concatStringsSep ", " model.passthru.files}'';

  duplicates = values: lib.unique (builtins.filter (value: lib.count (other: other == value) values > 1) values);

  modelErrors = spec: let
    numbered = lib.imap1 (index: entry: entry // {inherit index;}) spec.models;
    enabled = builtins.filter (entry: entry.enable) numbered;
    scope = entry: lib.concatStringsSep " " (expand entry.content);
    entryErrors = entry: let
      path = "models.${toString entry.index}";
    in
      lib.optional (entry.model == null) "Semble `${path}.model` must be a model package."
      ++ contentScope.errors "${path}.content" entry.content
      ++ layoutErrors "${path}.model" entry.model;
    collisions = map (set: let
      indexes = map (entry: toString entry.index) (builtins.filter (entry: scope entry == set) enabled);
    in "Semble `models` entries ${lib.concatStringsSep ", " indexes} all route content `${set}`: each enabled entry needs its own content set (\"all\" counts as code config docs).")
    (duplicates (map scope enabled));
  in
    lib.concatMap entryErrors numbered
    ++ collisions
    ++ contentScope.errors "defaultContent" spec.defaultContent
    ++ layoutErrors "defaultModel" spec.defaultModel;

  grammarErrors = spec: let
    languages = map (grammar: grammar.language or "") spec.grammars;
  in
    lib.optional (lib.elem "" languages)
    "Semble `grammars` packages must expose a non-empty `language` attribute."
    ++ map (language: "Semble `grammars` language \"${language}\" appears more than once; grammar languages must be unique.")
    (duplicates (builtins.filter (language: language != "") languages))
    ++ map (language: "Semble `grammars` language \"${language}\" is already bundled with Semble (semble-grammars ${extracted.provenance.sembleGrammarsVersion}); Semble would never load the extra grammar.")
    (builtins.filter (language: lib.elem language bundledLanguages) languages);

  # A mapping may name any language Semble knows: a parsed one (bundled, an
  # alias, or a `grammars` language) or one it indexes with line chunking
  # (every extension-map language). Only unknown names are rejected.
  mappingErrors = spec: let
    known = bundledLanguages ++ extracted.languages ++ map (grammar: grammar.language or "") spec.grammars;
    patterns = lib.concatMap (mapping: mapping.patterns or []) spec.pathMappings;
  in
    lib.concatLists (lib.imap1 (index: mapping: let
      path = "pathMappings.${toString index}";
      language = mapping.language or "";
    in
      (
        if !(builtins.isString language) || language == ""
        then ["Semble `${path}.language` must be a non-empty string."]
        else
          lib.optional (!(lib.elem language known))
          "Semble `${path}.language`: \"${language}\" is not a language Semble knows. Use a bundled grammar or alias (semble-grammars ${extracted.provenance.sembleGrammarsVersion}), a language from Semble's extension map, or the language of a `grammars` package."
      )
      ++ lib.optional (!(lib.elem (mapping.content or null) categories))
      "Semble `${path}.content` must be one of code, config or docs."
      ++ lib.optional (!(builtins.isList (mapping.patterns or null) && mapping.patterns != [] && lib.all (pattern: builtins.isString pattern && pattern != "") mapping.patterns))
      "Semble `${path}.patterns` must be a non-empty list of non-empty globs.")
    spec.pathMappings)
    ++ map (pattern: "Semble `pathMappings` pattern \"${pattern}\" is listed more than once; only its first entry could ever match.")
    (duplicates (builtins.filter builtins.isString patterns));

  modelsVanilla = spec: enabledModels spec == [] && spec.defaultModel == null && expand spec.defaultContent == contentScope.default;
  grammarsVanilla = spec: spec.grammars == [] && spec.pathMappings == [];
in {
  inherit bundledLanguages expand layouts normalize;

  # Every message for a normalized spec; empty means valid.
  errors = spec: modelErrors spec ++ grammarErrors spec ++ mappingErrors spec;

  warnings = spec:
    lib.optional (enabledModels spec != [] && !(lib.any (entry: expand entry.content == expand spec.defaultContent) (enabledModels spec)))
    "Semble `models` has no entry for `defaultContent` (${lib.concatStringsSep " " (expand spec.defaultContent)}), so a plain `semble search` uses `defaultModel` and warns on every call.";

  inherit enabledModels grammarsVanilla modelsVanilla;
  isVanilla = spec: grammarsVanilla spec && modelsVanilla spec;

  # src/semble/semble_models.py: the routing table. Disabled entries are left
  # out; content is expanded so the patch compares exact sets.
  table = spec: {
    DEFAULT_CONTENT = expand spec.defaultContent;
    DEFAULT_MODEL =
      if spec.defaultModel == null
      then null
      else "${spec.defaultModel}";
    MODELS =
      map (entry: {
        content = expand entry.content;
        model = "${entry.model}";
      })
      (enabledModels spec);
  };

  # The path mappings flattened to one entry per pattern, in list order: the
  # first match wins, so the consumer's order is the precedence.
  mappingList = lib.concatMap (mapping:
    map (pattern: {
      inherit (mapping) content language;
      inherit pattern;
    })
    mapping.patterns);
}
