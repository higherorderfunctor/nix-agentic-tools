{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  runtimeNames = import ../../../lib/ai/runtimes.nix;
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
  # Stop at options (including future attrsOf leaves) for whole-option
  # replacement. Evaluated-value defaults are lossless for these bool/int/
  # package-list leaves, but discard nested priorities in ini-typed values.
  # Phase 5 git.settings must preserve definitions with
  # lib.modules.mkAliasAndWrapDefsWithPriority, as in
  # packages/ai-module/lib/runtime.nix:forward; do not use inheritOptions there.
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
        description = "Guest RAM in MiB, at least 128; a runtime definition replaces the root value.";
        type = lib.types.int;
      };
      vcpus = lib.mkOption {
        default = 2;
        description = "Guest virtual CPUs, at least one; a runtime definition replaces the root value.";
        type = lib.types.int;
      };
    };
  };

  # Guest routes and host command construction.
  active = builtins.filter (name: config.ai.${name}.enable && config.ai.${name}.sandbox.enable) runtimeNames;
  commandName = name: "${name}-sandbox";
  factory = config.ai.internal.mkSandbox pkgs;
  routed = builtins.filter (name: routes ? ${name}) active;
  # Guest routes deliberately select the configured package before host
  # installPackage/jail/environment wrapping. Kiro/Kimchi need airlock first;
  # Copilot has no guest executable route.
  routes = {
    claude = config.ai.claude.package;
    codex = config.ai.codex.package;
  };
  packageAssertion = name: {
    assertion = routes.${name} != null;
    message = "ai.${name}.sandbox.enable requires ai.${name}.package to be non-null; configuration-only runtimes cannot run in a guest.";
  };
  runtimePackage = name: let
    cfg = config.ai.${name}.sandbox;
    package = routes.${name};
  in
    assert lib.assertMsg (packageAssertion name).assertion (packageAssertion name).message;
      factory {
        exe = lib.getExe package;
        memory = cfg.vm.memory;
        outName = commandName name;
        packages = cfg.extraPackages ++ [pkgs.git];
        vcpus = cfg.vm.vcpus;
      };
in {
  options.ai =
    {
      internal.sandboxPackages = lib.mkOption {
        default = map runtimePackage routed ++ map factory (builtins.attrValues config.ai.sandboxes);
        description = "Sandbox launchers consumed by the Home Manager and devenv package sinks.";
        internal = true;
        readOnly = true;
        type = lib.types.listOf lib.types.package;
        visible = false;
      };
      sandbox = sandboxOptions;
      sandboxes = lib.mkOption {
        default = {};
        description = "Deprecated for one release: use ai.sandbox for runtimes or lib.ai.mkSandbox for a standalone guest.";
        type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
          options = {
            exe = lib.mkOption {
              description = "Absolute guest executable path, usually lib.getExe or lib.getExe' applied to a package.";
              type = lib.types.str;
            };
            outName = lib.mkOption {
              default = name;
              description = "Host wrapper executable name.";
              type = lib.types.str;
            };
          };
        }));
      };
    }
    // lib.genAttrs runtimeNames (_: {sandbox = inheritOptions [] sandboxOptions;});

  config = lib.mkMerge [
    {
      assertions = map packageAssertion routed;
      warnings =
        lib.optional (config.ai.sandboxes != {}) "ai.sandboxes is deprecated for one release; use ai.sandbox for runtime guests or lib.ai.mkSandbox for standalone guests."
        ++ map (name: "ai.${name}.sandbox.enable is true, but ${name} has no guest route; set ai.${name}.sandbox.enable = false to opt out.") (builtins.filter (name: !(routes ? ${name})) active);
    }
    {
      ai.claims.command = lib.mkMerge (
        map (name: {${commandName name} = ["ai.${name}.sandbox"];}) routed
        ++ lib.mapAttrsToList (name: sandbox: {${sandbox.outName} = ["ai.sandboxes.${name}"];}) config.ai.sandboxes
      );
    }
  ];
}
