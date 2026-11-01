# cspell:ignore chardev dports vcpu virtio virtserialport
{
  inputs,
  lib,
}: pkgs: {
  exe,
  outName,
  # Spike: share the launch directory's Git repository read-only and start the
  # process in a guest clone of its HEAD.
  repo ? false,
}: let
  git = lib.getExe pkgs.git;
  validName = name: builtins.isString name && builtins.match "[a-zA-Z0-9][a-zA-Z0-9._+-]*" name != null;
  guestCommand = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-exec";
    text =
      ''
        mapfile -d "" -t args < /run/sandbox/argv
      ''
      + lib.optionalString repo ''
        head="$(< /run/sandbox/repo-head)"
        ${git} -c safe.directory='*' clone --quiet --shared --no-checkout /mnt/repo /home/sandbox/repo
        ${git} -C /home/sandbox/repo -c advice.detachedHead=false checkout --quiet --detach "$head"
        cd /home/sandbox/repo
      ''
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
        fileSystems =
          {
            "/nix/.rw-store" = {
              fsType = "tmpfs";
              neededForBoot = true;
              options = ["mode=0755"];
            };
          }
          // lib.optionalAttrs repo {"/mnt/repo".options = ["ro"];};
        microvm = {
          hypervisor = "qemu";
          interfaces = [];
          mem = 1024;
          qemu.extraArgs =
            lib.optionals repo [
              "-fw_cfg"
              "name=opt/sandbox.repo-head,file=repo-head"
            ]
            ++ [
              "-fw_cfg"
              "name=opt/sandbox.argv,file=argv"
              "-device"
              "virtio-serial-pci"
              "-chardev"
              "file,id=status,path=status"
              "-device"
              "virtserialport,chardev=status,name=sandbox.status"
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
            # A relative source resolves against the runner's working
            # directory, the per-launch runtime directory, where the launcher
            # links `repo` to the Git common directory.
            ++ lib.optional repo {
              mountPoint = "/mnt/repo";
              proto = "9p";
              readOnly = true;
              source = "repo";
              tag = "repo";
            };
          socket = null;
          storeOnDisk = false;
          vcpu = 1;
          writableStoreOverlay = "/nix/.rw-store";
        };
        networking.hostName = "sandbox";
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;
        services.udev.extraRules = ''
          SUBSYSTEM=="virtio-ports", ATTR{name}=="sandbox.status", OWNER="root", GROUP="root", MODE="0600"
        '';
        system.stateVersion = "26.05";
        systemd.services = {
          sandbox = {
            after = ["dev-virtio\\x2dports-sandbox.status.device" "systemd-modules-load.service" "systemd-user-sessions.service"];
            requires = ["dev-virtio\\x2dports-sandbox.status.device"];
            serviceConfig = {
              ExecStart = lib.getExe guestCommand;
              ExecStartPre =
                map (name: "+${pkgs.coreutils}/bin/install -m 0444 /sys/firmware/qemu_fw_cfg/by_name/opt/sandbox.${name}/raw /run/sandbox/${name}")
                (["argv"] ++ lib.optional repo "repo-head");
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
            unitConfig = lib.optionalAttrs repo {RequiresMountsFor = "/mnt/repo";};
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
  assert lib.assertMsg (builtins.isBool repo) "mkSandbox.repo must be a boolean";
    (import ../../../lib/strict-shell-application.nix pkgs {
      name = outName;
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
        + lib.optionalString repo ''
          # A linked worktree shares its common directory; the guest checks out
          # this worktree's HEAD from it.
          if ! repo_git_dir="$(${git} rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
            || ! repo_head="$(${git} rev-parse --verify --quiet 'HEAD^{commit}')"; then
            echo '${outName}: run inside a Git checkout with at least one commit' >&2
            exit 2
          fi
        ''
        + ''
          runtime_dir="$(${pkgs.coreutils}/bin/mktemp -d -t ${outName}.XXXXXXXX)"
          trap '${pkgs.coreutils}/bin/rm -rf -- "$runtime_dir"' EXIT
          cd "$runtime_dir"
          umask 077
          : > argv
          if (( $# != 0 )); then
            printf '%s\0' "$@" > argv
          fi
          : > status
        ''
        + lib.optionalString repo ''
          ${pkgs.coreutils}/bin/ln -s -- "$repo_git_dir" repo
          printf '%s' "$repo_head" > repo-head
        ''
        + ''
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
