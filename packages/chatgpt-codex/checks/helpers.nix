{lib, ...}: let
  codexExtracted = builtins.fromJSON (builtins.readFile ../extracted.json);

  # The value Home Manager renders into the user config.toml, read from the
  # file entry both backends share rather than from the generated store file,
  # which would be import-from-derivation inside `nix flake check`.
  hmCodexSettings = evaluated:
    evaluated.config.ai.codex.files."${evaluated.config.ai.codex.configDir}/config.toml".content.value;

  # Home Manager alone turns daemon auto-start off by default; devenv's
  # launcher runs without a daemon instead. Parity checks compare the rest.
  withHmDaemonDefault = settings:
    lib.recursiveUpdate settings {features.daemon_auto_start = false;};
in {
  inherit codexExtracted hmCodexSettings withHmDaemonDefault;
}
