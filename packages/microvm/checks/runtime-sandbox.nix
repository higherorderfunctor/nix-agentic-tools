{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  # Runtimes with a guest route; the others have no sandbox tree.
  routed = ["claude" "codex"];
  withoutRoute = ["copilot" "kimchi" "kiro"];
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
    lib.recursiveUpdate (lib.genAttrs routed (_: {
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
  # git.nix's settings and tool leaves have their own checks (checks/git.nix);
  # these compare the rest of the tree, identities and forges included.
  onlyIdentities = sandbox: sandbox // {git = {inherit (sandbox.git) forges identities;};};
  # The guest's git configuration written out here: the fixture sets no Git
  # settings, so the file is the guest-fixed keys alone. Only the no-ssh
  # script's store path is read back from the module.
  expectedGitConfig = result: runtime: let
    text = result.config.ai.${runtime}.sandbox.git._config;
    sshCommand = builtins.head (lib.splitString "\"" (builtins.elemAt (lib.splitString "sshCommand = \"" text) 1));
  in "[core]\n\tsshCommand = \"${sshCommand}\"\n\n[safe]\n\tdirectory = \"\"\n\tdirectory = \"/mnt/seed\"\n";
  # The factory call common.nix makes for a runtime guest, with the expected
  # git configuration and package list.
  expected = result: runtime:
    factory {
      exe = lib.getExe pkgs.hello;
      gitConfig = expectedGitConfig result runtime;
      memory =
        if runtime == "codex"
        then 4096
        else 8192;
      outName = "${runtime}-sandbox";
      packages =
        if runtime == "codex"
        then [pkgs.ripgrep]
        else [pkgs.fd];
      vcpus = 4;
    };
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
    forBackends "command-claim" (api: let
      otherOwner = api.eval (lib.recursiveUpdate fixture {ai.claude.claims.command = ["claude-sandbox"];});
    in
      lib.any (assertion: !assertion.assertion && lib.hasPrefix "ai.claims.command.claude-sandbox: claimed by claude and microvm" assertion.message) otherOwner.config.assertions)
    // forBackends "copy-down" (api: let
      result = api.eval fixture;
      cfg = result.config.ai;
      replacement = {
        enable = false;
        extraPackages = [];
        git = {
          forges = {};
          identities = {};
        };
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
      routed
      && cfg.claude.sandbox.vm.memory == 8192
      && cfg.claude.sandbox.extraPackages == [pkgs.fd]
      && cfg.codex.sandbox.vm.memory == 4096
      && cfg.codex.sandbox.extraPackages == [pkgs.ripgrep]
      && cfg.sandbox.vm.memory == 8192
      && cfg.sandbox.extraPackages == [pkgs.fd]
      && onlyIdentities replaced.config.ai.codex.sandbox == replacement
      && onlyIdentities defaultReplaced.config.ai.codex.sandbox == replacement
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
        onlyIdentities result.config.ai.${runtime}.sandbox
        == {
          enable = false;
          extraPackages = [];
          git = {
            forges = {};
            identities = {};
          };
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
      routed
      && own.config.ai.codex.sandbox.extraPackages == [pkgs.fd]
      && own.config.ai.codex.sandbox.vm.memory == 2048
      && own.config.ai.sandbox.extraPackages == []
      && own.config.ai.sandbox.vm.memory == 4096
      && api.packages result == [])
    // forBackends "names" (api: let
      result = api.eval fixture;
      actual = result.config.ai.internal.sandboxPackages;
    in
      map (package: package.meta.mainProgram) actual
      == ["claude-sandbox" "codex-sandbox"]
      && map (package: package.drvPath) actual == map (runtime: (expected result runtime).drvPath) routed
      && lib.all (package: builtins.elem package.drvPath (map (p: p.drvPath) (api.packages result))) actual
      && result.config.ai.claims.command
      == {
        claude-sandbox = ["microvm"];
        codex-sandbox = ["microvm"];
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
        && !(builtins.tryEval (builtins.head result.config.ai.internal.sandboxPackages).drvPath).success)
      routed)
    // forBackends "size-bounds" (api: let
      accepted = path: value: (builtins.tryEval (builtins.deepSeq (lib.getAttrFromPath path (api.eval (lib.setAttrByPath path value)).config) true)).success;
      memory = ["ai" "codex" "sandbox" "vm" "memory"];
      rootMemory = ["ai" "sandbox" "vm" "memory"];
      vcpus = ["ai" "sandbox" "vm" "vcpus"];
    in
      accepted memory 128
      && accepted vcpus 1
      && !accepted memory 127
      && !accepted rootMemory 8589934592
      && !accepted vcpus 0)
    // forBackends "withoutRoute" (api: let
      enabled = runtime: {ai = (harness.setEnable runtime true).ai // {sandbox.enable = true;};};
    in
      lib.all (runtime: let
        result = api.eval (enabled runtime);
      in
        !(result.options.ai.${runtime} ? sandbox)
        && result.config.ai.internal.sandboxPackages == []
        && (result.config.ai.claims.command or {}) == {})
      withoutRoute)
    // lib.concatMapAttrs (backend: api:
      lib.listToAttrs (map (runtime:
        lib.nameValuePair "microvm-sandbox-${runtime}-${backend}-launcher"
        (lib.findFirst (package: package.meta.mainProgram == "${runtime}-sandbox") (throw "missing ${runtime}-sandbox on ${backend}") (api.eval fixture).config.ai.internal.sandboxPackages))
      routed))
    backends
  );
}
