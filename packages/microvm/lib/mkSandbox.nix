# cspell:ignore chardev dports guestfwd libslirp netdev networkd romfile setsid slirp vcpu vcpus virtio virtserialport
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
  repoConfig ? false,
  signing ? null,
  vcpus ? 1,
}: let
  agentSocket = "/run/sandbox/agent.sock";
  # QEMU executes one wrapper per connection with its socket on stdin/stdout.
  doorAddress = "10.0.2.100";
  doorMac = "02:00:00:00:d0:01";
  guestRepo = import ./repo-guest.nix {inherit lib pkgs;};
  hostRepo = import ./repo-host.nix {inherit lib pkgs;};
  # The command starts in a Git checkout, so its shells need Git on PATH.
  guestPackages = packages ++ lib.optional repo pkgs.git;
  allDoors =
    doors
    ++ lib.optional (signing != null) {
      # The filter passes only key listing and Git signature requests.
      command = "${pkgs.python3}/bin/python3";
      arguments = ["-I" "${./agent-filter.py}" signing.socket];
      inherit (signing) port;
    };
  hasDoors = allDoors != [];
  # Door arguments sit in this wrapper in the Nix store, which the guest mounts,
  # so the guest can read them. Secrets must come from a runtime file in the
  # launcher's directory that the command reads when it starts.
  doorWrapper = door:
    import ../../../lib/strict-shell-application.nix pkgs {
      name = "sandbox-door-${toString door.port}";
      text = ''
        # libslirp starts each guestfwd command with setsid and without a shell,
        # so this process is its own group leader and launcher cleanup can kill
        # the group, command included. Cleanup ignores a record whose group is
        # not its pid.
        pid_file="door-${toString door.port}-$$.pid"
        temporary_pid_file="$pid_file.tmp"
        # Publish the complete identity before the command can communicate with the guest.
        trap '${pkgs.coreutils}/bin/rm -f -- "$pid_file" "$temporary_pid_file"' EXIT
        # Fields after the parenthesised comm, as the launcher cleanup reads them:
        # index 19 is the start time. comm may contain spaces or a closing parenthesis.
        IFS= read -r stat < /proc/self/stat
        read -r -a process <<< "''${stat##*) }"
        printf '%s %s\n' "$$" "''${process[19]}" > "$temporary_pid_file"
        ${pkgs.coreutils}/bin/mv -- "$temporary_pid_file" "$pid_file"
        ${pkgs.coreutils}/bin/env -i \
          ${door.command} ${lib.concatMapStrings (argument: "${lib.escapeShellArg argument} ") door.arguments}2>> doors.log
      '';
    };
  validAbsolutePath = value: builtins.isString value && builtins.match "/[a-zA-Z0-9._+/-]+" value != null;
  validDoor = door:
    lib.subtractLists ["arguments" "command" "port"] (builtins.attrNames door)
    == []
    && door ? command
    && door ? port
    && validPort door.port
    && validAbsolutePath door.command
    && builtins.isList door.arguments
    && builtins.all builtins.isString door.arguments;
  normalizedDoors = map (door: {arguments = [];} // door) allDoors;
  validPort = port: builtins.isInt port && port >= 1 && port <= 65535;
  validSigning =
    signing
    == null
    || (
      builtins.isAttrs signing
      && builtins.attrNames signing == ["port" "socket"]
      && validPort signing.port
      && validAbsolutePath signing.socket
    );
  doorNetdev = lib.concatStringsSep "," (
    ["user" "id=doors" "restrict=on" "net=10.0.2.0/24"]
    ++ map (door: "guestfwd=tcp:${doorAddress}:${toString door.port}-cmd:${lib.getExe (doorWrapper door)}") normalizedDoors
  );
  validName = name: builtins.isString name && builtins.match "[a-zA-Z0-9][a-zA-Z0-9._+-]*" name != null;
  guestCommand = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-exec";
    runtimeInputs = guestPackages;
    text =
      ''
        mapfile -d "" -t args < /run/sandbox/argv
      ''
      + lib.optionalString repo guestRepo.clone
      + lib.optionalString repoConfig guestRepo.configure
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
                directory = /mnt/seed
            '';
          };
          # A child shell resetting PATH still finds tools in the system profile.
          systemPackages = guestPackages;
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
            "/mnt/seed".options = ["ro"];
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
            ++ lib.optionals repoConfig ["-fw_cfg" "name=opt/sandbox.repo-config,file=repo-config"]
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
              # An empty romfile loads no option ROM: the guest boots a direct kernel,
              # so QEMU must neither search its data directory for the NIC's ROM
              # image nor offer the guest a network boot.
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
                mountPoint = "/mnt/seed";
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
              RuntimeDirectoryMode = "0700";
              Type = "exec";
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
                map (name: "+${pkgs.coreutils}/bin/install -m 0444 /sys/firmware/qemu_fw_cfg/by_name/opt/sandbox.${name}/raw /run/sandbox/${name}")
                (["argv"] ++ lib.optionals repo ["repo-head" "repo-branch"] ++ lib.optional repoConfig "repo-config")
                # The sandbox user owns its runtime directory, so roots live outside it.
                ++ lib.optional repo "+${pkgs.coreutils}/bin/install -m 0444 /sys/firmware/qemu_fw_cfg/by_name/opt/sandbox.seed-roots/raw /run/sandbox-seed-roots";
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
            unitConfig = lib.optionalAttrs repo {RequiresMountsFor = ["/mnt/seed"];};
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
    for pid_file in "$runtime_dir"/door-*.pid; do
      # A connection may finish and unlink its record while cleanup is reading it.
      { read -r pid start_time < "$pid_file"; } 2>/dev/null || continue
      if [[ $pid =~ ^[0-9]+$ && $start_time =~ ^[0-9]+$ ]] && IFS= read -r stat 2>/dev/null < "/proc/$pid/stat"; then
        # A stale PID can name an unrelated process; start time identifies the door.
        read -r -a process <<< "''${stat##*) }"
        if [[ ''${process[19]:-} == "$start_time" && ''${process[2]:-} == "$pid" ]]; then
          # Kill the connection's group, including a command the wrapper is waiting for.
          kill -KILL -- "-$pid" 2>/dev/null || :
        fi
      fi
    done
  '';
