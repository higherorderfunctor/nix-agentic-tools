# The sandbox's Git surface: `ai.sandbox.git` (shared across runtimes) and
# `ai.<runtime>.sandbox.git`, lowered into each runtime's internal `_ini` sink,
# which common.nix renders as the guest's system Git configuration
# (/etc/gitconfig — a protected scope, the only one `safe.directory` and a
# forced `core.sshCommand` hold in, and a file because git-absorb and
# git-revise are libgit2 and read files only). The types are the host's — the
# raw tree is lib/git-tool-settings/ini-type.nix, each tool's typed tree the
# owner's generator result — so one consumer value plugs into host and sandbox
# alike; nothing is copied or retyped here.
#
# Copy-down preserves DEFINITIONS, not evaluated values (review-v2 C1:
# forwarding an evaluated value loses nested priorities): a runtime
# `git.settings` definition replaces the root's whole value; otherwise the
# root's definitions forward at their own option-wide priority with nested
# mkOverride wrappers intact, so a nested mkDefault key still loses to a
# runtime value or a typed tool leaf for that key, and an equal-priority
# disagreement stays a loud conflict — exactly as the host's `git.settings`
# behaves (checks/git-config/module-eval.nix).
{routeNames}: {
  lib,
  options,
  pkgs,
  ...
}: let
  iniType = import ../../../lib/git-tool-settings/ini-type.nix {inherit lib;};
  lower = import ../../../lib/git-tool-settings/lower.nix {inherit lib;};
  # Nested priority wrappers travel with the definitions; the wrapper keeps an
  # option-wide `mkDefault`/`mkForce` from re-entering at ordinary priority
  # (packages/ai-module/lib/runtime.nix `forward`, the one precedent).
  forward = option: lib.modules.mkAliasAndWrapDefsWithPriority lib.id option;
  rootPath = ["ai" "sandbox" "git"];
  runtimePath = runtime: ["ai" runtime "sandbox" "git"];
  # The same tool-module invocation the host backends use, mounted at the
  # sandbox's shared root: it declares `ai.sandbox.git.<tool>` and evaluates
  # the owner's assertions wherever the tree mounts, but lowers and installs
  # nothing — each runtime tree below does, at the runtime's own sink.
  rootTrees = map (tool:
    import ../../../lib/git-tool-settings/tool-module.nix {
      package = ai: ai.gitTools.${tool.owner};
      inherit (tool) section settings;
      root = rootPath;
      sink = null;
      tool = tool.owner;
    })
  tools;
  # One tool tree per runtime: typed leaves lower into the runtime's `_ini`
  # sink at their own priority, `enable` defaults to the shared root's and
  # installs the package into the runtime's guest package list.
  runtimeTrees = runtime:
    map (tool:
      import ../../../lib/git-tool-settings/tool-module.nix {
        enableDescription = "Install ${tool.owner} in ${runtime}'s sandbox guest and its guest package list; defaults to ai.sandbox.git.${tool.section}.enable, which a definition here replaces at any priority.";
        enableFrom = rootPath ++ [tool.section "enable"];
        install = ["_packages"];
        package = ai: ai.gitTools.${tool.owner};
        inherit (tool) section settings;
        root = runtimePath runtime;
        sink = ["_ini"];
        tool = tool.owner;
      })
    tools;
  tools = [
    {
      owner = "git-absorb";
      section = "absorb";
      settings = (import ../../../packages/git-absorb/lib/default.nix).git-absorb.settings {inherit lib;};
    }
    {
      owner = "git-branchless";
      section = "branchless";
      settings = (import ../../../packages/git-branchless/lib/default.nix).git-branchless.settings {inherit lib;};
    }
    {
      owner = "git-revise";
      section = "revise";
      settings = (import ../../../packages/git-revise/lib/default.nix).git-revise.settings {inherit lib;};
    }
  ];
  # The refusal `core.sshCommand` runs: the guest holds no credentials, and
  # every push goes through the origin remote the host relay serves.
  noSsh = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-no-ssh";
    text = ''
      printf '%s\n' "SSH from the sandbox guest is refused." "Push through the guest's origin remote, which the host relay serves." >&2
      exit 1
    '';
  };
  # Guest-fixed keys, forced over every consumer value: no SSH from the guest,
  # and the seed and host-objects paths repo-guest.nix reads are trusted even
  # though the host owns them (repo-guest.nix clones --shared from
  # /run/sandbox/seed; repo-host.nix points the guest's alternates at
  # /mnt/objects).
  fixed = {
    core.sshCommand = lib.mkForce (lib.getExe noSsh);
    safe.directory = lib.mkForce ["/mnt/objects" "/run/sandbox/seed"];
  };
  # The raw tree: the runtime's own definitions when it has any, else the
  # root's — the whole-option replacement the rest of the tree already uses.
  rawSettings = runtime: let
    own = lib.getAttrFromPath (runtimePath runtime ++ ["settings"]) options;
  in
    lib.mkMerge [
      (lib.mkIf (own.highestPrio < 1500) (forward own))
      (lib.mkIf (own.highestPrio >= 1500) (forward (lib.getAttrFromPath (rootPath ++ ["settings"]) options)))
    ];
  # A typed leaf the runtime leaves unset inherits the root leaf's definition
  # at the root's own priority — the same per-leaf lowering the tool module
  # performs, so a root typed value conflicts with a raw value exactly as on
  # the host.
  inheritedTyped = runtime:
    lib.concatMap (tool: let
      ownTyped = (lib.getAttrFromPath (runtimePath runtime ++ [tool.section]) options).settings;
      rootTyped = (lib.getAttrFromPath (rootPath ++ [tool.section]) options).settings;
    in
      lib.concatMap (leaf:
        lib.optionals ((lib.getAttrFromPath (lib.tail leaf.path) ownTyped).highestPrio >= 1500)
        (lower.lower leaf (lib.getAttrFromPath (lib.tail leaf.path) rootTyped)))
      tool.settings.leaves)
    tools;
