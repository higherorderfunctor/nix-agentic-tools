# cspell:ignore chardev dports virtio virtserialport
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (harness) checkRows evalDevenv evalHm mkTest rejectsChange;
  args = {
    exe = lib.getExe pkgs.hello;
    outName = "sandbox-hello";
  };
  argvFixture = pkgs.writeScriptBin "sandbox-argv-fixture" ''
    #!${lib.getExe pkgs.python3}
    import json, os, sys
    print("SANDBOX_ARGV=" + json.dumps([os.fsencode(arg).hex() for arg in sys.argv[1:]]), flush=True)
    print(f"SANDBOX_UID={os.getuid()}", flush=True)
  '';
  argvPackage = factory {
    exe = lib.getExe argvFixture;
    outName = "sandbox-argv-fixture";
  };
  factory = self.lib.ai.mkSandbox pkgs;
  package = factory args;
  guest = package.guest.config;
  moduleConfig.ai.sandboxes.sandbox-hello = builtins.removeAttrs args ["outName"];
  statusFixture = pkgs.writeScriptBin "sandbox-status-fixture" ''
    #!${lib.getExe pkgs.python3}
    import os, signal, sys
    port = "/dev/virtio-ports/sandbox.status"
    assert os.stat(port).st_mode & 0o777 == 0o600, "completion port is not root-only"
    try:
        open(port, "w")
    except PermissionError:
        print("PASS: completion port denies guest writes", flush=True)
    else:
        raise AssertionError("guest can forge completion")
    print("exited:0", flush=True)  # Console text must not override the real status.
    if sys.argv[1] == "signal":
        os.kill(os.getpid(), signal.SIGTERM)
    sys.exit(int(sys.argv[1]))
  '';
