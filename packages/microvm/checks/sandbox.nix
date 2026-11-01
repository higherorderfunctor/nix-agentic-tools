# cspell:ignore chardev dports virtio objectname vcpu vcpus virtserialport
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
  # Guest-side assertions: each fixture exits non-zero when the guest disagrees.
  # They need KVM, so they are launchers to run, not sandboxed builds.
  mkGuestScript = name: text:
    import ../../../lib/strict-shell-application.nix pkgs {
      inherit name text;
      runtimeInputs = [pkgs.coreutils pkgs.gnugrep];
    };
  packagesFixture = mkGuestScript "sandbox-packages-fixture" ''
    git --version | grep -Fx 'git version ${pkgs.git.version}'
    rg --version | head -n 1 | grep -Fx 'ripgrep ${pkgs.ripgrep.version}'
    # Simulate a harness shell that resets PATH to the guest system profile.
    ${lib.getExe pkgs.bash} -c '
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export PATH=/run/current-system/sw/bin
      git --version
      rg --version
    '
    echo SANDBOX_PACKAGES_OK
  '';
  packagesPackage = factory {
    exe = lib.getExe packagesFixture;
    outName = "sandbox-packages-fixture";
    packages = [pkgs.git pkgs.ripgrep];
  };
  sizeFixture = mkGuestScript "sandbox-size-fixture" ''
    [[ $(nproc) == "$1" ]]
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    # MemTotal excludes kernel reservations: accept 75%-100% of the request.
    (( mem_kb * 1024 <= $2 * 1048576 && mem_kb * 1024 >= $2 * 1048576 * 3 / 4 ))
    echo "SANDBOX_SIZE_OK nproc=$(nproc) MemTotal_kB=$mem_kb"
  '';
  mkSizePackage = memory: vcpus:
    factory {
      exe = lib.getExe sizeFixture;
      outName = "sandbox-size-${toString memory}-${toString vcpus}";
      inherit memory vcpus;
      packages = [pkgs.gawk];
    };
  sizeDefault = mkSizePackage 1024 1;
  sizeLarge = mkSizePackage 4096 2;
  package = factory args;
  guest = package.guest.config;
  # `recover` creates work for a graceful-shutdown recovery smoke boot.
  repoProbe = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-repo-probe";
    runtimeInputs = [pkgs.coreutils pkgs.git];
    text = ''
      echo "REPO_PWD=$PWD"
      echo "REPO_HEAD=$(git rev-parse --verify --quiet HEAD || :)"
      echo "REPO_BRANCH=$(git symbolic-ref --quiet --short HEAD || :)"
      echo "REPO_STATUS_LINES=$(git status --porcelain | wc -l)"
      if [[ -e ''${1:-uncommitted} ]]; then echo REPO_HOST_ONLY=present; else echo REPO_HOST_ONLY=absent; fi
      git for-each-ref --format='REPO_REF=%(refname):%(objectname)'
      if [[ ''${1:-} == recover ]]; then
        git -c user.name=sandbox-fixture -c user.email=sandbox@example.invalid commit --quiet --allow-empty -m sandbox-recovery-fixture
        echo "REPO_RECOVER_HEAD=$(git rev-parse HEAD)"
        echo REPO_READY_FOR_HOST_GC
        sleep 10
        git fsck --no-dangling
        echo REPO_OBJECTS_AFTER_GC_OK
      fi
    '';
  };
  repoPackage = factory {
    exe = lib.getExe repoProbe;
    outName = "sandbox-repo-probe";
    repo = true;
  };
  repoRootProbe = mkGuestScript "sandbox-repo-root-probe" ''
    [[ $(id -u) == 0 ]]
    for directory in /mnt/objects /run/sandbox/seed; do
      if touch "$directory/sandbox-root-write-probe" 2>/dev/null; then
        echo "REPO_ROOT_WRITE=allowed:$directory" >&2
        exit 1
      fi
      echo "REPO_ROOT_WRITE=denied:$directory"
    done
  '';
  repoRootGuest = repoPackage.guest.extendModules {
    modules = [{systemd.services.sandbox.serviceConfig.ExecStartPre = lib.mkAfter ["+${lib.getExe repoRootProbe}"];}];
  };
  # The smoke launcher changes only the runner, preserving production host setup.
  repoRootPackage = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-repo-root-probe";
    runtimeInputs = [pkgs.coreutils pkgs.gnused];
    text = ''
      fixture_launcher=$(mktemp)
      trap 'rm -f -- "$fixture_launcher"' EXIT
      sed 's|${repoPackage.guest.config.microvm.declaredRunner}/bin/microvm-run|${repoRootGuest.config.microvm.declaredRunner}/bin/microvm-run|' ${lib.getExe repoPackage} > "$fixture_launcher"
      chmod 0700 "$fixture_launcher"
      "$fixture_launcher" "$@"
    '';
  };
  mkLintedCheck = import ../../../lib/mk-linted-check.nix {inherit pkgs;};
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
      microvm-sandbox-argv = mkLintedCheck "microvm-sandbox-argv" {
        text = ''
          ${lib.getExe pkgs.python3} ${./argv.py} \
            ${lib.getExe argvPackage} \
            ${argvPackage.guest.config.microvm.declaredRunner}/bin/microvm-run \
            ${argvPackage.guest.config.systemd.services.sandbox.serviceConfig.ExecStart} \
            ${lib.getExe pkgs.python3} \
            ${lib.removePrefix "+" argvPackage.guest.config.systemd.services.sandbox.serviceConfig.ExecStopPost} \
            ${pkgs.systemd}/bin/systemctl
          ${pkgs.gnugrep}/bin/grep -Fx ${lib.escapeShellArg (builtins.unsafeDiscardStringContext (toString argvFixture))} \
            ${pkgs.closureInfo {rootPaths = [argvPackage];}}/store-paths
        '';
      };
      microvm-sandbox-argv-launcher = argvPackage;
      microvm-sandbox-duplicate-name = mkTest "microvm-sandbox-duplicate-name" (
        let
          duplicate.ai.sandboxes = {
            a = args;
            b = args;
          };
          rejected = result: builtins.any (a: !a.assertion && lib.hasPrefix "ai.claims.command.sandbox-hello:" a.message) result.config.assertions;
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
        && lib.all (package: builtins.elem package packagesPackage.guest.config.environment.systemPackages) [pkgs.git pkgs.ripgrep]
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
        == ["exe" "memory" "outName" "packages" "repo" "vcpus"]
        && (builtins.functionArgs factory).memory
        && (builtins.functionArgs factory).packages
        && (builtins.functionArgs factory).repo
        && (builtins.functionArgs factory).vcpus
        && !(builtins.functionArgs factory).exe
        && !(builtins.tryEval (factory (args // {memory = 0;}))).success
        && !(builtins.tryEval (factory (args // {vcpus = 0;}))).success
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
      microvm-sandbox-packages-launcher = packagesPackage;
      microvm-sandbox-repo = mkLintedCheck "microvm-sandbox-repo" {
        runtimeInputs = [pkgs.git];
        text = ''
          ${lib.getExe pkgs.python3} ${./repo.py} \
            ${lib.getExe repoPackage} \
            ${repoPackage.guest.config.microvm.declaredRunner}/bin/microvm-run \
            ${repoPackage.guest.config.systemd.services.sandbox.serviceConfig.ExecStart} \
            ${lib.getExe pkgs.python3} \
            ${lib.getExe repoPackage.repoExport}
        '';
      };
      microvm-sandbox-repo-guest = mkTest "microvm-sandbox-repo-guest" (
        let
          g = repoPackage.guest.config;
          shares = builtins.listToAttrs (map (share: {
              name = share.source;
              value = share;
            })
            g.microvm.shares);
        in
          builtins.length g.microvm.shares
          == 3
          && shares.objects.mountPoint == "/mnt/objects"
          && shares.objects.readOnly
          && shares.seed.mountPoint == "/run/sandbox/seed"
          && shares.seed.readOnly
          && builtins.elem "ro" g.fileSystems."/mnt/objects".options
          && builtins.elem "ro" g.fileSystems."/run/sandbox/seed".options
          && builtins.all (name: builtins.elem "name=opt/sandbox.${name},file=${name}" g.microvm.qemu.extraArgs) ["repo-branch" "repo-head" "seed-roots"]
          && g.systemd.services.sandbox.serviceConfig.RuntimeDirectory == "sandbox-command"
          && g.systemd.services.sandbox.unitConfig.RequiresMountsFor == ["/mnt/objects" "/run/sandbox/seed"]
          && lib.hasInfix "directory = /mnt/objects" g.environment.etc.gitconfig.text
          && lib.hasInfix "directory = /run/sandbox/seed" g.environment.etc.gitconfig.text
          && !lib.hasInfix "*" g.environment.etc.gitconfig.text
          && builtins.elem "+${pkgs.coreutils}/bin/install -m 0444 /sys/firmware/qemu_fw_cfg/by_name/opt/sandbox.seed-roots/raw /run/sandbox-seed-roots" g.systemd.services.sandbox.serviceConfig.ExecStartPre
          && builtins.length guest.microvm.shares == 1
      );
      microvm-sandbox-repo-launcher = repoPackage;
      microvm-sandbox-repo-root-launcher = repoRootPackage;
      microvm-sandbox-size = mkTest "microvm-sandbox-size" (
        let
          big = sizeLarge.guest.config;
          small = sizeDefault.guest.config;
        in
          guest.microvm.mem
          == 1024
          && guest.microvm.vcpu == 1
          && small.microvm.mem == 1024
          && big.microvm.mem == 4096
          && big.microvm.vcpu == 2
      );
      microvm-sandbox-size-default-launcher = sizeDefault;
      microvm-sandbox-size-large-launcher = sizeLarge;
      microvm-sandbox-status-launcher = factory {
        exe = lib.getExe statusFixture;
        outName = "sandbox-status-fixture";
      };
    };
}
