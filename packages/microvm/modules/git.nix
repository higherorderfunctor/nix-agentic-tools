# cspell:ignore extraheader includeif insteadof pushinsteadof signingkey
# The sandbox's Git surface: `ai.sandbox.git` (shared across runtimes) and
# `ai.<runtime>.sandbox.git`, lowered into each runtime's internal `_ini` sink,
# which common.nix renders, with the guest-fixed keys after it, as the guest's
# system Git configuration (/etc/gitconfig). That scope is where
# `safe.directory` must live — Git honors it only in protected configuration —
# and a file because git-absorb and git-revise are libgit2 and read files only.
# It is also Git's LOWEST scope: the fixed `core.sshCommand` there is the
# refusal an ordinary push hits, not a boundary — a guest process can override
# it through any higher scope (`--global`, repository-local, `-c`), and the
# guest holds no credentials either way. The types are the host's — the raw
# tree is lib/git-tool-settings/ini-type.nix, each tool's typed tree the
# owner's generator result — so one consumer value plugs into host and sandbox
# alike; nothing is copied or retyped here.
#
# Copy-down preserves DEFINITIONS, not evaluated values (forwarding an
# evaluated value loses nested priorities): a runtime
# `git.settings` definition replaces the root's whole value; otherwise the
# root's definitions forward at their own option-wide priority with nested
# mkOverride wrappers intact, so a nested mkDefault key still loses to a
# runtime value or a typed tool leaf for that key, and an equal-priority
# disagreement stays a loud conflict — exactly as the host's `git.settings`
# behaves (checks/git-config/module-eval.nix). The root's typed leaves replace
# the same way: they forward as weak defaults a runtime's own value for the
# leaf wins over (see `inheritedTyped`).
{routeNames}: {
  config,
  lib,
  options,
  pkgs,
  ...
}: let
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
        assertions = tool.settings.lowestScopeAssertions or null;
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
  # Guest-fixed keys: no SSH from the guest, and the seed path repo-guest.nix
  # clones --shared from (/mnt/seed) is trusted even though the host owns it.
  # They render AFTER everything the consumer sets, so they win: Git takes the
  # last value of a single-valued key whatever the case of its section and key
  # names, and an empty `safe.directory` resets the list a consumer built
  # before the seed path joins it. An `include` earlier in the file cannot
  # change that, and `include` itself is refused below.
  fixedConfig = lib.generators.toGitINI {
    core.sshCommand = lib.getExe noSsh;
    safe.directory = ["" (import ../lib/repo-paths.nix).seed];
  };
  # The guest's /etc/gitconfig lands in the Nix store, which any local user
  # reads, and the guest holds no credentials. A consumer value that carries
  # one, or can pull one in, is refused wherever the raw tree defines it:
  # whole sections, and single keys of sections that hold other settings.
  refusedSections = ["credential" "gpg" "include" "includeif"];
  refusedKeys = {
    http = ["extraheader"];
    url = ["insteadof" "pushinsteadof"];
    user = ["signingkey"];
  };
  # Every key of an ini tree as the consumer wrote it, with the section and
  # key names Git compares (case folded; a dotted or quoted subsection is not
  # part of the section name).
  iniKeys = tree:
    lib.concatMap (top:
      lib.concatMap (name: let
        value = tree.${top}.${name};
        key = path: {
          inherit path;
          section = lib.toLower (builtins.head (builtins.match "([^ .\"]*).*" top));
          name = lib.toLower (lib.last path);
        };
      in
        if lib.isAttrs value
        then map (leaf: key [top name leaf]) (lib.attrNames value)
        else [(key [top name])]) (lib.attrNames tree.${top}))
    (lib.attrNames tree);
  isRefused = entry: lib.elem entry.section refusedSections || lib.elem entry.name (refusedKeys.${entry.section} or []);
  # The raw tree: the runtime's own definitions when it has any, else the
  # root's — the whole-option replacement the rest of the tree already uses.
  runtimeDefinesSettings = runtime:
    (lib.getAttrFromPath (runtimePath runtime ++ ["settings"]) options).highestPrio < 1500;
  rawSettings = runtime: let
    own = lib.getAttrFromPath (runtimePath runtime ++ ["settings"]) options;
  in
    forward (
      if runtimeDefinesSettings runtime
      then own
      else lib.getAttrFromPath (rootPath ++ ["settings"]) options
    );
  # The root's typed leaf definitions reach the runtime's typed tree itself —
  # never lowered around it into `_ini`: the tool module lowers the merged
  # leaf, and the owner's assertions read the merged settings, so a root
  # `test.jobs` meets a runtime `test.strategy` inside one tree instead of
  # slipping past every assertion into `_ini`, which none of them reads. They
  # forward as weak defaults, below any definition a runtime makes for the
  # same leaf (a runtime `mkDefault` included), so the runtime's value replaces
  # the root's as a runtime `settings` or `enable` does, where equal-priority
  # definitions would be a conflict. For the same reason a root typed leaf also
  # yields to a raw key at normal priority. Conditioning the forward on the
  # runtime leaf being unset would read the priority of the very option these
  # definitions land in, which does not terminate.
  # Each definition is a relative path spliced under every runtime's own
  # `ai.<runtime>` block, so one list serves them all.
  rootTypedPriority = 1400;
  inheritedTyped = lib.concatMap (tool:
    lib.map (
      leaf:
        lib.setAttrByPath (["sandbox" "git" tool.section "settings"] ++ lib.tail leaf.path)
        (let
          rootLeaf = lib.getAttrFromPath (lib.tail leaf.path) (lib.getAttrFromPath (rootPath ++ [tool.section]) options).settings;
        in
          lib.mkIf rootLeaf.isDefined (lib.mkMerge (map (lib.mkOverride rootTypedPriority) rootLeaf.definitions)))
    )
    tool.settings.leaves)
  tools;