in
  assert lib.assertMsg pkgs.stdenv.hostPlatform.isLinux "mkSandbox requires a Linux host package set";
  assert lib.assertMsg (builtins.isString exe && lib.hasPrefix "/" exe) "mkSandbox.exe must be an absolute executable path";
  # ai.sandbox options refuse bad sizes first; these guard direct lib.ai.mkSandbox
  # callers, which have no option layer.
  assert lib.assertMsg (builtins.isInt memory && memory >= 128) "mkSandbox.memory must be an integer number of MiB, at least 128";
  assert lib.assertMsg (builtins.isInt vcpus && vcpus >= 1) "mkSandbox.vcpus must be a positive integer";
  assert lib.assertMsg (builtins.isList packages && builtins.all lib.isDerivation packages) "mkSandbox.packages must be a list of packages";
  assert lib.assertMsg (validName outName) "mkSandbox.outName must be a single executable name";
  assert lib.assertMsg validSigning "mkSandbox.signing must be null or {port; socket;} with a TCP port and an absolute host agent socket";
  assert lib.assertMsg (builtins.isList doors && builtins.all validDoor normalizedDoors) "mkSandbox.doors entries must be {port; command; arguments ? [];} with a TCP port, an absolute command path and string arguments";
  assert lib.assertMsg (builtins.length (lib.unique (map (door: door.port) allDoors)) == builtins.length allDoors) "mkSandbox.doors and mkSandbox.signing ports must be unique";
  assert lib.assertMsg (builtins.isBool repo) "mkSandbox.repo must be a boolean";
  assert lib.assertMsg (builtins.isBool repoConfig && (!repoConfig || repo)) "mkSandbox.repoConfig requires repo = true and reads SANDBOX_REPO_CONFIG and SANDBOX_SEED_OBJECTS at launch";
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
        + lib.optionalString repoConfig ''
          if [[ ''${SANDBOX_REPO_CONFIG:-} != /* || ''${SANDBOX_SEED_OBJECTS:-} != /* ]]; then
            echo '${outName}: repoConfig requires absolute SANDBOX_REPO_CONFIG and SANDBOX_SEED_OBJECTS paths' >&2
            exit 2
          fi
        ''
        + lib.optionalString repo hostRepo.prepare
        + ''
          runtime_dir="$(${pkgs.coreutils}/bin/mktemp -d -t ${outName}.XXXXXXXX)"
          # Invoked by the EXIT trap, including preparation failures.
          # shellcheck disable=SC2329
          cleanup() {
            ${runtimeDoorCleanup}
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
        + lib.optionalString repoConfig ''
          ${pkgs.coreutils}/bin/install -m 0600 -- "$SANDBOX_REPO_CONFIG" repo-config
          # The caller's relay session borrows the seed's objects through this link.
          ${pkgs.coreutils}/bin/ln -s -T -- "$runtime_dir/seed/objects" "$SANDBOX_SEED_OBJECTS"
        ''
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
          inherit doorAddress guest;
          # Only the repo check reads this, to run the guest export on the host.
          repoExport = guestRepo.export;
        };
    })
