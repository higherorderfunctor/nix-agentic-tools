# `ai.jail`: run each harness launcher inside an exclusion-only bubblewrap
# jail (jail.nix, `lib.ai.jail`). The jail starts from the full host view and
# the full environment, and takes away only what the consumer lists.
#
# One library for every place that touches the surface:
#   * option declarations: root `ai.jail` (sharedOptions.nix) and per-runtime
#     `ai.<runtime>.jail` (mkBackendTransform.nix `launcherOwnOptions`);
#   * `resolve`, the root-to-runtime fold behind
#     `ai.<runtime>.normalized.jail`;
#   * `wrap`, which jails an installed launcher package in place.
#
# Pure in shape: `config/ai-delivery-schema.nix` reads the root declaration
# with `pkgs = null`, so only `wrap` takes a package set.
{lib}: let
  inherit (lib) mkOption types;
  aiCommon = import ../ai-common.nix {inherit lib;};

  # Every field defaults to null. Delivery warnings count any non-null value,
  # a `false` included, as a request, so a non-null default would warn on
  # every runtime that does not consume the surface.
  fields = {
    enable = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Whether to jail the launcher. Null inherits; nothing is jailed until this resolves to `true`.";
    };
    exclude = mkOption {
      type = types.submodule {
        options = {
          environment = mkOption {
            type = types.nullOr (types.listOf (types.strMatching "[A-Za-z_][A-Za-z0-9_]*"));
            default = null;
            example = ["SSH_AUTH_SOCK"];
            description = "Environment variable names removed from the jailed process (`--unsetenv`).";
          };
          paths = mkOption {
            type = types.nullOr (types.listOf (types.strMatching "/.*"));
            default = null;
            example = ["/home/alice/.claude/.credentials.json" "/home/alice/.ssh"];
            description = ''
              Absolute host paths masked in the jail, resolved through
              `realpath` at launch: a directory becomes an empty tmpfs, a
              file an empty read-only file, and a path missing at launch is
              skipped.
            '';
          };
        };
      };
      default = {};
      description = "What the jail takes away from the host view.";
    };
    permissions = mkOption {
      type = types.nullOr types.raw;
      default = null;
      example = lib.literalExpression ''combinators: [(combinators.readonly "/etc")]'';
      description = ''
        A function from jail.nix's combinator set to a list of permissions,
        appended after the exclusion profile and the masks: the escape hatch
        into jail.nix's full vocabulary. The set includes the repository's
        `mask-path` and `unset-env`.
      '';
    };
  };

  # `ai.<runtime>.normalized.jail`: null, or the folded fields.
  resolvedType = types.nullOr (types.submodule {options = fields;});

  # Per field, a non-null runtime value replaces the root one; lists are
  # replaced, not merged. Null unless the result enables the jail.
  resolve = {
    root,
    runtime,
  }: let
    pick = path:
      aiCommon.resolveOverride {
        topValue = lib.getAttrFromPath path root;
        cliValue = lib.getAttrFromPath path runtime;
      };
    folded = {
      enable = pick ["enable"];
      exclude = {
        environment = pick ["exclude" "environment"];
        paths = pick ["exclude" "paths"];
      };
      permissions = pick ["permissions"];
    };
  in
    if folded.enable == true
    then folded
    else null;

  # The exclusion-only base: the whole host filesystem (`--dev-bind / /`),
  # with a fresh /proc for the unshared pid namespace (other processes'
  # environ stays out of reach) and a minimal /dev. The environment is kept
  # (no `--clearenv`) and the network namespace is shared, so a loopback
  # proxy stays reachable. `no-new-session` keeps the controlling terminal
  # the TUIs need. jail.nix still unshares user, ipc, pid, uts and cgroup and
  # adds `--die-with-parent`.
  basePermissions = c: [
    (c.unsafe-add-raw-args "--dev-bind / /")
    (c.unsafe-add-raw-args "--proc /proc")
    (c.unsafe-add-raw-args "--dev /dev")
    (c.unsafe-add-raw-args ''--chdir "$PWD"'')
    (c.share-ns "net")
    c.no-new-session
    c.strict-runtime
    c.restore-path
  ];

  # Jail each of `executables` from `package` in place: one jail per binary,
  # under the same name, joined with the package's `share/` when it has one.
  # Nothing else of the package is forwarded (none of its passthru, so a
  # later `launcherPackage` flatten cannot unwrap the jail); `jails` exposes
  # each wrapper by name for inspection.
  wrap = {
    executables,
    jail,
    name,
    package,
    pkgs,
    profile,
  }: let
    jailed = jail.extend {
      inherit basePermissions pkgs;
      additionalCombinators = jail.combinators pkgs;
    };
    permissions = c:
      map c.mask-path (lib.defaultTo [] profile.exclude.paths)
      ++ map c.unset-env (lib.defaultTo [] profile.exclude.environment)
      ++ lib.optionals (profile.permissions != null) (profile.permissions c);
    jails = lib.genAttrs executables (exe: jailed exe "${package}/bin/${exe}" permissions);
  in
    pkgs.symlinkJoin {
      name = "${name}-jail";
      paths = map (exe: jails.${exe}) executables;
      passthru = {inherit jails;};
      postBuild = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        if [ -d ${package}/share ]; then
          ln -s ${package}/share "$out/share"
        fi
      '';
      meta.mainProgram = builtins.head executables;
    };

  rootOption = mkOption {
    type = types.submodule {options = fields;};
    default = {};
    description = ''
      Run each AI harness launcher inside a bubblewrap jail built with
      jail.nix. Nothing is jailed until `enable = true`, here or on
      `ai.<runtime>.jail`; no path or variable is excluded by default.

      The jail is exclusion-only: the harness sees the whole host
      filesystem with the user's own permissions, keeps its environment
      and the host network, and loses only what is listed. Each
      `exclude.paths` entry is resolved through `realpath` at launch and
      masked there: a directory by an empty tmpfs, a file by an empty
      read-only file; a missing path is skipped. Each `exclude.environment`
      name is unset. `permissions` appends jail.nix combinators.

      `ai.<runtime>.jail` (Claude, Codex, Kimchi, and `ai.kiro.cli.jail`)
      overrides this field by field: a non-null runtime value replaces the
      root one, lists included. The jail wraps the installed launcher in
      place, so the harness command keeps its name. github.com Copilot has
      no launcher and warns.

      Linux only: on any other system the option evaluates, jails nothing
      and warns. The harnesses' own sandboxes (Codex's bubblewrap, Claude's
      sandbox, Kiro's FHS launcher) then run inside the jail and need
      nested user namespaces. That works when the outer bubblewrap is the
      Nix-store binary this jail uses, and fails under Ubuntu's
      AppArmor-confined `/usr/bin/bwrap`.
    '';
  };
in {
  inherit
    fields
    resolve
    resolvedType
    rootOption
    wrap
    ;
}
