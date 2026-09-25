# Per-key Semble embedding models: validation, the vanilla test, and the key
# table baked into a customized package. Shared by `customizePackage` (for
# direct callers) and the convenience module (which reports the same errors as
# assertions).
{lib}: let
  contentScope = import ./contentScope.nix {inherit lib;};

  keyPattern = "[a-z0-9][a-z0-9_-]*";

  # model2vec's accepted folder layouts (persistence/datamodels.py
  # FOLDER_LAYOUTS in model2vec 0.8.1). A model directory must hold every file
  # of at least one of them.
  layouts = [
    ["config.json" "model.safetensors" "tokenizer.json"]
    ["config_sentence_transformers.json" "model.safetensors" "tokenizer.json"]
    ["config_sentence_transformers.json" "0_StaticEmbedding/model.safetensors" "0_StaticEmbedding/tokenizer.json"]
  ];

  # Entries may come from the module (every field set) or from a direct
  # `customizePackage` caller (fields optional, content possibly a scalar).
  normalizeEntry = entry: {
    content = contentScope.normalize (lib.toList (entry.content or contentScope.default));
    enable = entry.enable or true;
    model = entry.model or null;
  };

  layoutErrors = optionPath: model:
    lib.optional (model != null && model ? passthru.files && !(lib.any (layout: lib.all (file: lib.elem file model.passthru.files) layout) layouts)) ''
      Semble `${optionPath}` does not hold a model2vec model: its files must include one of these sets:
      ${lib.concatMapStringsSep "\n" (layout: "  - ${lib.concatStringsSep ", " layout}") layouts}
      Files given: ${lib.concatStringsSep ", " model.passthru.files}'';
in {
  inherit keyPattern layouts;

  # Semble's own model, as the module's option evaluates an empty entry.
  builtinEntry = {
    content = contentScope.default;
    description = null;
    enable = true;
    model = null;
  };

  # `optionPath` prefixes each message, e.g. "cli.models". Reads only
  # `content`, `enable` and `model`, so an entry's description is never forced.
  errors = optionPath: models:
    lib.optional (!(models ? default))
    "Semble `${optionPath}` must keep its `default` entry; set `${optionPath}.default.enable = false` instead of removing it."
    ++ lib.optional (!(lib.any (entry: (normalizeEntry entry).enable) (lib.attrValues models)))
    "Semble `${optionPath}` must keep at least one entry enabled: with none, every CLI search fails."
    ++ lib.concatLists (lib.mapAttrsToList (key: entry: let
      normalized = normalizeEntry entry;
      entryPath = "${optionPath}.${key}";
    in
      lib.optional (builtins.match keyPattern key == null)
      "Semble `${optionPath}` key \"${key}\" must match ${keyPattern}."
      ++ contentScope.errors "${entryPath}.content" normalized.content
      ++ layoutErrors "${entryPath}.model" normalized.model)
    models);

  # True when `models` is empty or holds only Semble's built-in default
  # (enabled, no model, code content). Such a setup needs no patch.
  isVanilla = models:
    builtins.attrNames models
    == []
    || (builtins.attrNames models
      == ["default"]
      && normalizeEntry models.default
      == {
        content = contentScope.default;
        enable = true;
        model = null;
      });

  # The key table baked into src/semble/semble_models.py.
  table = lib.mapAttrs (_: entry: let
    normalized = normalizeEntry entry;
  in {
    inherit (normalized) content;
    enabled = normalized.enable;
    model =
      if normalized.model == null
      then null
      else "${normalized.model}";
  });
}
