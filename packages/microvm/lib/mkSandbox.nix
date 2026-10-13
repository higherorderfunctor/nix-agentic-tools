# cspell:ignore vcpu
{
  inputs,
  lib,
}: pkgs: {
  binName,
  outName,
  pkg,
}: let
  validName = name: builtins.isString name && builtins.match "[a-zA-Z0-9][a-zA-Z0-9._+-]*" name != null;
  guest = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      inputs.microvm.nixosModules.microvm
      {
        fileSystems."/nix/.rw-store" = {
          fsType = "tmpfs";
          neededForBoot = true;
          options = ["mode=0755"];
        };
        microvm = {
          hypervisor = "qemu";
          interfaces = [];
          mem = 1024;
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
            after = ["systemd-user-sessions.service"];
            serviceConfig = {
              ExecStart = "${pkg}/bin/${binName}";
              # Reboot stops the upstream QEMU runner, which uses -no-reboot.
              ExecStopPost = "+${pkgs.systemd}/bin/systemctl --no-block reboot";
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
  assert lib.assertMsg (lib.isDerivation pkg) "mkSandbox.pkg must be a package";
  assert lib.assertMsg (validName binName) "mkSandbox.binName must be a single executable name";
  assert lib.assertMsg (validName outName) "mkSandbox.outName must be a single executable name";
    (import ../../../lib/strict-shell-application.nix pkgs {
      name = outName;
      text = ''
        if (( $# != 0 )); then
          echo '${outName}: arguments are not supported by this console sandbox' >&2
          exit 2
        fi
        if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
          echo '${outName}: /dev/kvm must be readable and writable; enable KVM and grant your user access to the kvm group' >&2
          exit 1
        fi
        runtime_dir="$(${pkgs.coreutils}/bin/mktemp -d -t ${outName}.XXXXXXXX)"
        trap '${pkgs.coreutils}/bin/rm -rf -- "$runtime_dir"' EXIT
        cd "$runtime_dir"
        ${runner}/bin/microvm-run
      '';
    }).overrideAttrs (old: {
      passthru = (old.passthru or {}) // {inherit guest;};
    })
