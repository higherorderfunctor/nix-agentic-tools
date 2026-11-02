# cspell:ignore guestfwd netdev
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  factory = self.lib.ai.mkSandbox pkgs;
  mkLintedCheck = import ../../../lib/mk-linted-check.nix {inherit pkgs;};
  redact = import ../../../lib/redact {inherit lib;};
  state = "/tmp/microvm-sandbox-session-check";
  guest = pkgs.writeScriptBin "sandbox-session-guest" ''
    #!${lib.getExe pkgs.python3}
    ${builtins.readFile ./session-guest.py}
  '';
  fixture.ai = {
    claude = {
      enable = true;
      package = guest;
      sandbox.git.identities.personal = identity "claude-only";
    };
    codex = {
      enable = true;
      package = guest;
      sandbox.git.identities.work = identity "codex-only";
    };
    git-relay.instances.sandbox = {
      port = 29418;
      stateDir = state;
    };
    sandbox = {
      enable = true;
      git.forges."127.0.0.1".hostKeys = "[127.0.0.1]:29422 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAOhB7/zzhC+HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4";
      vm = {
        memory = 1024;
        vcpus = 1;
      };
    };
  };
  identity = token: {
    push.key = redact.file "${state}/client-key";
    remotes.${token}.forge = "127.0.0.1";
    user = {
      email = "guest-session@example.invalid";
      name = "Guest Session Bot";
    };
  };
  backends = {
    devenv = harness.evalDevenv fixture;
    hm = harness.evalHmModules [fixture {ai.codex.pinDaemonToPackage = false;}];
  };
  launcher = result: runtime:
    lib.findFirst (package: package.meta.mainProgram == "${runtime}-sandbox") (throw "missing ${runtime} session launcher") result.config.ai.internal.sandboxPackages;
  check = name: predicate:
    lib.mapAttrs' (backend: result:
      lib.nameValuePair "microvm-sandbox-session-${name}-${backend}"
      (harness.mkTest "microvm-sandbox-session-${name}-${backend}" (predicate result)))
    backends;
  codex = launcher backends.hm "codex";
  claude = launcher backends.hm "claude";
  relay = backends.hm.config.ai.git-relay.instances.sandbox.package;
  boot = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-session-boot-check";
    runtimeInputs = [pkgs.coreutils pkgs.git pkgs.openssh pkgs.openssl pkgs.python3];
    text = ''
      exec ${lib.getExe pkgs.python3} ${./session.py} \
        ${lib.getExe codex} ${lib.getExe claude} ${lib.getExe relay} \
        ${lib.getExe' pkgs.openssh "sshd"} ${lib.getExe' pkgs.git "git-shell"} ${lib.getExe pkgs.bash} ${state}
    '';
  };
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
    check "wiring" (result: let
      cfg = result.config;
      one = runtime: let
        package = launcher result runtime;
        inherit (package) table;
        token = "${runtime}-only";
        own =
          if runtime == "codex"
          then "work"
          else "personal";
        connected = package.connected.guest.config;
        netdev = lib.findFirst (lib.hasPrefix "user,id=doors") "" connected.microvm.qemu.extraArgs;
      in
        builtins.attrNames table
        == [token]
        && table.${token}.credential == "${runtime}-${own}"
        && table.${token}.identity == own
        && package.plain.drvPath
        == (factory {
          exe = lib.getExe guest;
          memory = 1024;
          outName = "${runtime}-sandbox";
          packages = [pkgs.git];
          vcpus = 1;
        }).drvPath
        && package.plain.guest.config.microvm.interfaces == []
        && package.seeded.guest.config.microvm.interfaces == []
        && !lib.any (lib.hasPrefix "user,id=doors") package.seeded.guest.config.microvm.qemu.extraArgs
        && lib.hasInfix "guestfwd=tcp:10.0.2.100:9418-cmd:" netdev
        && builtins.elem "name=opt/sandbox.repo-config,file=repo-config" connected.microvm.qemu.extraArgs
        && cfg.ai.git-relay.instances.sandbox.stateDir == state;
    in
      lib.all one ["claude" "codex"])
    // {
      microvm-sandbox-session-boot = boot;
      microvm-sandbox-session-launchers = mkLintedCheck "microvm-sandbox-session-launchers" {
        runtimeInputs = [pkgs.gnugrep];
        text = lib.concatMapStringsSep "\n" (package: ''
          grep -F ${lib.escapeShellArg "${lib.getExe package.selector} ${package.tableFile}"} ${lib.getExe package}
          if grep -Fq sandbox-select ${lib.getExe package.plain}; then
            echo 'plain factory launcher unexpectedly invokes identity selection' >&2
            exit 1
          fi
        '') [claude codex];
      };
    }
  );
}
