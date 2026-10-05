{lib}: let
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  entryType =
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
        always = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Include this guidance in the always-on router instead of the skill.";
        };
        before = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Entries that follow this entry; absent or disabled names are ignored.";
        };
      };
    };
in {
  inherit entryType;
  workflowType = aiTypes.extendSubmodule entryType {
    options.steps = lib.mkOption {
      type = lib.types.attrsOf entryType;
      default = {};
      description = "Named workflow steps, composed and ordered independently.";
    };
  };
}
