# Git worktree protocol program. Both backends import this module unchanged:
# every effect is a per-runtime `ai.<runtime>.*` contribution, so neither
# backend has native work of its own.
{
  config,
  lib,
  ...
}: let
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  # Shipped protocol entries in render order. Both the order and the
  # defaults derive from this one list.
  shipped = [
    {
      name = "isolate";
      value = "Never author tracked or new files in the current checkout. Make every change in a git worktree under {location}. A relative location is relative to the repository's top-level directory, and {repo} is that directory's name.";
    }
    {
      name = "base";
      value = "Branch from the current checkout's branch unless told otherwise.";
    }
    {
      name = "request";
      value = "Push the branch and open a pull or merge request targeting the branch you started from.";
    }
    {
      name = "draft";
      value = "Open pull or merge requests as drafts.";
    }
    {
      name = "protect";
      value = "Never merge into or fast-forward the default branch locally.";
    }
    {
      name = "cleanup";
      value = "After the request merges, remove the worktree and delete the local branch.";
    }
  ];
  protocolOrder = map (entry: entry.name) shipped;
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
        '';
      };
      protocol = lib.mkOption {
        type = lib.types.attrsOf (aiTypes.optionalTextSource {
          autoEnable = false;
          description = "git worktree guidance";
          enableDefault = true;
          textType = lib.types.str;
        });
        default = {};
        defaultText = lib.literalMD "shipped entries: ${lib.concatMapStringsSep ", " (key: "`${key}`") protocolOrder}";
        example = lib.literalExpression ''
          {
            draft.enable = false;
            sign.text = "Sign every commit.";
          }
        '';
        description = ''
          Instructions delivered as `ai.<runtime>.extraSystemPrompt.git-worktrees`.
          Entries support `enable` and either `text` or `source`, using the same
          text-source type as delegate-routing entries. Shipped keys render in
          ${lib.concatStringsSep ", " protocolOrder} order; added keys follow in
          name order. Every `{location}` is replaced by `location`.

          WARNING: change where worktrees go with `location`, never by rewriting
          `isolate`. Other runtime settings derive from `location` and would
          silently disagree.
        '';
      };
    };
  };

  runtimeConfig = runtime: let
    cfg = program.resolve config runtime;
    orderedKeys = protocolOrder ++ lib.subtractLists protocolOrder (lib.attrNames cfg.protocol);
    text = lib.concatStringsSep "\n\n" (lib.concatMap (key:
      lib.optional (cfg.protocol ? ${key} && cfg.protocol.${key}.enable)
      (lib.removeSuffix "\n" cfg.protocol.${key}.text))
    orderedKeys);
  in
    lib.mkIf cfg.enable (lib.mkMerge ([
        {
          # Field by field: a whole-entry mkDefault would be discarded by any
          # consumer definition of one field.
          ai.${runtime}.extraSystemPrompt.git-worktrees = lib.mapAttrs (_: lib.mkDefault) {
            enable = text != "";
            text = builtins.replaceStrings ["{location}"] [cfg.location] text;
          };
        }
      ]
      # The protocol replaces Kiro's own worktree steering. The strip also
      # applies to Kiro's built-in default agent, which gets no protocol: only
      # typed agents receive `extraSystemPrompt`. With sibling worktrees the
      # vendor's absolute `{{worktree_path}}` stop-condition path never
      # resolves, so workflow loops spin to maxIterations; keep it relative.
      ++ lib.optional (runtime == "kiro") {
        ai.kiro.tweaks = {
          relativeFileCheckPaths = lib.mkDefault true;
          stripVendorWorktreeSteering = lib.mkDefault true;
        };
      }));
in {
  imports = [program.module];

  config = lib.mkMerge ([
      {
        ai.programs.git-worktrees.protocol =
          lib.mapAttrs (_: text: {
            text = lib.mkDefault text;
          })
          (lib.listToAttrs shipped);
      }
    ]
    ++ map runtimeConfig program.supportedRuntimes);
}
