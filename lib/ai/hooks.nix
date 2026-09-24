{lib}: let
  packageToCommand = package:
    if lib.isDerivation package && (package.meta.mainProgram or null) != null
    then lib.getExe package
    else if lib.isDerivation package && package ? pname
    then lib.getExe' package package.pname
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

  # One matcher group: an optional matcher and its handlers. A runtime with
  # native handlers (Claude's handler types, Codex's extra fields) passes its
  # own handler type and, where its semantics differ, its own descriptions.
  mkMatcherBlockType = {
    handler,
    hooks ? "Command handlers fired by this matcher group.",
    matcher ? "Optional matcher passed unchanged to each runtime.",
  }:
    lib.types.submodule {
      options = {
        hooks = lib.mkOption {
          type = lib.types.listOf handler;
          default = [];
          description = hooks;
        };
        matcher = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = matcher;
        };
      };
    };

  portableMatcherBlockType = mkMatcherBlockType {handler = portableHandlerType;};

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

  # One matcher-group list per event. A runtime whose native event set is not
  # the portable one (Kimchi's is wider) declares its own option from the same
  # block type, so both lower through `render` below.
  mkHooksType = events:
    lib.types.submodule {
      options = lib.genAttrs events (event:
        lib.mkOption {
          type = lib.types.listOf portableMatcherBlockType;
          default = [];
          description = "${event} matcher groups.";
        });
    };

  hooksType = mkHooksType portableEvents;

  merge = shared: native:
    lib.zipAttrsWith (_event: lists: lib.concatLists lists) [shared native];

  # Typed event map → the Claude-shaped `hooks` JSON object that Claude's
  # settings.json and Kimchi's .kimchi/hooks.json both read. Per handler,
  # `filterAttrs (v != null)` drops a null timeout and keeps `type` plus any
  # freeform tail (Claude's http url, prompt, …). Per block, a null matcher is
  # omitted, because no-matcher events take none.
  render = lib.mapAttrs (_event:
    map (block:
      lib.optionalAttrs (block.matcher != null) {inherit (block) matcher;}
      // {hooks = map (lib.filterAttrs (_: value: value != null)) block.hooks;}));
in {
  inherit commandType hooksType merge mkHooksType mkMatcherBlockType packageToCommand portableEvents portableHandlerType render;
}
