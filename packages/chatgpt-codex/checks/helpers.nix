{harness, ...}: let
  inherit (harness) evalHm ownedDocument;

  codexExtracted = builtins.fromJSON (builtins.readFile ../extracted.json);

  # Codex HM settings never become a home.file source: its user config.toml is
  # a native write target, so Nix owns leaves rather than the whole file. The
  # declared value therefore travels as data inside the reconciler's store
  # plan, which is a derivation — reading it back would be
  # import-from-derivation inside `nix flake check`. `_reconciledDocuments` is
  # the eval-visible record of that same declaration, so the semantic parity
  # tests still compare the exact desired value, and they compare a VALUE
  # rather than a substring of generated shell.
  hmCodexSettings = evaluated:
    (ownedDocument "codex" "${evaluated.config.ai.codex.configDir}/config.toml" evaluated).value;

  codexSettingsActivation = config:
    (evalHm config).config.home.activation.codexSettingsReconcile.text;
in {
  inherit codexExtracted codexSettingsActivation hmCodexSettings;
}
