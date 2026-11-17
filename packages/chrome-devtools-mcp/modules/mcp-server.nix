{lib, ...}: let
  extracted = import ../lib/extracted.nix {inherit lib;};
in {
  meta = {
    modes = {
      stdio = "chrome-devtools-mcp";
      http = "bridge";
    };
    scope = "local";
    defaultPort = 19762;
  };

  inherit (extracted) settingsOptions;

  settingsToEnv = _cfg: _mode: {};

  settingsToArgs = cfg: _mode: extracted.settingsToArgs cfg.settings;
}
