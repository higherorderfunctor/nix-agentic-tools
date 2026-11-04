# cspell:ignore chardev dports getppid guestfwd netdev objectname vcpu vcpus virtio virtserialport
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
  # Host side of the door: QEMU runs it per guest connection (measured), with
  # the connection on stdin and stdout. It reports its pid and descriptor
  # shape, marks stderr, then echoes lines until EOF.
  doorFixture = pkgs.writeScriptBin "sandbox-door-fixture" ''
    #!${lib.getExe pkgs.python3}
    import os, stat, sys
    print("PID", os.getppid(), "STDIN", "socket" if stat.S_ISSOCK(os.fstat(0).st_mode) else "other", "SAME", os.fstat(0).st_ino == os.fstat(1).st_ino, flush=True)
    print("MARKER", repr(os.environ.get("SANDBOX_DOOR_TEST_MARKER")), "PATH", repr(os.environ.get("PATH")), "VARIABLES", sorted(os.environ), flush=True)
    print("DOOR_STDERR_MUST_NOT_REACH_GUEST", file=sys.stderr, flush=True)
    if len(sys.argv) > 1 and sys.argv[1] == "hold":
        sys.stdin.read()
        sys.exit(0)
    for line in sys.stdin:
        print(f"ECHO {line.rstrip()}", flush=True)
    print("BYE", flush=True)
  '';
  doorGuestFixture = pkgs.writeScriptBin "sandbox-door-guest-fixture" ''
    #!${lib.getExe pkgs.python3}
    import os, socket, sys
    expected_path = ${builtins.toJSON "${pkgs.python3}/bin"}
    door = ("10.0.2.100", 7000)
    def open_door():
        s = socket.create_connection(door, timeout=10)
        return s, s.makefile("r")
    a, ra = open_door()
    header = ra.readline().split()
    assert header[0] == "PID" and header[2:] == ["STDIN", "socket", "SAME", "True"], header
    environment = ra.readline()
    # Python adds LC_CTYPE after the wrapper's env -i; it is not inherited.
    expected = f"MARKER None PATH {expected_path!r} VARIABLES ['LC_CTYPE', 'PATH']\n"
    assert environment == expected, (environment, expected)
    b, rb = open_door()
    other = rb.readline().split()
    assert other[1] != header[1], "one door process served two connections"
    rb.readline()
    a.sendall(b"one\n"); b.sendall(b"two\n")
    assert ra.readline() == "ECHO one\n" and rb.readline() == "ECHO two\n"
    a.shutdown(socket.SHUT_WR)
    assert ra.read() == "BYE\n"
    b.shutdown(socket.SHUT_WR)
    assert rb.read() == "BYE\n"
    print(f"PASS: door per connection ({header[1]} != {other[1]}), clean environment, host-only stderr, exit on EOF", flush=True)
    b.close()
    blocked = [("10.0.2.2", 22), ("10.0.2.2", 7000), ("10.0.2.3", 53), ("1.1.1.1", 443), ("10.0.2.100", 7001)]
    for target in blocked:
        try:
            socket.create_connection(target, timeout=3).close()
        except OSError as error:
            print(f"PASS: {target} blocked ({error!r})", flush=True)
        else:
            sys.exit(f"FAIL: {target} reachable")
    query = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01"
    for resolver in ["10.0.2.3", "1.1.1.1"]:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.settimeout(3)
        u.sendto(query, (resolver, 53))
        try:
            u.recvfrom(512)
        except OSError as error:
            print(f"PASS: DNS via {resolver} blocked ({error!r})", flush=True)
        else:
            sys.exit(f"FAIL: DNS via {resolver} answered")
  '';
  doorLifecycleGuestFixture = pkgs.writeScriptBin "sandbox-door-lifecycle-guest-fixture" ''
    #!${lib.getExe pkgs.python3}
    import socket, time
    connection = socket.create_connection(("10.0.2.100", 7000), timeout=10)
    stream = connection.makefile("r")
    print(stream.readline().strip(), flush=True)
    print("DOOR_HOLD_READY", flush=True)
    time.sleep(3600)
  '';
  doorLifecyclePackage = factory {
    doors = [fixtureDoor];
    exe = lib.getExe doorLifecycleGuestFixture;
    outName = "sandbox-door-lifecycle";
  };
  doorLifecycleCheck = mkGuestScript "sandbox-door-lifecycle-check" ''
    log=$(mktemp)
    export SANDBOX_DOOR_TEST_MARKER=must-not-reach-the-door
    ${lib.getExe doorLifecyclePackage} > "$log" 2>&1 &
    launcher_pid=$!
    # Invoked indirectly by traps.
    # shellcheck disable=SC2329
    cleanup() {
      status=$?
      if (( status != 0 )); then
        cat "$log"
      fi
      kill "$launcher_pid" 2>/dev/null || :
      wait "$launcher_pid" 2>/dev/null || :
      rm -f -- "$log"
    }
    trap cleanup EXIT
    door_pid=""
    for _ in {1..120}; do
      door_pid=$(sed -n 's/^PID \([0-9][0-9]*\) STDIN socket SAME True\r*$/\1/p' "$log")
      [[ -n $door_pid ]] && break
      kill -0 "$launcher_pid"
      sleep 1
    done
    [[ $door_pid =~ ^[0-9]+$ ]]
    runtime_dir=$(readlink "/proc/$launcher_pid/cwd")
    [[ $runtime_dir == /tmp/sandbox-door-lifecycle.* ]]
    for _ in {1..100}; do
      [[ -s $runtime_dir/door-7000-$door_pid.pid ]] && break
      kill -0 "$launcher_pid"
      sleep 0.1
    done
    read -r recorded_pid door_start_time < "$runtime_dir/door-7000-$door_pid.pid"
    [[ $recorded_pid == "$door_pid" && $door_start_time =~ ^[0-9]+$ ]]
    grep -Fx 'DOOR_STDERR_MUST_NOT_REACH_GUEST' "$runtime_dir/doors.log"
    grep -Fqx 'DOOR_HOLD_READY' <(tr -d '\r' < "$log")
    read -r qemu_pid < <(pgrep -P "$launcher_pid" -f '^microvm@sandbox ')
    [[ $(readlink "/proc/$qemu_pid/exe") == */.qemu-system-*-wrapped ]]
    printf 'LIFECYCLE_PIDS launcher=%s qemu=%s door=%s\n' "$launcher_pid" "$qemu_pid" "$door_pid"
    kill -0 "$door_pid"
    command_pid=$(< "/proc/$door_pid/task/$door_pid/children")
    command_pid=''${command_pid// /}
    [[ $command_pid =~ ^[0-9]+$ ]]
    kill -KILL "$qemu_pid"
    wait "$launcher_pid" || launcher_status=$?
    printf 'LIFECYCLE_WAIT status=%s\n' "''${launcher_status:-0}"
    [[ ''${launcher_status:-0} == 125 ]]
    for pid in "$door_pid" "$command_pid"; do
      for _ in {1..100}; do
        if ! IFS= read -r stat 2>/dev/null < "/proc/$pid/stat"; then break; fi
        read -r -a process <<< "''${stat##*) }"
        [[ ''${process[0]} == Z ]] && break
        sleep 0.01
      done
      [[ ! -r /proc/$pid/stat || ''${process[0]} == Z ]] || {
        echo "FAIL: door process $pid survived QEMU death and launcher cleanup" >&2
        exit 1
      }
    done
    [[ ! -e $runtime_dir ]]
    echo "PASS: QEMU death orphaned door $door_pid; launcher exit trap reaped it (launcher status ''${launcher_status:-0})"
  '';
  doorPackage = factory {
    doors = [fixtureDoor];
    exe = lib.getExe doorGuestFixture;
    outName = "sandbox-door-fixture";
  };
  factory = self.lib.ai.mkSandbox pkgs;
  fixtureDoor = {
    command = lib.getExe doorFixture;
    environment.PATH = "${pkgs.python3}/bin";
    port = 7000;
  };
  sshSigner = self.lib.ai.mkSshSigner pkgs;
  # Guest-side assertions: each fixture exits non-zero when the guest disagrees.
  # They need KVM, so they are launchers to run, not sandboxed builds.
  mkGuestScript = name: text:
    import ../../../lib/strict-shell-application.nix pkgs {
      inherit name text;
      runtimeInputs = [pkgs.coreutils pkgs.diffutils pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.openssh pkgs.procps];
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
  signingGuestFixture = mkGuestScript "sandbox-signing-guest-fixture" ''
    [[ $SSH_AUTH_SOCK == /run/sandbox/agent.sock ]]
    private_dir=$1
    for _ in {1..100}; do
      [[ -S $SSH_AUTH_SOCK ]] && break
      sleep 0.1
    done
    [[ -S $SSH_AUTH_SOCK ]]
    [[ $(stat -c '%U:%a' "$SSH_AUTH_SOCK") == sandbox:600 ]]
    private_dir=''${private_dir:?}
    [[ ! -e $private_dir ]]
    if grep -Fq "$private_dir" /proc/mounts; then
      echo 'FAIL: private key path is shared with the guest' >&2
      exit 1
    fi
    ssh-add -L | tee listed-key
    [[ $(awk '{print $1, $3}' listed-key) == 'ssh-ed25519 sandbox-signing-test' ]]
    printf 'microvm signing door test\n' > message
    ssh-keygen -Y sign -f listed-key -n microvm-test message
    [[ -s message.sig ]]
    base64 -w 0 listed-key; echo ' MICROVM_TEST_KEY'
    base64 -w 0 message; echo ' MICROVM_TEST_MESSAGE'
    base64 -w 0 message.sig; echo ' MICROVM_TEST_SIGNATURE'
    echo PASS: guest lists and signs through the sandbox-owned agent socket
  '';
  signingPackage = factory {
    exe = lib.getExe signingGuestFixture;
    outName = "sandbox-signing-fixture";
    packages = [pkgs.openssh];
    signing = {
      port = 2222;
      socket = "/tmp/microvm-signing-agent.sock";
    };
  };
  signingCheck = mkGuestScript "sandbox-signing-check" ''
    private_dir=$(mktemp -d -p /tmp microvm-signing-private-key.XXXXXXXX)
    artifacts=$(mktemp -d)
    agent_socket=/tmp/microvm-signing-agent.sock
    log=$(mktemp)
    # Invoked indirectly by traps.
    # shellcheck disable=SC2329
    cleanup() {
      status=$?
      if (( status != 0 )); then
        cat "$log"
      fi
      if [[ -n ''${signer_pid:-} ]]; then
        kill "$signer_pid" 2>/dev/null || :
        wait "$signer_pid" 2>/dev/null || :
      fi
      rm -rf -- "$private_dir" "$artifacts" "$agent_socket" "$log"
    }
    trap cleanup EXIT
    ssh-keygen -q -t ed25519 -N "" -C sandbox-signing-test -f "$private_dir/private-key"
    # The signer must not load an inherited agent; the dedicated socket is explicit.
    export SSH_AUTH_SOCK=/tmp/microvm-signing-inherited-agent-must-not-be-used.sock
    ${lib.getExe sshSigner} "$agent_socket" "$private_dir/private-key" &
    signer_pid=$!
    for _ in {1..100}; do
      [[ -S $agent_socket ]] && break
      kill -0 "$signer_pid"
      sleep 0.1
    done
    [[ -S $agent_socket ]]
    ${lib.getExe signingPackage} -- "$private_dir" > "$log"
    grep -E ' MICROVM_TEST_KEY' "$log"
    for artifact in KEY MESSAGE SIGNATURE; do
      count=$(grep -Ec "[[:blank:]]MICROVM_TEST_$artifact" "$log")
      [[ $count == 1 ]]
      encoded=$(sed -n "s/^\([A-Za-z0-9+/=]*\)[[:blank:]]MICROVM_TEST_$artifact.*/\1/p" "$log")
      [[ -n $encoded ]]
      printf '%s' "$encoded" | base64 -d > "$artifacts/$artifact"
    done
    cmp "$private_dir/private-key.pub" "$artifacts/KEY"
    printf 'sandbox-signing-test %s\n' "$(< "$private_dir/private-key.pub")" > "$private_dir/allowed-signers"
    ssh-keygen -Y verify -f "$private_dir/allowed-signers" -I sandbox-signing-test -n microvm-test -s "$artifacts/SIGNATURE" < "$artifacts/MESSAGE"
    echo 'PASS: dedicated signer listed and signed; host verified the generated public key'
  '';
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
    doors = [fixtureDoor];
    exe = lib.getExe repoProbe;
    outName = "sandbox-repo-probe";
    repo = true;
  };
  repoRootProbe = mkGuestScript "sandbox-repo-root-probe" ''
    [[ $(id -u) == 0 ]]
    if touch /mnt/seed/sandbox-root-write-probe 2>/dev/null; then
      echo "REPO_ROOT_WRITE=allowed:/mnt/seed" >&2
      exit 1
    fi
    echo "REPO_ROOT_WRITE=denied:/mnt/seed"
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
      microvm-sandbox-door-cleanup = mkLintedCheck "microvm-sandbox-door-cleanup" {
        runtimeInputs = [pkgs.git];
        text = ''
          ${lib.getExe pkgs.python3} ${./door-cleanup.py} \
            ${lib.getExe doorPackage} \
            ${doorPackage.guest.config.microvm.declaredRunner}/bin/microvm-run \
            ${lib.escapeShellArg (lib.findFirst (lib.hasPrefix "user,id=doors") "" doorPackage.guest.config.microvm.qemu.extraArgs)}
          ${lib.getExe pkgs.python3} ${./door-cleanup.py} \
            ${lib.getExe repoPackage} \
            ${repoPackage.guest.config.microvm.declaredRunner}/bin/microvm-run \
            ${lib.escapeShellArg (lib.findFirst (lib.hasPrefix "user,id=doors") "" repoPackage.guest.config.microvm.qemu.extraArgs)} --repo
        '';
      };
      microvm-sandbox-door-launcher = doorPackage;
      microvm-sandbox-door-lifecycle = doorLifecycleCheck;
      microvm-sandbox-doors = mkTest "microvm-sandbox-doors" (
        let
          door = doorPackage.guest.config;
          doorless = argvPackage.guest.config;
          valid = {
            command = lib.getExe doorFixture;
            port = 7000;
          };
          rejects = doors: !(builtins.tryEval (factory (args // {inherit doors;})).drvPath).success;
        in
          door.microvm.interfaces
          == []
          && lib.hasInfix "guestfwd=tcp:10.0.2.100:7000-cmd:/nix/store/" (lib.findFirst (lib.hasPrefix "user,id=doors") "" door.microvm.qemu.extraArgs)
          && lib.hasInfix "-sandbox-door-7000" (lib.findFirst (lib.hasPrefix "user,id=doors") "" door.microvm.qemu.extraArgs)
          && builtins.elem "network-online.target" door.systemd.services.sandbox.wants
          && !(builtins.any (lib.hasInfix "netdev") doorless.microvm.qemu.extraArgs)
          && doorless.systemd.services.sandbox.wants == []
          && builtins.all (a: a.assertion) door.assertions
          && rejects [(valid // {port = 0;})]
          && rejects [(valid // {command = "nc 10.0.0.1 22";})]
          && rejects [(valid // {command = "/bin/x,restrict=off";})]
          && rejects [(valid // {arguments = "not-a-list";})]
          && rejects [(valid // {arguments = [42];})]
          && rejects [(valid // {extra = true;})]
          && rejects [valid valid]
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
        && !builtins.elem pkgs.git guest.environment.systemPackages
      );
      microvm-sandbox-invalid-name = mkTest "microvm-sandbox-invalid-name" (
        builtins.attrNames (builtins.functionArgs factory)
        == ["doors" "exe" "memory" "outName" "packages" "repo" "repoConfig" "signing" "vcpus"]
        && (builtins.functionArgs factory).doors
        && (builtins.functionArgs factory).memory
        && (builtins.functionArgs factory).packages
        && (builtins.functionArgs factory).repo
        && (builtins.functionArgs factory).repoConfig
        && (builtins.functionArgs factory).signing
        && (builtins.functionArgs factory).vcpus
        && !(builtins.functionArgs factory).exe
        && !(builtins.tryEval (factory (args // {memory = 0;}))).success
        && !(builtins.tryEval (factory (args // {vcpus = 0;}))).success
        && !(builtins.tryEval (factory (args // {exe = "hello";}))).success
        && !(builtins.tryEval (factory (args // {repo = "yes";}))).success
        && !(builtins.tryEval (factory (args // {outName = "../hello";}))).success
      );
      microvm-sandbox-launcher = package;
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
          == 2
          && shares.seed.mountPoint == "/mnt/seed"
          && shares.seed.readOnly
          && builtins.elem "ro" g.fileSystems."/mnt/seed".options
          && builtins.all (name: builtins.elem "name=opt/sandbox.${name},file=${name}" g.microvm.qemu.extraArgs) ["repo-branch" "repo-head" "seed-roots"]
          && g.systemd.services.sandbox.serviceConfig.RuntimeDirectory == "sandbox"
          && g.systemd.services.sandbox.unitConfig.RequiresMountsFor == ["/mnt/seed"]
          && lib.hasInfix "directory = /mnt/seed" g.environment.etc.gitconfig.text
          && !lib.hasInfix "*" g.environment.etc.gitconfig.text
          && builtins.elem "+${pkgs.coreutils}/bin/install -m 0444 /sys/firmware/qemu_fw_cfg/by_name/opt/sandbox.seed-roots/raw /run/sandbox-seed-roots" g.systemd.services.sandbox.serviceConfig.ExecStartPre
          && builtins.length guest.microvm.shares == 1
          && builtins.elem pkgs.git g.environment.systemPackages
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
      microvm-sandbox-signing = mkTest "microvm-sandbox-signing" (
        let
          signingConfig = signingPackage.guest.config;
          rejects = signing: !(builtins.tryEval (factory (args // {inherit signing;})).drvPath).success;
          assertions = {
            agent-environment = signingConfig.systemd.services.sandbox.serviceConfig.Environment == ["SSH_AUTH_SOCK=/run/sandbox/agent.sock"];
            agent-owner = signingConfig.systemd.services.sandbox-signing-agent.serviceConfig.User == "sandbox";
            bridge = lib.hasInfix "UNIX-LISTEN:/run/sandbox/agent.sock,fork,mode=0600 TCP:10.0.2.100:2222" signingConfig.systemd.services.sandbox-signing-agent.serviceConfig.ExecStart;
            door = lib.hasInfix "guestfwd=tcp:10.0.2.100:2222-cmd:/nix/store/" (lib.findFirst (lib.hasPrefix "user,id=doors") "" signingConfig.microvm.qemu.extraArgs);
            missing-socket = rejects {
              port = 2222;
            };
            no-key-share = builtins.length signingConfig.microvm.shares == 1;
            port-range = rejects {
              port = 0;
              socket = "/tmp/agent.sock";
            };
            socket-invalid = rejects {
              port = 2222;
              socket = "relative-agent.sock";
            };
            socket-options = rejects {
              port = 2222;
              socket = "/tmp/agent.sock,forever";
            };
            socket-shell = rejects {
              port = 2222;
              socket = "/tmp/agent socket";
            };
          };
        in
          builtins.all (name: assertions.${name} || throw "microvm-sandbox-signing: ${name}") (builtins.attrNames assertions)
      );
      microvm-sandbox-signing-check = signingCheck;
      microvm-sandbox-signing-launcher = signingPackage;
      microvm-sandbox-status-launcher = factory {
        exe = lib.getExe statusFixture;
        outName = "sandbox-status-fixture";
      };
    };
}
