# MicroVM sandbox implementation

<!-- cspell:ignore ACPI chardev sysfs vcpus virtio -->

> **Last verified:** 2026-11-01 — shared runtime sandbox options and guest
> routes; repository object retention, read-only mounts, and committed-work
> recovery through virtio serial ports.

`ai.sandbox` enables fresh Linux KVM guests for enabled Claude and Codex
runtimes. Home Manager and devenv expose the same options and install
`claude-sandbox` and `codex-sandbox` into their respective package profiles:

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

`enable` defaults to false, `extraPackages` to `[]`, and `vm.memory`/`vm.vcpus`
to 4096 MiB/two CPUs. Every runtime in `lib/ai/runtimes.nix` mirrors the whole
option tree at `ai.<runtime>.sandbox`. Only defined root leaves supply runtime
option defaults, following the peer-default pattern in `ai.proxy`. Runtime
definitions, including `mkDefault`, replace each whole option: a list (and any
future attribute-set option) is replaced rather than merged with the root. Other
leaves keep their root values. Nothing flows up. Kiro's new root tree is
separate from its existing `ai.kiro.cli.sandbox` setting.

The guest-route table selects the plain `ai.claude.package` or
`ai.codex.package`, before host launcher environment and jail wrapping. Enabling
a sandbox with a null package fails evaluation. Kiro, Kimchi and Copilot have no
guest route yet: an enabled runtime with resolved `sandbox.enable = true` warns
once; set `ai.<runtime>.sandbox.enable = false` to opt out. Untouched defaults
never warn. Sandbox commands claim their names through `ai.claims`.

`extraPackages` and Git from the module's package set enter both the executable
PATH and the guest system profile, so child shells resetting PATH to
`/run/current-system/sw/bin` still find them. This phase supplies no repository,
doors, identities or Git settings. Never log a harness into a provider inside
the VM; VM-only CPA client keys will supply authentication in a later phase.

The public standalone factory also accepts packages and sizing:

```nix
inputs.nix-agentic-tools.lib.ai.mkSandbox pkgs {
  exe = lib.getExe pkgs.hello;
  memory = 4096;
  outName = "sandbox-hello";
  packages = [pkgs.git pkgs.ripgrep];
  vcpus = 2;
}
```

The factory defaults remain 1024 MiB, one CPU and no extra packages. Memory must
be at least 128 MiB and CPUs at least one. It returns a package with
`bin/<outName>` and owns the guest definition and launcher. `exe` must be an
absolute executable path (usually `lib.getExe package`); its string context
keeps the package in the closure. `outName` must be a single executable name.
The pinned microvm source is bound through `ai.internal.mkSandbox`; consumers
need no extra module arguments.

`ai.sandboxes.<name> = {exe; outName?;}` remains for one release. A non-empty
value warns to migrate runtime guests to `ai.sandbox`, or standalone guests to
`lib.ai.mkSandbox`. Its default `outName` is the attribute name. Collisions
between legacy entries or with runtime sandbox commands fail through the same
claims registry. An empty configuration installs no sandbox and forces no guest.

The guest shares the host's store at `/nix/.ro-store`, not `/nix/store`:
upstream mounts the latter as an overlay with tmpfs upper and work directories
beneath `/nix/.rw-store`. Sharing directly at the overlay destination would hide
the lower mount. Root is tmpfs as well; no disk, NIC, home or workspace is
shared.

QEMU's upstream runner has `-no-reboot`, because its microvm machine can hang on
powering off. The service's privileged `ExecStopPost` writes systemd's
main-process `EXIT_CODE` and `EXIT_STATUS` through
`/dev/virtio-ports/sandbox.status`, then requests reboot even if reporting
fails. A root-only udev rule prevents the unprivileged process from forging
completion. The unit waits for this device before starting; the reporter accepts
ordinary completion results only, and unset main-process status (including
preparation failure) produces no record. QEMU writes the separate file chardev
into the private host runtime directory. Console output is never parsed. The
existing store share already enables PCI in the upstream runner; virtio serial
uses that bus on Linux guests without adding a mount. No serial getty competes
with the process for its console.

