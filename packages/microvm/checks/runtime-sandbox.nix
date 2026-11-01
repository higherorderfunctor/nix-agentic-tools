{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  runtimes = import ../../../lib/ai/runtimes.nix;
  factory = self.lib.ai.mkSandbox pkgs;
  backends = {
    devenv = {
      eval = harness.evalDevenv;
      packages = result: result.config.packages;
    };
    hm = {
      eval = harness.evalHm;
      packages = result: result.config.home.packages;
    };
  };
  forBackends = name: test:
    lib.mapAttrs' (backend: api: lib.nameValuePair "microvm-sandbox-${name}-${backend}" (harness.mkTest "microvm-sandbox-${name}-${backend}" (test api))) backends;
  fixture.ai =
    lib.recursiveUpdate (lib.genAttrs ["claude" "codex"] (_: {
      enable = true;
      package = pkgs.hello;
    })) {
      codex.environmentVariables.SANDBOX_HOST_ONLY = "host-launcher";
      codex.sandbox = {
        extraPackages = [pkgs.ripgrep];
        vm.memory = 4096;
      };
      kiro.cli.enable = true;
      sandbox = {
        enable = true;
        extraPackages = [pkgs.fd];
        vm = {
          memory = 8192;
          vcpus = 4;
        };
      };
    };
  expected = runtime:
    factory {
      exe = lib.getExe pkgs.hello;
      memory =
        if runtime == "codex"
        then 4096
        else 8192;
      outName = "${runtime}-sandbox";
      packages =
        (
          if runtime == "codex"
          then [pkgs.ripgrep]
          else [pkgs.fd]
        )
        ++ [pkgs.git];
      vcpus = 4;
    };
  sandboxWarnings = evaluated: builtins.filter (message: lib.hasInfix "sandbox" message) evaluated.config.warnings;
  noRoute = runtime: "ai.${runtime}.sandbox.enable is true, but ${runtime} has no guest route; set ai.${runtime}.sandbox.enable = false to opt out.";
  deprecated = "ai.sandboxes is deprecated for one release; use ai.sandbox for runtime guests or lib.ai.mkSandbox for standalone guests.";
  legacy.ai.sandboxes.hello.exe = lib.getExe pkgs.hello;
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
    forBackends "command-collision" (api: let
      collision = api.eval (lib.recursiveUpdate fixture {
        ai.sandboxes.old = {
          exe = lib.getExe pkgs.hello;
          outName = "claude-sandbox";
        };
      });
      rejected = prefix: result: lib.any (assertion: !assertion.assertion && lib.hasPrefix prefix assertion.message) result.config.assertions;
    in
      rejected "ai.claims.command.claude-sandbox:" collision)
    // forBackends "copy-down" (api: let
      result = api.eval fixture;
      cfg = result.config.ai;
      replacement = {
        enable = false;
        extraPackages = [];
        vm = {
          memory = 4096;
          vcpus = 3;
        };
      };
      replaceWith = value: api.eval (lib.recursiveUpdate fixture {ai.codex.sandbox = value;});
      replaced = replaceWith replacement;
      defaultReplaced = replaceWith (lib.mapAttrsRecursive (_: lib.mkDefault) replacement);
    in
      lib.all (runtime:
        cfg.${runtime}.sandbox.enable
        && cfg.${runtime}.sandbox.vm.vcpus == 4
        && result.options.ai.${runtime}.sandbox.vm.vcpus.highestPrio == 1500)
      runtimes
      && cfg.claude.sandbox.vm.memory == 8192
      && cfg.claude.sandbox.extraPackages == [pkgs.fd]
      && cfg.codex.sandbox.vm.memory == 4096
      && cfg.codex.sandbox.extraPackages == [pkgs.ripgrep]
      && cfg.sandbox.vm.memory == 8192
      && cfg.sandbox.extraPackages == [pkgs.fd]
      && defaultReplaced.config.ai.codex.sandbox == replacement
      && replaced.config.ai.codex.sandbox == replacement
      && map (package: package.meta.mainProgram) replaced.config.ai.internal.sandboxPackages == ["claude-sandbox"])
    // forBackends "defaults" (api: let
      result = api.eval {};
      own = api.eval {
        ai.codex.sandbox = {
          extraPackages = lib.mkDefault [pkgs.fd];
          vm.memory = lib.mkDefault 2048;
        };
      };
      partial = api.eval {ai.sandbox.vm.memory = 8192;};
    in
      lib.all (runtime:
        result.config.ai.${runtime}.sandbox
        == {
          enable = false;
          extraPackages = [];
          vm = {
            memory = 4096;
            vcpus = 2;
          };
        }
        && result.options.ai.${runtime}.sandbox.enable.highestPrio == 1500
        && result.options.ai.${runtime}.sandbox.extraPackages.highestPrio == 1500
        && result.options.ai.${runtime}.sandbox.vm.memory.highestPrio == 1500
        && result.options.ai.${runtime}.sandbox.vm.vcpus.highestPrio == 1500
        && partial.options.ai.${runtime}.sandbox.enable.highestPrio == 1500
        && partial.options.ai.${runtime}.sandbox.extraPackages.highestPrio == 1500
        && partial.config.ai.${runtime}.sandbox.vm.memory == 8192
        && partial.options.ai.${runtime}.sandbox.vm.vcpus.highestPrio == 1500)
      runtimes
      && own.config.ai.codex.sandbox.extraPackages == [pkgs.fd]
      && own.config.ai.codex.sandbox.vm.memory == 2048
      && own.config.ai.sandbox.extraPackages == []
      && own.config.ai.sandbox.vm.memory == 4096
      && sandboxWarnings result == []
      && api.packages result == [])
    // forBackends "deprecation" (api:
      sandboxWarnings (api.eval legacy) == [deprecated])
    // forBackends "names" (api: let
      result = api.eval fixture;
      actual = result.config.ai.internal.sandboxPackages;
    in
      map (package: package.meta.mainProgram) actual
      == ["claude-sandbox" "codex-sandbox"]
      && map (package: package.drvPath) actual == map (runtime: (expected runtime).drvPath) ["claude" "codex"]
      && lib.all (package: builtins.elem package.drvPath (map (p: p.drvPath) (api.packages result))) actual
      && result.config.ai.claims.command
      == {
        claude-sandbox = ["ai.claude.sandbox"];
        codex-sandbox = ["ai.codex.sandbox"];
      })
    // forBackends "null-package" (api:
      lib.all (runtime: let
        result = api.eval {
          ai.${runtime} = {
            enable = true;
            package = null;
            sandbox.enable = true;
          };
        };
        failures = map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion) result.config.assertions);
      in
        builtins.elem "ai.${runtime}.sandbox.enable requires ai.${runtime}.package to be non-null; configuration-only runtimes cannot run in a guest." failures
        && !(builtins.tryEval (builtins.head result.config.ai.internal.sandboxPackages).drvPath).success) ["claude" "codex"])
    // forBackends "warnings" (api: let
      enabled = runtime: {ai = (harness.setEnable runtime true).ai // {sandbox.enable = true;};};
    in
      lib.all (runtime:
        sandboxWarnings (api.eval {ai.sandbox.enable = true;})
        == []
        && sandboxWarnings (api.eval (harness.setEnable runtime true)) == []
        && sandboxWarnings (api.eval (enabled runtime)) == [(noRoute runtime)]
        && sandboxWarnings (api.eval (lib.recursiveUpdate (enabled runtime) {ai.${runtime}.sandbox.enable = false;})) == []
        && (api.eval (enabled runtime)).config.ai.internal.sandboxPackages == []
        && ((api.eval (enabled runtime)).config.ai.claims.command or {}) == {}) ["copilot" "kimchi" "kiro"])
    // lib.concatMapAttrs (backend: api:
      lib.listToAttrs (map (runtime:
        lib.nameValuePair "microvm-sandbox-${runtime}-${backend}-launcher"
        (lib.findFirst (package: package.meta.mainProgram == "${runtime}-sandbox") (throw "missing ${runtime}-sandbox on ${backend}") (api.eval fixture).config.ai.internal.sandboxPackages)) ["claude" "codex"]))
    backends
  );
}
