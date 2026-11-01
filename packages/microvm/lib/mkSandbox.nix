# cspell:ignore chardev dports guestfwd netdev networkd romfile slirp vcpu virtio virtserialport
{
  inputs,
  lib,
}: pkgs: {
  doors ? [],
  exe,
  outName,
}: let
  # Doors: one restricted user-mode NIC; each door is a guestfwd whose host
  # command QEMU runs with the guest TCP connection on stdin and stdout.
  doorAddress = "10.0.2.100";
  doorMac = "02:00:00:00:d0:01";
  validDoor = door:
    builtins.isAttrs door
    && builtins.attrNames door == ["command" "port"]
    && builtins.isInt door.port
    && door.port >= 1
    && door.port <= 65535
    && builtins.isString door.command
    && builtins.match "/[a-zA-Z0-9._+/-]+" door.command != null;
  doorNetdev = lib.concatStringsSep "," (
    ["user" "id=doors" "restrict=on" "net=10.0.2.0/24"]
    ++ map (door: "guestfwd=tcp:${doorAddress}:${toString door.port}-cmd:${door.command}") doors
  );
  validName = name: builtins.isString name && builtins.match "[a-zA-Z0-9][a-zA-Z0-9._+-]*" name != null;
  guestCommand = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-exec";
    text = ''
      mapfile -d "" -t args < /run/sandbox/argv
      exec ${lib.escapeShellArg exe} "''${args[@]}"
    '';
  };
  guestCompletion = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-completion";
    text = ''
      # Reboot stops the upstream runner, which uses -no-reboot, even if reporting fails.
      trap '${pkgs.systemd}/bin/systemctl --no-block reboot' EXIT
      case "''${SERVICE_RESULT:-}" in
        success|exit-code|signal|core-dump)
          if [[ -n ''${EXIT_CODE:-} && -n ''${EXIT_STATUS:-} ]]; then
            printf '%s:%s\n' "$EXIT_CODE" "$EXIT_STATUS" > /dev/virtio-ports/sandbox.status
          fi
          ;;
        *) ;;
      esac
    '';
  };
  guest = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      inputs.microvm.nixosModules.microvm
      {
        boot.kernelModules = ["qemu_fw_cfg" "virtio_console"];
        fileSystems."/nix/.rw-store" = {
          fsType = "tmpfs";
          neededForBoot = true;
          options = ["mode=0755"];
        };
        microvm = {
          hypervisor = "qemu";
          interfaces = [];
          mem = 1024;
          qemu.extraArgs =
            [
              "-fw_cfg"
              "name=opt/sandbox.argv,file=argv"
              "-device"
              "virtio-serial-pci"
              "-chardev"
              "file,id=status,path=status"
              "-device"
              "virtserialport,chardev=status,name=sandbox.status"
            ]
            ++ lib.optionals (doors != []) [
              "-netdev"
              doorNetdev
              "-device"
              "virtio-net-pci,netdev=doors,mac=${doorMac},romfile="
            ];
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
        networking = lib.mkMerge [
          {hostName = "sandbox";}
          (lib.mkIf (doors != []) {
            useDHCP = false;
            useNetworkd = true;
          })
        ];
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;
        services.udev.extraRules = ''
          SUBSYSTEM=="virtio-ports", ATTR{name}=="sandbox.status", OWNER="root", GROUP="root", MODE="0600"
        '';
        system.stateVersion = "26.05";
        systemd.network.networks = lib.mkIf (doors != []) {
          "10-doors" = {
            address = ["10.0.2.15/24"];
            # A default route sends stray traffic into slirp, where restrict=on
            # must drop it, instead of failing early in the guest.
            gateway = ["10.0.2.2"];
            linkConfig.RequiredForOnline = "routable";
            matchConfig.MACAddress = doorMac;
            networkConfig.LinkLocalAddressing = "no";
          };
        };
        systemd.services = {
          sandbox = {
            after =
              ["dev-virtio\\x2dports-sandbox.status.device" "systemd-modules-load.service" "systemd-user-sessions.service"]
              ++ lib.optional (doors != []) "network-online.target";
            requires = ["dev-virtio\\x2dports-sandbox.status.device"];
            wants = lib.optional (doors != []) "network-online.target";
            serviceConfig = {
              ExecStart = lib.getExe guestCommand;
              ExecStartPre = "+${pkgs.coreutils}/bin/install -m 0444 /sys/firmware/qemu_fw_cfg/by_name/opt/sandbox.argv/raw /run/sandbox/argv";
              ExecStopPost = "+${lib.getExe guestCompletion}";
              RuntimeDirectory = "sandbox";
              RuntimeDirectoryMode = "0700";
              StandardError = "tty";
              StandardInput = "tty-force";
              StandardOutput = "tty";
              TTYPath =
                if pkgs.stdenv.hostPlatform.isx86_64
                then "/dev/ttyS0"
                else "/dev/ttyAMA0";
              Type = "exec";
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
  assert lib.assertMsg (builtins.isList doors && builtins.all validDoor doors) "mkSandbox.doors entries must be {port; command;} with a TCP port and an absolute command path of letters, digits and ._+/-";
  assert lib.assertMsg (builtins.length (lib.unique (map (door: door.port) doors)) == builtins.length doors) "mkSandbox.doors ports must be unique";
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
        : > status
        if ${runner}/bin/microvm-run; then
          status="$(< status)"
          if [[ $status =~ ^exited:([0-9]{1,3})$ ]] && (( 10#''${BASH_REMATCH[1]} <= 255 )); then
            exit "$((10#''${BASH_REMATCH[1]}))"
          elif [[ $status =~ ^(killed|dumped):([A-Z0-9+]+)$ ]]; then
            signal="''${BASH_REMATCH[2]}"
            if [[ ! $signal =~ ^[0-9]+$ ]]; then
              signal=$(kill -l "$signal") || signal=0
            fi
            if [[ $signal =~ ^[0-9]{1,2}$ ]] && (( 10#$signal >= 1 && 10#$signal <= 64 )); then
              exit "$((128 + 10#$signal))"
            fi
          fi
          echo '${outName}: VM stopped without a valid guest completion status' >&2
        else
          echo '${outName}: VM runner failed' >&2
        fi
        exit 125
      '';
    }).overrideAttrs (old: {
      passthru = (old.passthru or {}) // {inherit guest;};
    })