in {
  imports = rootTrees ++ lib.concatMap runtimeTrees routeNames;

  options.ai =
    {
      sandbox.git.settings = lib.mkOption {
        default = {};
        description = "Git configuration for every sandbox guest, in the same shape as the host's `git.settings`. A runtime `sandbox.git.settings` definition replaces this whole value; a runtime that defines only a typed tool leaf keeps these keys, and a nested `mkDefault` key here still loses to a runtime value or a typed leaf for that key. The guest-fixed keys `core.sshCommand` and `safe.directory` render after everything here, so a value for either (in any case) loses; keys that carry or pull in credentials (`credential`, `gpg`, `include`, `includeIf`, `http.*.extraHeader`, `url.*.insteadOf`, `url.*.pushInsteadOf`, `user.signingKey`) fail evaluation, because the file is world-readable in the store.";
        type = iniType;
      };
    }
    // lib.genAttrs routeNames (runtime: {
      sandbox.git = {
        settings = lib.mkOption {
          default = {};
          description = "Git configuration for ${runtime}'s sandbox guest, in the same shape as the host's `git.settings`. Defining it replaces the whole inherited `ai.sandbox.git.settings` value; equal-priority disagreement with a typed tool leaf stays a loud conflict, exactly as on the host. The guest-fixed keys render after everything here and credential-carrying keys fail evaluation, as at the shared root.";
          type = iniType;
        };
        _ini = lib.mkOption {
          default = {};
          description = "The runtime's merged Git configuration: raw definitions and typed tool leaves, each at its own priority, without the guest-fixed keys.";
          internal = true;
          type = iniType;
          visible = false;
        };
        _config = lib.mkOption {
          default = "";
          description = "The runtime's rendered system Git configuration: `_ini` followed by the guest-fixed keys; common.nix hands it to the factory as the guest's /etc/gitconfig.";
          internal = true;
          type = lib.types.str;
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
    # Refuse the credential-carrying keys (`refusedSections`) in every tree
    # that defines raw settings: the shared root and each runtime's own.
    assertions =
      map (path: let
        offenders = map (entry: lib.concatStringsSep "." entry.path) (lib.filter isRefused (iniKeys (lib.getAttrFromPath (path ++ ["settings"]) config)));
      in {
        assertion = offenders == [];
        message = ''
          ${lib.concatStringsSep "." path}.settings sets ${lib.concatStringsSep ", " offenders}, which the sandbox guest's git configuration refuses.
          The guest's /etc/gitconfig is built into the Nix store, which any local user can read, and the guest holds no credentials. Credential helpers, authorization headers, signing keys, gpg programs, URL rewrites (they can embed a token) and includes (they can pull any of these in) never reach it. Drop the key.
        '';
      })
      ([rootPath] ++ map runtimePath routeNames);

    ai = lib.genAttrs routeNames (runtime:
      lib.mkMerge (
        [
          {sandbox.git._ini = rawSettings runtime;}
          {sandbox.git._config = lib.generators.toGitINI config.ai.${runtime}.sandbox.git._ini + fixedConfig;}
        ]
        ++ inheritedTyped
      ));
  };
}
