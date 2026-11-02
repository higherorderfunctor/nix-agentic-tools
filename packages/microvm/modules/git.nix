# The sandbox's Git surface: `ai.sandbox.git` (shared across runtimes) and
# `ai.<runtime>.sandbox.git`, lowered into each runtime's internal `_ini` sink,
# which common.nix renders as the guest's system Git configuration
# (/etc/gitconfig). That scope is where `safe.directory` must live — Git
# honors it only in protected configuration — and a file because git-absorb
# and git-revise are libgit2 and read files only. It is also Git's LOWEST
# scope: the forced `core.sshCommand` there is the refusal an ordinary push
# hits, not a boundary — a guest process can override it through any higher
# scope (`--global`, repository-local, `-c`), and the guest holds no
# credentials either way. The types are the host's — the raw tree is
# lib/git-tool-settings/ini-type.nix, each tool's typed tree the owner's
# generator result — so one consumer value plugs into host and sandbox alike;
# nothing is copied or retyped here.
#
# Copy-down preserves DEFINITIONS, not evaluated values (review-v2 C1:
# forwarding an evaluated value loses nested priorities): a runtime
# `git.settings` definition replaces the root's whole value; otherwise the
# root's definitions forward at their own option-wide priority with nested
# mkOverride wrappers intact, so a nested mkDefault key still loses to a
# runtime value or a typed tool leaf for that key, and an equal-priority
# disagreement stays a loud conflict — exactly as the host's `git.settings`
# behaves (checks/git-config/module-eval.nix).
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  runtimeNames = import ../../../lib/ai/runtimes.nix;
  iniType = import ../../../lib/git-tool-settings/ini-type.nix {inherit lib;};
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
  # installs the package into the runtime's guest package list. The guest's
  # system file is the lowest Git scope it reads, so each tree also carries
  # the owner's lowest-scope checks (an unset leaf there is upstream's
  # default); the shared root tree above carries none, because it renders
  # into no scope of its own — its leaves reach a guest only through these
  # runtime trees, which check them.
  runtimeTrees = runtime:
    map (tool:
      import ../../../lib/git-tool-settings/tool-module.nix {
        assertions = tool.settings.lowestScopeAssertions or [];
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
  # /mnt/objects). The force is per LEAF: a section-level one would swallow
  # every other key a consumer sets there (core.editor, say) whole.
  # `fixedValues` stays unwrapped so `leafPaths` below walks the one list of
  # key paths.
  fixedValues = {
    core.sshCommand = lib.getExe noSsh;
    safe.directory = builtins.attrValues (import ../lib/repo-paths.nix);
  };
  fixed = lib.mapAttrs (_: lib.mapAttrs (_: lib.mkForce)) fixedValues;
  # Every leaf key path of an ini tree, one per rendered key. A priority
  # wrapper still around a value is not a subtree: what renders is its
  # content.
  leafPaths = prefix: tree:
    lib.concatMap (name: let
      value = tree.${name};
    in
      if value ? _type && value._type == "override"
      then leafPaths (prefix ++ [name]) value.content
      else if lib.isAttrs value
      then leafPaths (prefix ++ [name]) value
      else [(prefix ++ [name])])
    (lib.attrNames tree);
  folded = path: lib.concatStringsSep "." (map lib.toLower path);
  # Git folds the case of section and key names; Nix does not. A consumer key
  # a guest-fixed key differs from only by case is two keys to the `_ini`
  # merge and ONE to Git: both render — the force is per leaf, and these are
  # different leaves to Nix — and the line that renders last is the one Git
  # uses, a bypass of the forced `core.sshCommand` (for `safe.directory`, an
  # extra trusted path). The merge cannot refuse it, so the configuration
  # does (config.assertions), over the raw keys that flow toward the file.
  fixedKeys = map (path: {
    inherit path;
    folded = folded path;
  }) (leafPaths [] fixedValues);
  # The consumer keys that actually flow toward the rendered file: the
  # runtime's own `settings` value when it defines one, else the root's — the
  # same branch `rawSettings` forwards, so a key the whole-option replacement
  # already discarded is not refused.
  effectiveRaw = runtime:
    if runtimeDefinesSettings runtime
    then lib.getAttrFromPath (runtimePath runtime ++ ["settings"]) config
    else lib.getAttrFromPath (rootPath ++ ["settings"]) config;
  # The raw tree: the runtime's own definitions when it has any, else the
  # root's — the whole-option replacement the rest of the tree already uses.
  runtimeDefinesSettings = runtime:
    (lib.getAttrFromPath (runtimePath runtime ++ ["settings"]) options).highestPrio < 1500;
  rawSettings = runtime: let
    own = lib.getAttrFromPath (runtimePath runtime ++ ["settings"]) options;
  in
    lib.mkMerge [
      (lib.mkIf (runtimeDefinesSettings runtime) (forward own))
      (lib.mkIf (!(runtimeDefinesSettings runtime)) (forward (lib.getAttrFromPath (rootPath ++ ["settings"]) options)))
    ];
  # The root's typed leaf definitions reach the runtime's typed tree itself,
  # forwarded at the root's own priority — never lowered around it into
  # `_ini`: the tool module lowers the merged leaf at that priority, and the
  # owner's assertions read the merged settings, so a root `test.jobs` meets a
  # runtime `test.strategy` inside one tree instead of slipping past every
  # assertion into `_ini`, which none of them reads. A leaf both sides define
  # arbitrates by the priorities its definitions carry (an equal-priority
  # disagreement is a loud conflict, as the raw tree's are); conditioning the
  # forward on the runtime leaf being unset would read the priority of the
  # very option these definitions land in, which does not terminate.
  # Each definition is a relative path spliced under every runtime's own
  # `ai.<runtime>` block, so one list serves them all.
  inheritedTyped = lib.concatMap (tool:
    lib.map (
      leaf:
        lib.setAttrByPath (["sandbox" "git" tool.section "settings"] ++ lib.tail leaf.path)
        (forward (lib.getAttrFromPath (lib.tail leaf.path) (lib.getAttrFromPath (rootPath ++ [tool.section]) options).settings))
    )
    tool.settings.leaves)
  tools;
in {
  imports = rootTrees ++ lib.concatMap runtimeTrees runtimeNames;

  options.ai =
    {
      sandbox.git.settings = lib.mkOption {
        default = {};
        description = "Git configuration for every sandbox guest, in the same shape as the host's `git.settings`. A runtime `sandbox.git.settings` definition replaces this whole value; a runtime that defines only a typed tool leaf keeps these keys, and a nested `mkDefault` key here still loses to a runtime value or a typed leaf for that key. The guest-fixed keys `core.sshCommand` and `safe.directory` are forced on top, and a key differing from either only by case fails evaluation: Git folds key case and Nix does not, so the two are one key to Git whatever the merge does with them.";
        type = iniType;
      };
    }
    // lib.genAttrs runtimeNames (runtime: {
      sandbox.git = {
        settings = lib.mkOption {
          default = {};
          description = "Git configuration for ${runtime}'s sandbox guest, in the same shape as the host's `git.settings`. Defining it replaces the whole inherited `ai.sandbox.git.settings` value; equal-priority disagreement with a typed tool leaf stays a loud conflict, exactly as on the host. The guest-fixed keys `core.sshCommand` and `safe.directory` are forced on top, and a key differing from either only by case fails evaluation, as at the shared root.";
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

  config = {
    # Refuse consumer keys a guest-fixed key differs from only by case
    # (`fixedKeys` above explains why the merge cannot be allowed to settle
    # it): one assertion per runtime and fixed key, naming both keys, over
    # the raw keys that flow toward the runtime's rendered file.
    assertions = lib.concatMap (runtime:
      lib.concatMap (fixed: let
        offenders = lib.remove fixed.path (lib.filter (path: folded path == fixed.folded) (leafPaths [] (effectiveRaw runtime)));
      in [
        {
          assertion = offenders == [];
          message = ''
            ${lib.concatStringsSep "." (runtimePath runtime)} sets ${lib.concatStringsSep ", " (map (lib.concatStringsSep ".") offenders)}, which the guest-fixed ${lib.concatStringsSep "." fixed.path} differs from only by case.
            Git folds the case of section and key names and Nix does not, so to Git these are one key with two values: the forced one and yours. Drop the key; guest-fixed keys are not configurable.
          '';
        }
      ])
      fixedKeys)
    runtimeNames;

    ai = lib.genAttrs runtimeNames (runtime:
      lib.mkMerge (
        [{sandbox.git._ini = lib.mkMerge [fixed (rawSettings runtime)];}]
        ++ inheritedTyped
      ));
  };
}
