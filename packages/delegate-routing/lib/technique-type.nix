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
    launchRoute = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether a launch route may name this technique; false for one that pins only model aliases, which cannot take the full id or pattern a route composes.";
    };
    modelArg = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "The model value spelling this technique passes, such as \"full model id\", \"slug\" or \"modelId\"; a launch route composes it with the family's example id or match pattern, and refuses a technique that pins model and effort but leaves it empty.";
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
    pickerCommand = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          command = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "One-shot template using <model>, <effort>, <prompt-file>, <output-file> and, for Codex, <catalog-file> (a one-model tool-free catalog the helper writes), each substituted as a shell literal. The first word must be a bare executable name found on PATH; the helper skips a picker whose executable is not.";
          };
          toolFree = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether source or offline provider capture proves this command exposes no tools, including MCP and delegation. Unproven templates are unavailable.";
          };
        };
      });
      default = null;
      description = "Technique-owned bounded picker command and verified tool removal; null cannot serve as a picker.";
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
