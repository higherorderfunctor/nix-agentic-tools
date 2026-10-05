# Git worktree protocol program. Both backends import this module unchanged:
# every effect is a per-runtime `ai.<runtime>.*` contribution, so neither
# backend has native work of its own.
{
  config,
  lib,
  ...
}: let
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  programFactory = import ../../../lib/ai/program.nix {inherit lib;};
  program = programFactory.mkProgram {
    name = "git-worktrees";
    # Copilot has no `extraSystemPrompt`, which carries the protocol.
    supportedRuntimes = ["claude" "codex" "kimchi" "kiro"];
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to deliver the git worktree protocol to every supported runtime.";
      };
      location = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "../{repo}-worktrees";
        example = "~/worktrees";
        description = ''
          Directory that holds a repository's git worktrees. A relative path is
          relative to the repository's top-level directory, and `{repo}` stands
          for that directory's name. The protocol text receives it in place of
          `{location}`.

          Claude also gets it as `worktree.location` in its settings, but only
          when it is an absolute or `~/` path with no `{repo}`, the only shape
          that key accepts. Claude Code reads that key only in its Desktop app,
          for SSH sessions; its CLI does not.
        '';
      };
      protocol = lib.mkOption {
        type = aiTypes.textSource {
          defaultContent.source = ../protocol.md;
          description = "the git worktree protocol";
        };
        default = {};
        defaultText = lib.literalMD "the shipped protocol, `packages/git-worktrees/protocol.md`";
        description = ''
          Instructions delivered as `ai.<runtime>.extraSystemPrompt.git-worktrees`.
          Every `{location}` is replaced by `location`.
        '';
      };
    };
  };

  # The one shape `worktree.location` accepts (claude-code 2.1.289's settings
  # description): absolute or `~/`, with no placeholder.
  claudeLocation = location:
    if (lib.hasPrefix "/" location || lib.hasPrefix "~/" location) && !(lib.hasInfix "{repo}" location)
    then location
    else null;

  runtimeConfig = runtime: let
    cfg = program.resolve config runtime;
    claudeValue = claudeLocation cfg.location;
  in
    lib.mkIf cfg.enable (lib.mkMerge ([
        {
          # Field by field: a whole-entry mkDefault would be discarded by any
          # consumer definition of one field.
          ai.${runtime}.extraSystemPrompt.git-worktrees = lib.mapAttrs (_: lib.mkDefault) {
            enable = true;
            text = builtins.replaceStrings ["{location}"] [cfg.location] cfg.protocol.text;
          };
        }
      ]
      ++ lib.optional (runtime == "claude") (lib.mkIf (claudeValue != null) {
        ai.claude.native.settings.worktree.location = lib.mkDefault claudeValue;
      })
      # The protocol replaces Kiro's own worktree steering.
      ++ lib.optional (runtime == "kiro") {
        ai.kiro.tweaks.stripVendorWorktreeSteering = lib.mkDefault true;
      }));
in {
  imports = [program.module];

  config = lib.mkMerge (map runtimeConfig program.supportedRuntimes);
}
