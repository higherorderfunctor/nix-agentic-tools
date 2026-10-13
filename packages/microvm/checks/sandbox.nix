{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  args = {
    binName = "hello";
    outName = "sandbox-hello";
    pkg = pkgs.hello;
  };
  factory = self.lib.ai.mkSandbox pkgs;
  package = factory args;
  guest = package.guest.config;
  moduleConfig.ai.sandboxes.sandbox-hello = builtins.removeAttrs args ["outName"];
in {
  checks =
    {
      microvm-sandbox-empty = mkTest "microvm-sandbox-empty" (
        (evalHm {}).config.home.packages
        == []
        && (evalDevenv {}).config.packages == []
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      microvm-sandbox-launcher = package;
      microvm-sandbox-modules = mkTest "microvm-sandbox-modules" (
        map (p: p.drvPath) (evalHm moduleConfig).config.home.packages
        == [package.drvPath]
        && map (p: p.drvPath) (evalDevenv moduleConfig).config.packages == [package.drvPath]
        && (evalHm moduleConfig).config.ai.sandboxes.sandbox-hello.outName == "sandbox-hello"
      );
      microvm-sandbox-guest = mkTest "microvm-sandbox-guest" (
        guest.nixpkgs.hostPlatform.system
        == pkgs.stdenv.hostPlatform.system
        && guest.microvm.hypervisor == "qemu"
        && guest.microvm.interfaces == []
        && guest.microvm.volumes == []
        && guest.microvm.socket == null
        && !guest.microvm.storeOnDisk
        && guest.microvm.writableStoreOverlay == "/nix/.rw-store"
        && guest.fileSystems."/".fsType == "tmpfs"
        && guest.fileSystems."/nix/.rw-store".fsType == "tmpfs"
        && builtins.length guest.microvm.shares == 1
        && (builtins.head guest.microvm.shares).source == "/nix/store"
        && (builtins.head guest.microvm.shares).mountPoint == "/nix/.ro-store"
        && (builtins.head guest.microvm.shares).proto == "9p"
        && (builtins.head guest.microvm.shares).readOnly
        && guest.systemd.services.sandbox.serviceConfig.User == "sandbox"
        && guest.systemd.services.sandbox.serviceConfig.ExecStart == "${pkgs.hello}/bin/hello"
        && guest.systemd.services.sandbox.serviceConfig.ExecStopPost == "+${pkgs.systemd}/bin/systemctl --no-block reboot"
        && builtins.all (a: a.assertion) guest.assertions
      );
      microvm-sandbox-invalid-name = mkTest "microvm-sandbox-invalid-name" (
        !(builtins.tryEval (factory (args // {binName = "../hello";}))).success
        && !(builtins.tryEval (factory (args // {outName = "../hello";}))).success
      );
      microvm-sandbox-duplicate-name = mkTest "microvm-sandbox-duplicate-name" (
        let
          duplicate.ai.sandboxes = {
            a = args;
            b = args;
          };
          rejected = result: builtins.any (a: !a.assertion && a.message == "ai.sandboxes: each outName must be unique.") result.config.assertions;
        in
          rejected (evalHm duplicate) && rejected (evalDevenv duplicate)
      );
    };
}
