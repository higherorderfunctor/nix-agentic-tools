<!-- cspell:ignore virtio -->

# MicroVM sandboxes

`ai.sandboxes.<name>` installs a console launcher for one package executable in
a fresh NixOS QEMU guest. This is a Linux-only primitive for hosts with usable
KVM, with the guest architecture matching the host package set. Importing the
modules leaves `ai.sandboxes = {}` and installs no sandbox.

For Home Manager, import this flake's `homeManagerModules.default` and declare:

```nix
{lib, pkgs, ...}: {
  ai.sandboxes.sandbox-hello = {
    exe = lib.getExe pkgs.hello;
  };
}
```

For devenv, import this flake's `devenvModules.nix-agentic-tools` and use the
same declaration. The Home Manager sink adds wrappers to `home.packages`; devenv
adds them to `packages`. Run `sandbox-hello` to boot the guest and print Hello's
output. `outName` optionally overrides the wrapper name, which otherwise
defaults to the attribute name.

The plain factory takes the caller's package set and the same two fields:

```nix
inputs.nix-agentic-tools.lib.ai.mkSandbox pkgs {
  exe = lib.getExe pkgs.hello;
  outName = "sandbox-hello";
}
```

The result is a standalone package with `bin/sandbox-hello`. The source of
microvm.nix comes from this flake's pinned input; consumers need no separate
microvm input or module arguments. `exe` must be an absolute executable path;
use `lib.getExe' pkg "name"` to select a binary explicitly. Its Nix string
context keeps the package in the launcher closure. `outName` must be a single
name, not a path. Additional factory fields are rejected.

Run without arguments to invoke the executable without arguments. To pass guest
arguments, put `--` first: `sandbox-hello -- --version`. The launcher removes
that first delimiter and preserves every remaining argument, including empty
arguments and a second literal `--`. Arguments before the delimiter are reserved
for sandbox options; none are currently supported, so they fail with exit 2.

## Host setup

Enable virtualization in the firmware. On Linux, load `kvm` and the appropriate
CPU module (`kvm_intel` or `kvm_amd` on x86). Ensure `/dev/kvm` exists and your
user has read and write access; commonly this means adding the user to the `kvm`
group and logging out and back in. A NixOS host can declare the appropriate
`boot.kernelModules` and `users.users.<user>.extraGroups = ["kvm"]` manually.
The sandbox module installs no host NixOS services and needs no host root at
launch. The launcher reports a clear error when `/dev/kvm` access is missing.

## Guest boundaries and console limits

The guest runs the selected `exe` as the unprivileged `sandbox` user, with
serial input and output. It has one virtual CPU, 1 GiB RAM, no network
interface, and no host home or project mount. The only host share is the entire
`/nix/store`, served read-only over 9p. Treat that store as visible to the
guest: it can contain more than the selected executable's closure.

The guest uses a tmpfs root and a guest-local tmpfs at `/nix/.rw-store` for the
writable store overlay. Home, temporary files and store changes disappear when
the guest stops. Each launch uses a unique temporary host runtime directory;
normal launcher completion or runner failure removes it. Simultaneous launches
use separate directories. Guest arguments travel as a NUL-delimited file through
QEMU's read-only firmware configuration interface; they add no host filesystem
share and do not appear in QEMU's command line or the guest kernel command line.
The guest copies this blob into its private service runtime directory before
executing the selected program. The VM build is reused across invocations. The
selected process's completion requests a guest reboot, which stops the QEMU
runner through `-no-reboot`.

The launcher returns the selected process's exit code, or 128 plus the signal
number if a signal kills it. VM runner failure or missing completion returns 125
and prints a diagnostic; guest exit 125 has the same number without that
diagnostic. Completion travels through a separate root-only virtio serial port,
so program output cannot forge success.

This is a serial console wrapper, not a transparent replacement for the program:
boot logs share its output and interactive terminal behavior differs. It
forwards no host environment, credentials, workspace, or network. There is no
usable authenticated project or coding-harness workflow yet. Use a small
deterministic command to check the primitive before trying an interactive
program.
