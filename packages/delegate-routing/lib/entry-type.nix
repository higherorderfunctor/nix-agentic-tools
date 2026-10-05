{lib}: let
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  stepType =
    aiTypes.extendSubmodule (aiTypes.optionalTextSource {
      # Workflow step maps compose across scopes after module evaluation.
      # Validate their effective content in the shared renderer instead.
      allowEmptyText = config: config ? steps;
      autoEnable = false;
      description = "delegation guidance";
      enableDefault = true;
      textType = lib.types.str;
    }) {
      options = {
        after = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Entries that precede this entry; absent or disabled names are ignored.";
        };
        before = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Entries that follow this entry; absent or disabled names are ignored.";
        };
      };
    };
  entryType = aiTypes.extendSubmodule stepType {
    options.always = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Include this guidance in the always-on router instead of the skill.";
    };
  };
  workflowType = aiTypes.extendSubmodule entryType {
    options.steps = lib.mkOption {
      type = lib.types.attrsOf stepType;
      default = {};
      description = "Named workflow steps, composed and ordered independently.";
    };
  };
in {
  inherit entryType stepType workflowType;
  options = {
    routing = lib.mkOption {
      type = lib.types.attrsOf entryType;
      default = {};
      description = "Named routing guidance; runtime names atomically replace portable names.";
    };
    workflows = lib.mkOption {
      type = lib.types.attrsOf workflowType;
      default = {};
      description = "Named workflows; runtime headers replace portable headers and steps compose by name.";
    };
  };
}