The host wrapper accepts zero arguments or removes one leading `--`, rejecting
other prefixes before checking KVM and allocating its unique temporary runtime
directory. It serializes the remaining arguments with NUL separators; zero
arguments produce an empty file, distinct from one empty argument. QEMU reads
that relative `argv` file through `-fw_cfg`, so changing arguments never
rebuilds the guest and adds no share. The `qemu_fw_cfg` driver exposes the blob
in sysfs; privileged `ExecStartPre` installs it into the service's private
runtime directory. The unprivileged guest wrapper reads it with Bash `mapfile`
and executes the shell-quoted fixed `exe` with the resulting array. No argument
string is evaluated as shell syntax. Keep the executable's Nix string context
intact: it supplies the package dependency without a separate package field.

The pinned QEMU microvm machine exposes fw_cfg with the existing ACPI setup. The
sysfs raw file reports size zero despite containing data; streaming reads work,
including payloads larger than a page. This narrow read-only blob replaces the
need for any host control-directory share.

After a successful runner exit, the host validates the completion record and
returns the guest exit code (0–255), or 128 plus the signal number for a killed
process. A failed runner takes precedence over any record. Missing or malformed
completion and VM failure return 125 with a diagnostic, so a normal VM shutdown
alone cannot imply guest success. Guest exit 125 shares that numerical value but
has no infrastructure diagnostic.

The runner executes inside that directory, and the wrapper's exit trap removes
it. Avoid `exec` at that call: replacing the shell would bypass the cleanup
trap.

The factory accepts
`{exe; outName; memory ? 1024; packages ? []; repo ? false; vcpus ? 1;}`. With
`repo = true`, launch from a Git checkout (including a linked worktree or an
unborn branch). The guest starts in `/home/sandbox/repo` at that checkout's
committed HEAD, preserving its branch name or detached state. Uncommitted host
changes are excluded. Shallow, partial, and alternates-using repositories are
refused; supported object formats are SHA-1 and SHA-256. This factory parameter
does not add a module option.

The launcher builds an isolated bare seed repository with templates disabled and
the host's explicit object format. Only the chosen push remote's tracking refs
become seed branches; the checkout's HEAD becomes `refs/sandbox/head`. Remote
selection is `branch.<name>.pushRemote`, `remote.pushDefault`,
`branch.<name>.remote`, then `origin`. An unborn checkout gets an empty seed.
The generated seed and the host common directory's `objects/` are separate
read-only 9p exports. Their relative sources resolve in the per-launch runtime
directory. Host config, hooks, refs, and worktree metadata are never exported.
The guest clones the seed with `--shared --no-checkout`; its system Git config
trusts only the seed and object mount paths. The object share contains all host
objects, including objects outside the seeded refs; it is not an object-level
confidentiality boundary. The whole host Nix store is also readable in the
guest.

Before boot the launcher holds `<common>/sandbox-locks/<token>` and creates
`refs/sandbox/<token>/<n>` in the host for every borrowed root, including a
linked worktree's detached HEAD. These refs retain reachable objects even across
`git gc --prune=now`. Pin publication coordinates with Git GC and maintenance
locks and checks the full borrowed object graph before boot. Another sandbox
launch, an active collector, or a maintenance operation holding these locks
causes a retry diagnostic; the publication locks are released before the guest
starts. Forced GC and direct pruning that bypass Git locking are unsupported
during publication. The exit trap removes its pins; the next launch removes pins
from sessions whose locks are no longer held. Lock files remain to avoid locking
different inodes for the same session. Pin creation fails the launch if
concurrent maintenance already removed a required object.

On graceful service completion, the guest exports committed work through a
separate virtio bundle port. It includes local refs and detached HEAD and
excludes only the immutable seeded commits, which the host retains. Changes to
`origin/*` inside the guest cannot introduce unknown bundle prerequisites. The
host verifies the bundle against the host repository, validates its pack in an
isolated temporary repository, and makes it self-contained before saving it at
`$XDG_STATE_HOME/ai-sandbox/bundles/<token>.bundle` (default state root:
`~/.local/state`) and printing a fetch command. Saved bundles remain recoverable
after session pins are removed and host maintenance prunes the original commits.
Empty exports need no recovery. Export or verification failures are reported
separately from guest completion. Runner failures are reported even when
recovery also fails; nonempty failed exports are retained as
`<token>.failed.bundle`. Recovery covers committed work on graceful completion
only. Forced VM shutdown, host termination, and uncommitted files are not
recoverable through this path.

The user-facing contract and host preparation are documented in
`packages/microvm/modules/README.md`. The owner checks cover empty imports,
installation parity, factory validation, and guest boundaries. Real guest boot
requires a Linux host with KVM access and is a separate smoke test.
