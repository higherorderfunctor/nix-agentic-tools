# cspell:ignore chardev dports guestfwd netdev virtio virtserialport
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
    def log(event):
        if path := os.environ.get("DOOR_LOG"):
            with open(path, "a") as f:
                f.write(f"{event} {os.getpid()}\n")
    log("start")
    fd0, fd1 = os.fstat(0), os.fstat(1)
    kind = "socket" if stat.S_ISSOCK(fd0.st_mode) else oct(stat.S_IFMT(fd0.st_mode))
    print(f"PID {os.getpid()} STDIN {kind} SAME {fd0.st_ino == fd1.st_ino}", flush=True)
    print("STDERR", file=sys.stderr, flush=True)
    for line in sys.stdin:
        print(f"ECHO {line.rstrip()}", flush=True)
    print("BYE", flush=True)
    log("exit")
  '';
  doorGuestFixture = pkgs.writeScriptBin "sandbox-door-guest-fixture" ''
    #!${lib.getExe pkgs.python3}
    import socket, sys
    door = ("10.0.2.100", 7000)
    def open_door():
        s = socket.create_connection(door, timeout=10)
        return s, s.makefile("r")
    a, ra = open_door()
    header = ra.readline().split()
    assert header[0] == "PID" and header[2:] == ["STDIN", "socket", "SAME", "True"], header
    assert ra.readline() == "STDERR\n"
    b, rb = open_door()
    other = rb.readline().split()
    assert other[1] != header[1], "one door process served two connections"
    assert rb.readline() == "STDERR\n"
    a.sendall(b"one\n"); b.sendall(b"two\n")
    assert ra.readline() == "ECHO one\n" and rb.readline() == "ECHO two\n"
    a.shutdown(socket.SHUT_WR)
    assert ra.read() == "BYE\n"
    print(f"PASS: door per connection ({header[1]} != {other[1]}), stdin/stdout one socket, stderr in stream, exit on EOF", flush=True)
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
  doorPackage = factory {
    doors = [
      {
        command = lib.getExe doorFixture;
        port = 7000;
      }
    ];
    exe = lib.getExe doorGuestFixture;
    outName = "sandbox-door-fixture";
  };
  factory = self.lib.ai.mkSandbox pkgs;
  package = factory args;
  guest = package.guest.config;
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
      microvm-sandbox-door-launcher = doorPackage;
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
          && builtins.elem "user,id=doors,restrict=on,net=10.0.2.0/24,guestfwd=tcp:10.0.2.100:7000-cmd:${lib.getExe doorFixture}" door.microvm.qemu.extraArgs
          && builtins.elem "network-online.target" door.systemd.services.sandbox.wants
          && !(builtins.any (lib.hasInfix "netdev") doorless.microvm.qemu.extraArgs)
          && doorless.systemd.services.sandbox.wants == []
          && builtins.all (a: a.assertion) door.assertions
          && rejects [(valid // {port = 0;})]
          && rejects [(valid // {command = "nc 10.0.0.1 22";})]
          && rejects [(valid // {command = "/bin/x,restrict=off";})]
          && rejects [(valid // {extra = true;})]
          && rejects [valid valid]
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
        == ["doors" "exe" "outName"]
        && !(builtins.tryEval (factory (args // {exe = "hello";}))).success
        && !(builtins.tryEval (factory (args // {outName = "../hello";}))).success
      );
      microvm-sandbox-launcher = package;
      microvm-sandbox-modules = mkTest "microvm-sandbox-modules" (
        map (p: p.drvPath) (evalHm moduleConfig).config.home.packages
        == [package.drvPath]
        && map (p: p.drvPath) (evalDevenv moduleConfig).config.packages == [package.drvPath]
        && (evalHm moduleConfig).config.ai.sandboxes.sandbox-hello.outName == "sandbox-hello"
      );
      microvm-sandbox-status-launcher = factory {
        exe = lib.getExe statusFixture;
        outName = "sandbox-status-fixture";
      };
    };
}
