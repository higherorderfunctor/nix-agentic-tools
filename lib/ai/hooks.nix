{lib}: let
  packageToCommand = package:
    if lib.isDerivation package && (package.meta.mainProgram or null) != null
    then lib.getExe package
    else "${package}";

  commandType = lib.types.coercedTo lib.types.package packageToCommand lib.types.str;

  portableHandlerType = lib.types.submodule {
    options = {
      command = lib.mkOption {
        type = commandType;
        description = "Command executed for this hook; packages resolve to their executable store path.";
      };
      timeout = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Per-handler timeout in seconds.";
      };
      type = lib.mkOption {
        type = lib.types.enum ["command"];
        default = "command";
        description = "Portable hooks currently support command handlers only.";
      };
    };
  };

  portableMatcherBlockType = lib.types.submodule {
    options = {
      hooks = lib.mkOption {
        type = lib.types.listOf portableHandlerType;
        default = [];
        description = "Command handlers fired by this matcher group.";
      };
      matcher = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional matcher passed unchanged to each runtime.";
      };
    };
  };

  portableEvents = [
    "PermissionRequest"
    "PostCompact"
    "PostToolUse"
    "PreCompact"
    "PreToolUse"
    "SessionEnd"
    "SessionStart"
    "Stop"
    "SubagentStart"
    "SubagentStop"
    "UserPromptSubmit"
  ];

  hooksType = lib.types.submodule {
    options = lib.genAttrs portableEvents (event:
      lib.mkOption {
        type = lib.types.listOf portableMatcherBlockType;
        default = [];
        description = "Portable ${event} matcher groups.";
      });
  };

  merge = shared: native:
    lib.zipAttrsWith (_event: lists: lib.concatLists lists) [shared native];
in {
  inherit commandType hooksType merge packageToCommand portableEvents;
}
