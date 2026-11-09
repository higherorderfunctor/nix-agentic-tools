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
  phraseType = aiTypes.optionalTextSource {
    autoEnable = false;
    description = "skill phrase";
    enableDefault = true;
    textType = lib.types.str;
  };
  columnsOption = lib.mkOption {
    type = lib.types.attrsOf stepType;
    default = {};
    description = "Header text, order and presence of one table's columns, keyed by column; a disabled column drops its header and cells.";
  };
in {
  inherit entryType stepType workflowType;
  options = {
    routing = lib.mkOption {
      type = lib.types.attrsOf entryType;
      default = {};
      description = "Named routing guidance; runtime names atomically replace portable names.";
    };
    skill = lib.mkOption {
      type = lib.types.submodule {
        options = {
          columns = lib.mkOption {
            type = lib.types.submodule {
              options = {
                families = columnsOption;
                pools = columnsOption;
                techniques = columnsOption;
              };
            };
            default = {};
            description = "Table header text, order and presence keyed by column.";
          };
          entries = lib.mkOption {
            type = lib.types.attrsOf stepType;
            default = {};
            description = "Ordered body of the skill; text may use the {families}, {helper}, {manual}, {planner}, {pools}, {routing}, {techniques} and {workflows} placeholders, and an entry whose placeholder renders nothing is omitted.";
          };
          phrases = lib.mkOption {
            type = lib.types.attrsOf phraseType;
            default = {};
            description = "Templates used inside generated blocks; a disabled phrase renders nothing.";
          };
        };
      };
      default = {};
      description = "Skill text: body entries, table columns and phrases; runtime keys replace portable keys atomically.";
    };
    workflows = lib.mkOption {
      type = lib.types.attrsOf workflowType;
      default = {};
      description = "Named workflows; runtime headers replace portable headers and steps compose by name.";
    };
  };
}
