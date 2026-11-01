# cspell:ignore chardev dports virtio virtserialport
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  args = {
    exe = lib.getExe pkgs.hello;
    outName = "sandbox-hello";
  };
  argvFixture = pkgs.writeScriptBin "sandbox-argv-fixture" ''
    #!${lib.getExe pkgs.python3}
    import hashlib, os, sys
    data = b"".join(os.fsencode(arg) + b"\0" for arg in sys.argv[1:])
    print(f"SANDBOX_ARGV={len(sys.argv) - 1}:{hashlib.sha256(data).hexdigest()}:{os.getuid()}", flush=True)
  '';
  argvPackage = factory {
    exe = lib.getExe argvFixture;
    outName = "sandbox-argv-fixture";
  };
  factory = self.lib.ai.mkSandbox pkgs;
  package = factory args;
  guest = package.guest.config;
  # Reports the guest clone; the first argument names, relative to the clone, a
  # host-only uncommitted file that must
  # be absent. The source is read from the clone's alternates so the stub check
  # and a real guest probe the same share.
  repoProbe = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-repo-probe";
    runtimeInputs = [pkgs.coreutils pkgs.git];
    text = ''
      export GIT_PAGER=cat
      src="$(dirname "$(< .git/objects/info/alternates)")"
      echo "REPO_PWD=$PWD"
      echo "REPO_SRC=$src"
      echo "REPO_HEAD=$(git rev-parse HEAD)"
      git log -1 --format='REPO_LOG=%H %s'
      echo "REPO_STATUS_LINES=$(git status --porcelain | wc -l)"
      if [[ -e $1 ]]; then echo REPO_HOST_ONLY=present; else echo REPO_HOST_ONLY=absent; fi
      echo "REPO_DU_GIT_KIB=$(du -sk .git | cut -f1)"
      echo "REPO_DU_TREE_KIB=$(du -sk --exclude=.git . | cut -f1)"
      if touch "$src/sandbox-write" 2>/dev/null || mkdir "$src/objects/sandbox-write" 2>/dev/null; then
        echo REPO_WRITE=allowed
      else
        echo REPO_WRITE=denied
      fi
      grep -F " $src " /proc/mounts | sed 's/^/REPO_MOUNT=/' || :
      start=$EPOCHREALTIME
      git -c safe.directory='*' clone --quiet --shared --no-checkout "$src" "''${TMPDIR:-/tmp}/second-clone"
      git -C "''${TMPDIR:-/tmp}/second-clone" -c advice.detachedHead=false checkout --quiet --detach "$(git rev-parse HEAD)"
      echo "REPO_SECOND_CLONE_SECONDS=$(echo "$EPOCHREALTIME - $start" | ${pkgs.bc}/bin/bc)"
    '';
  };
  repoPackage = factory {
    exe = lib.getExe repoProbe;
    outName = "sandbox-repo-probe";
    repo = true;
  };
  moduleConfig.ai.sandboxes.sandbox-hello = builtins.removeAttrs args ["outName"];
  statusFixture = pkgs.writeScriptBin "sandbox-status-fixture" ''
    #!${lib.getExe pkgs.python3}
    import os, signal, sys
    port = "/dev/virtio-ports/sandbox.status"
    assert os.stat(port).st_mode & 0o777 == 0o600
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
        (evalHm {}).config.home.packages
        == []
        && (evalDevenv {}).config.packages == []
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
        ${pkgs.gnugrep}/bin/grep -Fx ${lib.escapeShellArg (builtins.unsafeDiscardStringContext (toString argvFixture))} \
          ${pkgs.closureInfo {rootPaths = [argvPackage];}}/store-paths
        touch "$out"
      '';
      microvm-sandbox-argv-launcher = argvPackage;
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
        && builtins.elem "virtserialport,chardev=status,name=sandbox.status" guest.microvm.qemu.extraArgs
        && builtins.elem "qemu_fw_cfg" guest.boot.kernelModules
        && builtins.elem "virtio_console" guest.boot.kernelModules
        && builtins.elem "dev-virtio\\x2dports-sandbox.status.device" guest.systemd.services.sandbox.requires
        && lib.hasInfix ''OWNER="root", GROUP="root", MODE="0600"'' guest.services.udev.extraRules
        && lib.hasPrefix "+/nix/store/" guest.systemd.services.sandbox.serviceConfig.ExecStopPost
        && builtins.all (a: a.assertion) guest.assertions
      );
      microvm-sandbox-invalid-name = mkTest "microvm-sandbox-invalid-name" (
        builtins.attrNames (builtins.functionArgs factory)
        == ["exe" "outName" "repo"]
        && !(builtins.tryEval (factory (args // {exe = "hello";}))).success
        && !(builtins.tryEval (factory (args // {repo = "yes";}))).success
        && !(builtins.tryEval (factory (args // {outName = "../hello";}))).success
      );
      microvm-sandbox-launcher = package;
      microvm-sandbox-modules = mkTest "microvm-sandbox-modules" (
        map (p: p.drvPath) (evalHm moduleConfig).config.home.packages
        == [package.drvPath]
        && map (p: p.drvPath) (evalDevenv moduleConfig).config.packages == [package.drvPath]
        && (evalHm moduleConfig).config.ai.sandboxes.sandbox-hello.outName == "sandbox-hello"
      );
      microvm-sandbox-repo = pkgs.runCommand "microvm-sandbox-repo" {nativeBuildInputs = [pkgs.git];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${lib.getExe pkgs.python3} ${./repo.py} \
          ${lib.getExe repoPackage} \
          ${repoPackage.guest.config.microvm.declaredRunner}/bin/microvm-run \
          ${repoPackage.guest.config.systemd.services.sandbox.serviceConfig.ExecStart} \
          ${lib.getExe pkgs.python3}
        touch "$out"
      '';
      microvm-sandbox-repo-guest = mkTest "microvm-sandbox-repo-guest" (
        let
          g = repoPackage.guest.config;
          share = lib.last g.microvm.shares;
        in
          share.source
          == "repo"
          && share.mountPoint == "/mnt/repo"
          && share.readOnly
          && builtins.elem "ro" g.fileSystems."/mnt/repo".options
          && builtins.elem "name=opt/sandbox.repo-head,file=repo-head" g.microvm.qemu.extraArgs
          && g.systemd.services.sandbox.unitConfig.RequiresMountsFor == "/mnt/repo"
          && builtins.length guest.microvm.shares == 1
      );
      microvm-sandbox-repo-launcher = repoPackage;
      microvm-sandbox-status-launcher = factory {
        exe = lib.getExe statusFixture;
        outName = "sandbox-status-fixture";
      };
    };
}
