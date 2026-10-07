{lib}:
lib.types.submodule {
  options = {
    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Launch or inspection command; required for external delegates.";
    };
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to render this technique.";
    };
    kind = lib.mkOption {
      type = lib.types.enum (import ./vocabulary.nix).kinds;
      description = "The technique's role.";
    };
    modes = lib.mkOption {
      type = lib.types.listOf (lib.types.enum ["acp" "headless" "interactive"]);
      default = [];
      description = "Session modes exposing this technique.";
    };
    notes = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Runtime-specific controls and constraints.";
    };
    pinsEffort = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether a delegate technique pins effort; null for inspection and usage.";
    };
    pinsModel = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether a delegate technique pins the model; null for inspection and usage.";
    };
    runsOwnSubagents = lib.mkOption {
      type = lib.types.str;
      default = "unknown";
      description = ''
        Whether a delegate launched this way can run its own subagents, with
        the mode it was observed in, such as "supported (headless)".
      '';
    };
  };
}