in {
  checks =
    {
      microvm-sandbox-empty = mkTest "microvm-sandbox-empty" (
        checkRows "empty sandbox imports" {
          "Home Manager does not install a default guest" = (evalHm {}).config.home.packages == [];
          "devenv does not install a default guest" = (evalDevenv {}).config.packages == [];
        }
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      microvm-sandbox-argv = pkgs.runCommand "microvm-sandbox-argv" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${lib.getExe pkgs.python3} ${./argv.py} \
          ${lib.getExe argvPackage} \
          ${argvPackage.guest.config.microvm.declaredRunner}/bin/microvm-run \
          ${argvPackage.guest.config.systemd.services.sandbox.serviceConfig.ExecStart} \
          ${lib.getExe pkgs.python3} \
          ${lib.removePrefix "+" argvPackage.guest.config.systemd.services.sandbox.serviceConfig.ExecStopPost} \
          ${pkgs.systemd}/bin/systemctl
        # The executable string context must retain its package even without a separate package field.
        ${pkgs.gnugrep}/bin/grep -Fx ${lib.escapeShellArg (builtins.unsafeDiscardStringContext (toString argvFixture))} \
          ${pkgs.closureInfo {rootPaths = [argvPackage];}}/store-paths
        touch "$out"
      '';
      # Expose the real launcher for KVM smoke runs; the parser check substitutes its runner.
      microvm-sandbox-argv-launcher = argvPackage;
      microvm-sandbox-duplicate-name = mkTest "microvm-sandbox-duplicate-name" (
        let
          distinct.ai.sandboxes = {
            a = args;
            b = args // {outName = "sandbox-other";};
          };
          duplicate.ai.sandboxes = {
            a = args;
            b = args;
          };
          # The harness exposes backend assertions rather than turning them into throws.
          # Read only the name-collision assertion and require the same guard in the control.
          uniqueNameAssertions = evaluate: config:
            map (a: a.assertion) (lib.filter (a: a.message == "ai.sandboxes: each outName must be unique.") (evaluate config).config.assertions);
          checksNames = evaluate: let
            read = uniqueNameAssertions evaluate;
          in
            read distinct == [true] && read duplicate == [false];
        in
          checkRows "sandbox name collisions" {
            "Home Manager rejects two launchers that would occupy the same bin path" = checksNames evalHm;
            "devenv rejects two launchers that would occupy the same bin path" = checksNames evalDevenv;
          }
      );
      microvm-sandbox-guest = mkTest "microvm-sandbox-guest" (
        let
          inherit (guest) microvm;
          inherit (guest.systemd.services) sandbox;
          statusDevice = "dev-virtio\\x2dports-sandbox.status.device";
          storeShare = builtins.head microvm.shares;
        in
          checkRows "sandbox guest boundaries" {
            "argv's firmware blob can be read by the guest kernel" = builtins.elem "qemu_fw_cfg" guest.boot.kernelModules;
            "completion uses the sandbox status port, not the serial console" =
              builtins.elem "virtserialport,chardev=status,name=sandbox.status" microvm.qemu.extraArgs;
            "guest architecture does not drift from the host" = guest.nixpkgs.hostPlatform.system == pkgs.stdenv.hostPlatform.system;
            "guest command does not run as root" = sandbox.serviceConfig.User == "sandbox";
            "guest has no network interface" = microvm.interfaces == [];
            "guest has no persistent disk volumes" = microvm.volumes == [];
            "guest root is not disk-backed" = guest.fileSystems."/".fsType == "tmpfs";
            "guest runner does not expose a control socket" = microvm.socket == null;
            "only the host store is mounted, as the read-only lower layer" =
              builtins.length microvm.shares
              == 1
              && storeShare.source == "/nix/store"
              && storeShare.mountPoint == "/nix/.ro-store"
              && storeShare.proto == "9p"
              && storeShare.readOnly;
            "reporter is privileged even though the guest command is not" =
              lib.hasPrefix "+/nix/store/" sandbox.serviceConfig.ExecStopPost;
            "sandbox does not start before the status port appears" =
              builtins.elem statusDevice sandbox.requires && builtins.elem statusDevice sandbox.after;
            "status device permissions prevent the guest command from writing completion" =
              lib.hasInfix ''SUBSYSTEM=="virtio-ports", ATTR{name}=="sandbox.status", OWNER="root", GROUP="root", MODE="0600"'' guest.services.udev.extraRules;
            "status port is recognized by the guest kernel" = builtins.elem "virtio_console" guest.boot.kernelModules;
            "store writes go to a guest-local temporary overlay" =
              microvm.writableStoreOverlay
              == "/nix/.rw-store"
              && guest.fileSystems."/nix/.rw-store".fsType == "tmpfs";
          }
      );
      microvm-sandbox-invalid-name = mkTest "microvm-sandbox-invalid-name" (
        let
          # Read a static guest setting through the factory entry point. Forcing
          # the launcher derivation could reject a bad name independently.
          reject = invalid:
            rejectsChange (input: (factory input).guest.config.microvm.hypervisor) {
              inherit invalid;
              valid = args;
              expected = "qemu";
            };
        in
          checkRows "sandbox factory input restrictions" {
            "factory cannot regain extra arguments such as pkg or binName" = builtins.attrNames (builtins.functionArgs factory) == ["exe" "outName"];
            "guest executable cannot resolve through a relative path" = reject (args // {exe = "hello";});
            "output name cannot escape the launcher's bin directory" = reject (args // {outName = "../hello";});
          }
      );
      microvm-sandbox-launcher = package;
      microvm-sandbox-modules = mkTest "microvm-sandbox-modules" (
        let
          hm = (evalHm moduleConfig).config;
          devenv = (evalDevenv moduleConfig).config;
        in
          checkRows "sandbox installation" {
            "Home Manager installs exactly the equivalent standalone launcher" = map (p: p.drvPath) hm.home.packages == [package.drvPath];
            "devenv installs exactly the equivalent standalone launcher" = map (p: p.drvPath) devenv.packages == [package.drvPath];
          }
      );
      # A real VM is needed to distinguish enforced port permissions from the configured rule.
      microvm-sandbox-status-launcher = factory {
        exe = lib.getExe statusFixture;
        outName = "sandbox-status-fixture";
      };
    };
}
