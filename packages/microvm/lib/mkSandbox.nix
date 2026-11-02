# cspell:ignore chardev dports guestfwd netdev networkd romfile slirp vcpu vcpus virtio virtserialport
{
  inputs,
  lib,
}: pkgs: {
  doors ? [],
  exe,
  memory ? 1024,
  outName,
  packages ? [],
  repo ? false,
  signing ? null,
  vcpus ? 1,
}: let
  agentSocket = "/run/sandbox/agent.sock";
  # QEMU executes one wrapper per connection with its socket on stdin/stdout.
  doorAddress = "10.0.2.100";
  doorMac = "02:00:00:00:d0:01";
  guestRepo = import ./repo-guest.nix {inherit lib pkgs;};
  hostRepo = import ./repo-host.nix {inherit lib pkgs;};
  allDoors =
    doors
    ++ lib.optional (signing != null) {
      command = "${pkgs.socat}/bin/socat";
      arguments = ["STDIO" "UNIX-CONNECT:${signing.socket}"];
      inherit (signing) port;
    };
  hasDoors = allDoors != [];
  doorWrapper = door:
    import ../../../lib/strict-shell-application.nix pkgs {
      name = "sandbox-door-${toString door.port}";
      text = ''
        # QEMU can wait for and replace its initial shell. Keep one shell for the
        # connection lifetime so its PID remains available to launcher cleanup.
        if [[ -z ''${SANDBOX_DOOR_CHILD:-} ]]; then
          SANDBOX_DOOR_CHILD=1 "$0" "$@" <&0 >&1 &
          child=$!
          wait "$child"
          exit $?
        fi
        unset SANDBOX_DOOR_CHILD
        pid_file="door-${toString door.port}-$$.pid"
        temporary_pid_file="$pid_file.tmp"
        # Publish the complete identity before the command can communicate with the guest.
        trap '${pkgs.coreutils}/bin/rm -f -- "$pid_file" "$temporary_pid_file"' EXIT
        read -r -a process < /proc/self/stat
        printf '%s %s\n' "$$" "''${process[21]}" > "$temporary_pid_file"
        ${pkgs.coreutils}/bin/mv -- "$temporary_pid_file" "$pid_file"
        ${pkgs.coreutils}/bin/env -i \
          ${lib.concatStrings (lib.mapAttrsToList (name: value: "${lib.escapeShellArg "${name}=${value}"} ") door.environment)} \
          ${door.command} ${lib.concatMapStrings (argument: "${lib.escapeShellArg argument} ") (door.arguments or [])}2>> doors.log
      '';
    };
  validEnvironment = environment:
    builtins.isAttrs environment
    && builtins.all (
      name: builtins.isString environment.${name} && builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null
    ) (builtins.attrNames environment);
  validDoor = door:
    builtins.isAttrs door
    && builtins.elem (builtins.attrNames door) [["arguments" "command" "environment" "port"] ["command" "environment" "port"] ["command" "port"]]
    && builtins.isInt door.port
    && door.port >= 1
    && door.port <= 65535
    && builtins.isString door.command
    && builtins.match "/[a-zA-Z0-9._+/-]+" door.command != null
    && builtins.isList (door.arguments or [])
    && builtins.all builtins.isString (door.arguments or [])
    && validEnvironment door.environment;
  normalizedDoors = map (door:
    {
      arguments = [];
      environment = {};
    }
    // door)
  allDoors;
  validSigning = signing:
    builtins.isAttrs signing
    && builtins.attrNames signing == ["port" "socket"]
    && builtins.isInt signing.port
    && signing.port >= 1
    && signing.port <= 65535
    && builtins.isString signing.socket
    && lib.hasPrefix "/" signing.socket;
  doorNetdev = lib.concatStringsSep "," (
    ["user" "id=doors" "restrict=on" "net=10.0.2.0/24"]
    ++ map (door: "guestfwd=tcp:${doorAddress}:${toString door.port}-cmd:${lib.getExe (doorWrapper door)}") normalizedDoors
  );
  runtimeName =
    if repo
    then "sandbox-command"
    else "sandbox";
  validName = name: builtins.isString name && builtins.match "[a-zA-Z0-9][a-zA-Z0-9._+-]*" name != null;
  guestCommand = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-exec";
    runtimeInputs = packages;
    text =
      ''
        mapfile -d "" -t args < /run/${runtimeName}/argv
      ''
      + lib.optionalString repo guestRepo.clone
      + ''
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
          ${lib.optionalString repo ''
        if ${pkgs.util-linux}/bin/runuser -u sandbox -- ${lib.getExe guestRepo.export} > /dev/virtio-ports/sandbox.bundle; then
          bundle_status=ok
        else
          case $? in
            3) bundle_status=empty ;;
            *) bundle_status=failed ;;
          esac
        fi
        printf '%s\n' "$bundle_status" > /dev/virtio-ports/sandbox.bundle-status
      ''}
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
        environment = {
          etc = lib.optionalAttrs repo {
            gitconfig.text = ''
              [safe]
                directory = /mnt/objects
                directory = /run/sandbox/seed
            '';
          };
          # A child shell resetting PATH still finds tools in the system profile.
          systemPackages = packages;
        };
        fileSystems =
          {
            "/nix/.rw-store" = {
              fsType = "tmpfs";
              neededForBoot = true;
              options = ["mode=0755"];
            };
          }
          // lib.optionalAttrs repo {
            "/mnt/objects".options = ["ro"];
            "/run/sandbox/seed".options = ["ro"];
          };
        microvm = {
          hypervisor = "qemu";
          interfaces = [];
          mem = memory;
          qemu.extraArgs =
            ["-device" "virtio-serial-pci"]
            ++ lib.optionals repo [
              "-fw_cfg"
              "name=opt/sandbox.repo-branch,file=repo-branch"
              "-fw_cfg"
              "name=opt/sandbox.repo-head,file=repo-head"
              "-fw_cfg"
              "name=opt/sandbox.seed-roots,file=seed-roots"
              "-chardev"
              "file,id=bundle,path=bundle"
              "-device"
              "virtserialport,chardev=bundle,name=sandbox.bundle"
              "-chardev"
              "file,id=bundle-status,path=bundle-status"
              "-device"
              "virtserialport,chardev=bundle-status,name=sandbox.bundle-status"
            ]
            ++ [
              "-fw_cfg"
              "name=opt/sandbox.argv,file=argv"
              "-chardev"
              "file,id=status,path=status"
              "-device"
              "virtserialport,chardev=status,name=sandbox.status"
            ]
            ++ lib.optionals hasDoors [
              "-netdev"
              doorNetdev
              "-device"
              "virtio-net-pci,netdev=doors,mac=${doorMac},romfile="
            ];
          shares =
            [
              {
                mountPoint = "/nix/.ro-store";
                proto = "9p";
                readOnly = true;
                source = "/nix/store";
                tag = "store";
              }
            ]
            # Sources resolve against the launcher's private runtime directory.
            ++ lib.optionals repo [
              {
                mountPoint = "/mnt/objects";
                proto = "9p";
                readOnly = true;
                source = "objects";
                tag = "objects";
              }
              {
                mountPoint = "/run/sandbox/seed";
                proto = "9p";
                readOnly = true;
                source = "seed";
                tag = "seed";
              }
            ];
          socket = null;
          storeOnDisk = false;
          vcpu = vcpus;
          writableStoreOverlay = "/nix/.rw-store";
        };
        networking = lib.mkMerge [
          {hostName = "sandbox";}
          (lib.mkIf hasDoors {
            useDHCP = false;
            useNetworkd = true;
          })
        ];
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;
        services.udev.extraRules = lib.concatMapStringsSep "\n" (name: ''
          SUBSYSTEM=="virtio-ports", ATTR{name}=="sandbox.${name}", OWNER="root", GROUP="root", MODE="0600"
        '') (["status"] ++ lib.optionals repo ["bundle" "bundle-status"]);
        system.stateVersion = "26.05";
        systemd.network.networks = lib.mkIf hasDoors {
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
          sandbox-signing-agent = lib.mkIf (signing != null) {
            after = ["network-online.target"];
            before = ["sandbox.service"];
            requires = ["network-online.target"];
            serviceConfig = {
              ExecStart = "${pkgs.socat}/bin/socat UNIX-LISTEN:${agentSocket},fork,mode=0600 TCP:${doorAddress}:${toString signing.port}";
              Restart = "on-failure";
              RuntimeDirectory = "sandbox";
              User = "sandbox";
            };
            wantedBy = ["multi-user.target"];
          };
          sandbox = let
            portDevices = map (name: "dev-virtio\\x2dports-sandbox.${lib.replaceStrings ["-"] ["\\x2d"] name}.device") (["status"] ++ lib.optionals repo ["bundle" "bundle-status"]);
          in {
            after = portDevices ++ ["systemd-modules-load.service" "systemd-user-sessions.service"] ++ lib.optional hasDoors "network-online.target";
            requires = portDevices;
            wants = lib.optional hasDoors "network-online.target";
            serviceConfig = {
              Environment = lib.optional (signing != null) "SSH_AUTH_SOCK=${agentSocket}";
              ExecStart = lib.getExe guestCommand;
              ExecStartPre =
                map (name: "+${pkgs.coreutils}/bin/install -m 0444 /sys/firmware/qemu_fw_cfg/by_name/opt/sandbox.${name}/raw /run/${runtimeName}/${name}")
                (["argv"] ++ lib.optionals repo ["repo-head" "repo-branch"])
                # The sandbox user owns its runtime directory, so roots live outside it.
                ++ lib.optional repo "+${pkgs.coreutils}/bin/install -m 0444 /sys/firmware/qemu_fw_cfg/by_name/opt/sandbox.seed-roots/raw /run/sandbox-seed-roots";
              ExecStopPost = "+${lib.getExe guestCompletion}";
              RuntimeDirectory = runtimeName;
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
            unitConfig = lib.optionalAttrs repo {RequiresMountsFor = ["/mnt/objects" "/run/sandbox/seed"];};
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
  runtimeDoorCleanup = lib.optionalString hasDoors ''
    # QEMU leaves door children running if it dies during a connection.
    for pid_file in door-*.pid; do
      [[ -f $pid_file ]] || continue
      read -r pid start_time < "$pid_file"
      if [[ $pid =~ ^[0-9]+$ && $start_time =~ ^[0-9]+$ ]] && IFS= read -r stat 2>/dev/null < "/proc/$pid/stat"; then
        # A stale PID can name an unrelated process; start time identifies the door.
        read -r -a process <<< "''${stat##*) }"
        if [[ ''${process[19]:-} == "$start_time" ]]; then
          kill "$pid" 2>/dev/null || :
        fi
      fi
    done
  '';
in
  assert lib.assertMsg pkgs.stdenv.hostPlatform.isLinux "mkSandbox requires a Linux host package set";
  assert lib.assertMsg (builtins.isString exe && lib.hasPrefix "/" exe) "mkSandbox.exe must be an absolute executable path";
  assert lib.assertMsg (builtins.isInt memory && memory >= 128) "mkSandbox.memory must be an integer number of MiB, at least 128";
  assert lib.assertMsg (builtins.isInt vcpus && vcpus >= 1) "mkSandbox.vcpus must be a positive integer";
  assert lib.assertMsg (builtins.isList packages && builtins.all lib.isDerivation packages) "mkSandbox.packages must be a list of packages";
  assert lib.assertMsg (validName outName) "mkSandbox.outName must be a single executable name";
  assert lib.assertMsg (builtins.isList doors && builtins.all validDoor normalizedDoors) "mkSandbox.doors entries must be {port; command; arguments ? []; environment ? {};} with a TCP port, an absolute command path, string arguments and string environment values";
  assert lib.assertMsg (builtins.length (lib.unique (map (door: door.port) allDoors)) == builtins.length allDoors) "mkSandbox.doors and mkSandbox.signing ports must be unique";
  assert lib.assertMsg (builtins.isBool repo) "mkSandbox.repo must be a boolean";
  assert lib.assertMsg (signing == null || validSigning signing) "mkSandbox.signing must be null or {port; socket;} with a TCP port and an absolute host agent socket";
    (import ../../../lib/strict-shell-application.nix pkgs {
      name = outName;
      runtimeInputs = lib.optionals repo [pkgs.coreutils pkgs.git pkgs.util-linux];
      text =
        ''
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
        ''
        + lib.optionalString repo hostRepo.prepare
        + ''
          runtime_dir="$(${pkgs.coreutils}/bin/mktemp -d -t ${outName}.XXXXXXXX)"
          # Invoked by the EXIT trap, including preparation failures.
          # shellcheck disable=SC2329
          cleanup() {
            ${runtimeDoorCleanup}
            ${lib.optionalString repo hostRepo.cleanup}
            ${pkgs.coreutils}/bin/rm -rf -- "$runtime_dir"
          }
          trap cleanup EXIT
          trap 'exit 130' INT
          trap 'exit 143' TERM
          cd "$runtime_dir"
          umask 077
          : > argv
          if (( $# != 0 )); then
            printf '%s\0' "$@" > argv
          fi
          : > status
        ''
        + lib.optionalString repo hostRepo.start
        + ''
          if ${runner}/bin/microvm-run; then
            runner_status=0
          else
            runner_status=$?
            echo '${outName}: VM runner failed' >&2
          fi
        ''
        + lib.optionalString repo hostRepo.recover
        + lib.optionalString repo ''
          if (( recovery_failed )); then
            exit 125
          fi
        ''
        + ''
          if (( runner_status == 0 )); then
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
          fi
          exit 125
        '';
    }).overrideAttrs (old: {
      passthru =
        (old.passthru or {})
        // {
          inherit guest;
          repoExport = guestRepo.export;
        };
    })
