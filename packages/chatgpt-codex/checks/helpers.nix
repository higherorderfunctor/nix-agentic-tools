{lib, ...}: let
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) get load;
  codexFacts = load {dir = ../extracted;};
  codexGlobalFlags = get codexFacts.aggregate "cli.globalFlags";

  # The value Home Manager renders into the user config.toml, read from the
  # file entry both backends share rather than from the generated store file,
  # which would be import-from-derivation inside `nix flake check`.
  hmCodexSettings = evaluated:
    evaluated.config.ai.codex.files."${evaluated.config.ai.codex.configDir}/config.toml".content.value;

  # Home Manager renders both managed defaults in user config.toml.
  withHmDefaults = settings:
    lib.recursiveUpdate settings {
      check_for_update_on_startup = false;
      features.daemon_auto_start = false;
    };
in {
  inherit codexGlobalFlags hmCodexSettings withHmDefaults;
}
