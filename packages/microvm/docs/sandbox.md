# MicroVM sandbox implementation

<!-- cspell:ignore ACPI chardev gettys poweroff sysfs vcpus virtio -->

> **Last verified:** 2026-11-01 — shared runtime sandbox options and guest
> routes; repository object retention, read-only mounts, and committed-work
> recovery through virtio serial ports.

`ai.sandbox` enables fresh Linux KVM guests for enabled Claude and Codex
runtimes. Home Manager and devenv expose the same options and install
`claude-sandbox` and `codex-sandbox` into their respective package profiles.

`enable` defaults to false, `extraPackages` to `[]`, and memory/CPUs to 4096
MiB/two. Every runtime in `lib/ai/runtimes.nix` mirrors the tree at
`ai.<runtime>.sandbox`. Defined root leaves supply option defaults, as in
`ai.proxy`; runtime definitions (including `mkDefault`) replace whole options,
including lists or future attribute-set options. Other leaves keep root values;
nothing flows up. Kiro's mirror is separate from `ai.kiro.cli.sandbox`.

The guest-route table selects the plain `ai.claude.package` or
`ai.codex.package`, before host launcher environment and jail wrapping. Enabling
a sandbox with a null package fails evaluation. Kiro, Kimchi and Copilot have no
guest route yet: an enabled runtime with resolved `sandbox.enable = true` warns
once; set `ai.<runtime>.sandbox.enable = false` to opt out. Untouched defaults
never warn. Sandbox commands claim their names through
`ai.microvm.claims.command`.

`extraPackages` and Git enter executable PATH and the guest system profile,
including child shells resetting PATH to `/run/current-system/sw/bin`.
Identity-aware launchers select a relay session and seed committed work; see
`sandbox-identities.md` for launch ordering and no-door cases. Guest Git
settings arrive through `ai.sandbox.git` (`sandbox-git.md`). Never log a harness
into a provider inside the VM; VM-only CPA client keys will supply
authentication later.

The public `lib.ai.mkSandbox pkgs` factory requires `exe` (an absolute
executable path whose Nix string context retains its package) and `outName` (a
single executable name). Optional defaults are `doors = []`, `gitConfig = null`,
`memory = 1024` MiB, `packages = []`, `repo = false`, `repoConfig = false`,
`signing = null`, and `vcpus = 1`. Memory must be at least 128 MiB and CPUs at
least one. The factory owns the guest and `bin/<outName>` launcher. The pinned
microvm source is bound through `ai.internal.mkSandbox`; consumers need no extra
module arguments.

`ai.sandboxes.<name> = {exe; outName?;}` remains for one release. A non-empty
value warns to migrate runtime guests to `ai.sandbox`, or standalone guests to
`lib.ai.mkSandbox`. Its default `outName` is the attribute name. Collisions
between legacy entries or with runtime sandbox commands fail through the same
claims registry. An empty configuration installs no sandbox and forces no guest.

The host store is shared read-only at `/nix/.ro-store`; upstream overlays
`/nix/store` with tmpfs upper/work directories beneath `/nix/.rw-store`. Root is
tmpfs too. No host disk, home or workspace is shared by default; only doors add
a NIC and only repo mode adds the object/seed mounts described below. The entire
host store is readable, beyond the executable's closure.

QEMU's upstream runner uses `-no-reboot` because its microvm machine can hang on
poweroff. Privileged `ExecStopPost` writes systemd's main-process `EXIT_CODE`
and `EXIT_STATUS` to `/dev/virtio-ports/sandbox.status`, then requests reboot
even if reporting fails. The unit waits for that device; root-only udev rules
prevent the guest command from forging completion. Preparation failures and
other service results produce no record. The file chardev writes into the
private host runtime directory; console output is never parsed. Virtio serial
uses the PCI bus already enabled by the store share. Serial gettys are disabled.

The launcher accepts zero arguments or strips one leading `--`; other prefixes
fail before KVM checks or runtime allocation. Arguments are NUL-separated in a
relative `argv` file delivered through QEMU `-fw_cfg`, without rebuilding or a
control-directory share. Zero arguments differ from one empty argument.
`qemu_fw_cfg` exposes the blob in sysfs; privileged `ExecStartPre` installs it
in the service runtime directory, and Bash `mapfile` restores the array for the
shell-quoted executable. No argument string is evaluated as shell syntax.
Streaming sysfs reads work beyond a page despite the raw file reporting size
zero; the pinned machine exposes fw_cfg through its existing ACPI setup.

After a successful runner exit, the host validates the completion record and
returns the guest exit code (0–255), or 128 plus the signal number for a killed
process. A failed runner takes precedence over any record. Missing or malformed
completion and VM failure return 125 with a diagnostic, so a normal VM shutdown
alone cannot imply guest success. Guest exit 125 shares that numerical value but
has no infrastructure diagnostic.

The runner executes in the private runtime directory. Its caller must retain the
shell and EXIT trap, which reap doors, release repository pins, and remove the
directory after recovery has finished.

Each door is `{port; command; arguments ? []; environment ? {};}` with a unique
TCP port, absolute host executable and string arguments/environment. QEMU runs a
fresh wrapper per connection with socket stdin/stdout; the command gets only its
declared environment, and host stderr stays in the launcher's private runtime
directory. The restricted user network exposes only those forwarded guest ports.
Each connection has its own process group. Launcher cleanup checks the recorded
PID's start time and group before killing the whole group, tolerating vanished
or incomplete records so repository cleanup and exit status survive. With
`repo = true`, launch from a Git checkout (including a linked worktree or an
unborn branch). The guest starts in `/home/sandbox/repo` at that checkout's
committed HEAD, preserving its branch name or detached state. Uncommitted host
changes are excluded. Shallow, partial, and alternates-using repositories are
refused; supported object formats are SHA-1 and SHA-256. These factory
parameters do not add module options. `repoConfig = true` requires repo mode and
an absolute `SANDBOX_REPO_CONFIG` file at launch. The runtime session launcher
uses it to deliver origin and identity through fw_cfg, included last in the
clone after replacing its seed origin URL.

Optional `signing = {port; socket;}` adds a door to the absolute host
`ssh-agent` socket. A guest bridge publishes `SSH_AUTH_SOCK` without sharing the
private key or its directory. `lib.ai.mkSshSigner pkgs` starts a dedicated host
agent, loads one key, and leaves it running until the signer is stopped.

The launcher creates an isolated bare seed with templates disabled and the
host's object format. Selected push-remote tracking refs become seed branches;
HEAD becomes `refs/sandbox/head`. Selection is `branch.<name>.pushRemote`,
`remote.pushDefault`, `branch.<name>.remote`, then `origin`. Unborn seeds are
empty. Seed and host common `objects/` are separate read-only 9p exports,
relative to the runtime directory; host config, hooks, refs and worktree
metadata stay out. The guest uses `clone --shared --no-checkout`, with system
Git trust limited to the seed/object mount paths. All host objects are readable,
including objects outside seeded refs: this share provides no object-level
confidentiality.

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

See `packages/microvm/modules/README.md` for host setup. Guest smoke tests need
Linux/KVM and run separately from sandboxed builds.
