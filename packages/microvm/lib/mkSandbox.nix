# cspell:ignore vcpu
{
  inputs,
  lib,
}: pkgs: {
  exe,
  outName,
}: let
  validName = name: builtins.isString name && builtins.match "[a-zA-Z0-9][a-zA-Z0-9._+-]*" name != null;
  guestCommand = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-exec";
    text = ''
      mapfile -d "" -t args < /run/sandbox/argv
      exec ${lib.escapeShellArg exe} "''${args[@]}"
    '';
  };
  guest = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      inputs.microvm.nixosModules.microvm
      {
        boot.kernelModules = ["qemu_fw_cfg"];
        fileSystems."/nix/.rw-store" = {
          fsType = "tmpfs";
          neededForBoot = true;
          options = ["mode=0755"];
        };
        microvm = {
          hypervisor = "qemu";
          interfaces = [];
          mem = 1024;
          qemu.extraArgs = ["-fw_cfg" "name=opt/sandbox.argv,file=argv"];
          shares = [
            {
              mountPoint = "/nix/.ro-store";
              proto = "9p";
              readOnly = true;
              source = "/nix/store";
              tag = "store";
            }
          ];
          socket = null;
          storeOnDisk = false;
          vcpu = 1;
          writableStoreOverlay = "/nix/.rw-store";
        };
        networking.hostName = "sandbox";
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;
        system.stateVersion = "26.05";
        systemd.services = {
          sandbox = {
            after = ["systemd-modules-load.service" "systemd-user-sessions.service"];
            serviceConfig = {
              ExecStart = lib.getExe guestCommand;
              ExecStartPre = "+${pkgs.coreutils}/bin/install -m 0444 /sys/firmware/qemu_fw_cfg/by_name/opt/sandbox.argv/raw /run/sandbox/argv";
              # Reboot stops the upstream QEMU runner, which uses -no-reboot.
              ExecStopPost = "+${pkgs.systemd}/bin/systemctl --no-block reboot";
              RuntimeDirectory = "sandbox";
              RuntimeDirectoryMode = "0700";
              StandardError = "tty";
              StandardInput = "tty-force";
              StandardOutput = "tty";
              TTYPath =
                if pkgs.stdenv.hostPlatform.isx86_64
                then "/dev/ttyS0"
                else "/dev/ttyAMA0";
              User = "sandbox";
              WorkingDirectory = "/home/sandbox";
            };
            wantedBy = ["multi-user.target"];
          };
          "serial-getty@ttyAMA0".enable = false;
          "serial-getty@ttyS0".enable = false;
        };
        users.users.sandbox = {
          home = "/home/sandbox";
          isNormalUser = true;
        };
      }
    ];
  };
  runner = guest.config.microvm.declaredRunner;
in
  assert lib.assertMsg pkgs.stdenv.hostPlatform.isLinux "mkSandbox requires a Linux host package set";
  assert lib.assertMsg (builtins.isString exe && lib.hasPrefix "/" exe) "mkSandbox.exe must be an absolute executable path";
  assert lib.assertMsg (validName outName) "mkSandbox.outName must be a single executable name";
    (import ../../../lib/strict-shell-application.nix pkgs {
      name = outName;
      text = ''
        if (( $# != 0 )); then
          if [[ $1 != -- ]]; then
            echo '${outName}: sandbox options are not supported; use -- before guest arguments' >&2
            exit 2
          fi
          shift
        fi
        if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
          echo '${outName}: /dev/kvm must be readable and writable; enable KVM and grant your user access to the kvm group' >&2
          exit 1
        fi
        runtime_dir="$(${pkgs.coreutils}/bin/mktemp -d -t ${outName}.XXXXXXXX)"
        trap '${pkgs.coreutils}/bin/rm -rf -- "$runtime_dir"' EXIT
        cd "$runtime_dir"
        umask 077
        : > argv
        if (( $# != 0 )); then
          printf '%s\0' "$@" > argv
        fi
        ${runner}/bin/microvm-run
      '';
    }).overrideAttrs (old: {
      passthru = (old.passthru or {}) // {inherit guest;};
    })
