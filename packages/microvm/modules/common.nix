{backend}: {
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  # Like lib/ai/proxy.nix's peer defaults, inheritance belongs in the option
  # default so even a runtime mkDefault replaces the whole inherited value.
  # Only explicitly requested root leaves supply runtime defaults.
  inheritOptions = path:
    lib.mapAttrs (name: option: let
      leaf = path ++ [name];
    in
      if lib.isOption option
      then
        option
        // {
          default =
            if (lib.getAttrFromPath leaf options.ai.sandbox).highestPrio < 1500
            then lib.getAttrFromPath leaf config.ai.sandbox
            else option.default;
        }
      else inheritOptions leaf option);
  # Stop at options for whole-option replacement: an evaluated-value default is
  # lossless for these bool/int/package-list leaves.
  sandboxOptions = {
    enable = lib.mkOption {
      default = false;
      description = "Install <runtime>-sandbox for enabled runtimes with a guest route. Runtime values override ai.sandbox defaults; false opts out.";
      type = lib.types.bool;
    };
    extraPackages = lib.mkOption {
      default = [];
      description = "Packages available throughout the guest and on its executable PATH. A runtime definition replaces the whole root list, rather than appending to it.";
      type = lib.types.listOf lib.types.package;
    };
    vm = {
      memory = lib.mkOption {
        default = 4096;
        description = "Guest RAM in MiB, from 128 to 1048576 (1 TiB), so a value given in bytes is refused; a runtime definition replaces the root value.";
        type = lib.types.ints.between 128 1048576;
      };
      vcpus = lib.mkOption {
        default = 2;
        description = "Guest virtual CPUs, at least one; a runtime definition replaces the root value.";
        type = lib.types.ints.positive;
      };
    };
  };

  # Guest routes and host command construction.
  commandName = name: "${name}-sandbox";
  factory = config.ai.internal.mkSandbox pkgs;
  routed = builtins.filter (name: config.ai.${name}.enable && config.ai.${name}.sandbox.enable) routeNames;
  # Guest routes deliberately select the configured package before host
  # installPackage/jail/environment wrapping. Only runtimes with a route get a
  # sandbox tree; Kiro and Kimchi need airlock first, and Copilot has no guest
  # executable route.
  routes = {
    claude = config.ai.claude.package;
    codex = config.ai.codex.package;
  };
  routeNames = builtins.attrNames routes;
  packageAssertion = name: {
    assertion = routes.${name} != null;
    message = "ai.${name}.sandbox.enable requires ai.${name}.package to be non-null; configuration-only runtimes cannot run in a guest.";
  };
  # The signer module and launcher consume one selection/name table.
  signers = lib.genAttrs routed (runtime:
    lib.mapAttrs (identity: entry: let
      service = "sandbox-signer-${runtime}-${identity}";
      evaluated = config.ai.services.${service};
    in {
      inherit service;
      inherit (evaluated) runtimeDir;
      environment = lib.filterAttrs (name: _: builtins.elem name ["TMPDIR" "XDG_RUNTIME_DIR"]) evaluated.environment;
      key = entry.signing.key;
    }) (lib.filterAttrs (_: entry: entry.signing.key != null) config.ai.${runtime}.sandbox.git.identities));
  runtimePackage = name: let
    cfg = config.ai.${name}.sandbox;
    package = routes.${name};
    args = {
      exe = lib.getExe package;
      # The guest's system git configuration (modules/git.nix), delivered as
      # a file because the libgit2 tools read files only; the system scope
      # is the one `safe.directory` is honored in.
      gitConfig = lib.generators.toGitINI cfg.git._ini;
      memory = cfg.vm.memory;
      outName = commandName name;
      packages = cfg.extraPackages ++ cfg.git._packages;
      vcpus = cfg.vm.vcpus;
    };
  in
    assert lib.assertMsg (packageAssertion name).assertion (packageAssertion name).message;
      if cfg.git.identities == {}
      then factory args
      else
        import ../lib/sandbox/launch.nix {
          inherit args factory lib pkgs;
          inherit (cfg.git) forges identities;
          instance = config.ai.git-relay.instances.sandbox;
          runtime = name;
          runtimeIdentities = options.ai.${name}.sandbox.git.identities.highestPrio < 1500;
          signers = signers.${name};
        };
in {
  imports = [
    (import ../../ai-module/lib/runtime.nix {
      enabled = true;
      name = "microvm";
    })
    (import ./git.nix {inherit routeNames;})
    (import ./identities.nix {inherit inheritOptions routed routeNames;})
    (import ./relay.nix {inherit backend routed;})
    (import ./signing.nix {inherit signers;})
  ];

  options.ai =
    {
      internal.sandboxPackages = lib.mkOption {
        default = map runtimePackage routed;
        description = "Sandbox launchers consumed by the Home Manager and devenv package sinks.";
        internal = true;
        readOnly = true;
        type = lib.types.listOf lib.types.package;
        visible = false;
      };
      sandbox = sandboxOptions;
    }
    // lib.genAttrs routeNames (_: {sandbox = inheritOptions [] sandboxOptions;});

  config = {
    assertions = map packageAssertion routed;
    ai.microvm.claims.command = map commandName routed;
  };
}