in {
  imports = rootTrees ++ lib.concatMap runtimeTrees routeNames;

  options.ai =
    {
      sandbox.git.settings = lib.mkOption {
        default = {};
        description = "Git configuration for every sandbox guest, in the same shape as the host's `git.settings`. A runtime `sandbox.git.settings` definition replaces this whole value; a runtime that defines only a typed tool leaf keeps these keys, and a nested `mkDefault` key here still loses to a runtime value or a typed leaf for that key. The guest-fixed keys `core.sshCommand` and `safe.directory` are forced on top.";
        type = iniType;
      };
    }
    // lib.genAttrs routeNames (runtime: {
      sandbox.git = {
        settings = lib.mkOption {
          default = {};
          description = "Git configuration for ${runtime}'s sandbox guest, in the same shape as the host's `git.settings`. Defining it replaces the whole inherited `ai.sandbox.git.settings` value; equal-priority disagreement with a typed tool leaf stays a loud conflict, exactly as on the host.";
          type = iniType;
        };
        _ini = lib.mkOption {
          default = {};
          description = "The runtime's merged Git configuration: raw definitions, typed tool leaves and the guest-fixed keys, each at its own priority; common.nix renders it as the guest's system /etc/gitconfig.";
          internal = true;
          type = iniType;
          visible = false;
        };
        _packages = lib.mkOption {
          default = [];
          description = "The enabled tools' packages, joined into the guest's package list by common.nix.";
          internal = true;
          type = lib.types.listOf lib.types.package;
          visible = false;
        };
      };
    });

  config.ai = lib.genAttrs routeNames (runtime: {
    sandbox.git._ini = lib.mkMerge ([fixed (rawSettings runtime)] ++ inheritedTyped runtime);
  });
}
