<!-- cspell:ignore virtio -->

# MicroVM sandboxes

`ai.sandbox` installs `<runtime>-sandbox` console launchers for enabled Claude
and Codex runtimes in fresh NixOS QEMU guests. This requires Linux and usable
KVM, with the guest architecture matching the host package set. Importing the
modules installs no sandbox until enabled.

For Home Manager, import this flake's `homeManagerModules.default` and declare:

```nix
{pkgs, ...}: {
  ai.claude.enable = true;
  ai.codex.enable = true;
  ai.sandbox = {
    enable = true;
    extraPackages = [pkgs.fd pkgs.ripgrep];
    vm = {memory = 8192; vcpus = 4;};
  };
  ai.codex.sandbox.vm.memory = 4096;
}
```

For devenv, import this flake's `devenvModules.nix-agentic-tools` and use the
same declaration. Home Manager adds launchers to `home.packages`; devenv adds
them to `packages`. Run `claude-sandbox` or `codex-sandbox` to boot the guest.

`enable` defaults to false, `extraPackages` to `[]`, and `vm.memory`/`vm.vcpus`
to 4096 MiB/two CPUs. Every runtime mirrors this tree at `ai.<runtime>.sandbox`.
Explicitly defined root leaves supply runtime option defaults. A runtime
definition, including `lib.mkDefault`, replaces the whole inherited option:
lists are replaced, never appended. Other leaves retain their root values;
runtime values never flow up. Set `ai.<runtime>.sandbox.enable = false` to opt
out. Kiro's mirror is separate from `ai.kiro.cli.sandbox`.

Guest routes use the plain configured `ai.claude.package` and
`ai.codex.package`, before host launcher wrapping; null packages refuse sandbox
evaluation. Enabled Kiro, Kimchi and Copilot runtimes with
`sandbox.enable = true` warn because they have no guest route yet. Untouched
defaults never warn. Extra packages and Git enter the guest system profile and
executable PATH so child shells can find them.

`ai.sandboxes.<name>` remains for one release as a deprecated standalone surface
and warns when non-empty. Migrate runtime guests to `ai.sandbox`, or use the
factory below for a standalone guest. A legacy declaration such as
`ai.sandboxes.sandbox-hello.exe = lib.getExe pkgs.hello` still installs
`sandbox-hello`; its optional `outName` overrides the attribute name. Command
names are exclusive through `ai.claims`, including collisions with runtime
launchers.

The standalone factory takes the caller's package set, required `exe` and
`outName`, and optional packages and sizing:

```nix
inputs.nix-agentic-tools.lib.ai.mkSandbox pkgs {
  exe = lib.getExe pkgs.hello;
  memory = 4096;
  outName = "sandbox-hello";
  packages = [pkgs.git pkgs.ripgrep];
  vcpus = 2;
}
```

The result is a standalone package with `bin/sandbox-hello`. The source of
microvm.nix comes from this flake's pinned input; consumers need no separate
microvm input or module arguments. `exe` must be an absolute executable path;
use `lib.getExe' pkg "name"` to select a binary explicitly. Its Nix string
context keeps the package in the launcher closure. `outName` must be a single
name, not a path. The factory defaults to `memory = 1024`, `vcpus = 1` and
`packages = []`; memory must be an integer of at least 128 MiB, CPUs a positive
integer, and packages a list of derivations. Packages enter both the guest
system profile and executable PATH.

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
serial input and output. RAM and virtual CPUs follow `ai.sandbox.vm` (or the
runtime override), or the standalone factory sizing. It has no network interface
and no host home or project mount. The only host share is the entire
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
