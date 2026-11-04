# MicroVM sandbox implementation

<!-- cspell:ignore ACPI chardev gettys poweroff SSHSIG sysfs vcpus virtio -->

> **Last verified:** 2026-11-01 — shared runtime sandbox options and guest
> routes; seeded-history copies, read-only mounts, and committed-work recovery
> through virtio serial ports.

`ai.sandbox` enables fresh Linux KVM guests for enabled Claude and Codex
runtimes. Home Manager and devenv expose the same options and install
`claude-sandbox` and `codex-sandbox` into their respective package profiles. The
options, example and copy-down rules are in
`packages/microvm/modules/README.md`. Only runtimes with a guest route mirror
the tree at `ai.<runtime>.sandbox`; defaults are inherited in the option
default, as in `ai.proxy`.

The guest-route table selects the plain `ai.claude.package` or
`ai.codex.package`, before host launcher environment and jail wrapping. Enabling
a sandbox with a null package fails evaluation. Kiro, Kimchi and Copilot have no
guest route and no `sandbox` option. Sandbox commands claim their names through
`ai.microvm.claims.command`.

`extraPackages` enter executable PATH and the guest system profile, including
child shells resetting PATH to `/run/current-system/sw/bin`. Identity-aware
launchers select a relay session and seed committed work; see
`sandbox-identities.md` for launch ordering and no-door cases. Never log a
harness into a provider inside the VM; VM-only CPA client keys will supply
authentication later.

The public `lib.ai.mkSandbox pkgs` factory requires `exe` (an absolute
executable path whose Nix string context retains its package) and `outName` (a
single executable name). Optional defaults are `doors = []`, `memory = 1024`
MiB, `packages = []`, `repo = false`, `repoConfig = false`, `signing = null`,
and `vcpus = 1`. Memory must be at least 128 MiB and CPUs at least one. The
factory owns the guest and `bin/<outName>` launcher. The pinned microvm source
is bound through `ai.internal.mkSandbox`; consumers need no extra module
arguments. An empty configuration installs no sandbox and forces no guest.

The host store is shared read-only at `/nix/.ro-store`; upstream overlays
`/nix/store` with tmpfs upper/work directories beneath `/nix/.rw-store`. Root is
tmpfs too. No host disk, home or workspace is shared by default; only doors add
a NIC and only repo mode adds the seed mount described below. The entire host
store is readable, beyond the executable's closure.

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

Each door is `{port; command; arguments ? [];}` with a unique TCP port, absolute
host executable and string arguments. QEMU runs a fresh wrapper per connection
with socket stdin/stdout; the command gets an empty environment, and host stderr
stays in the launcher's private runtime directory, which no guest share
includes. Door arguments sit in a wrapper in the Nix store, which the guest
mounts, so the guest can read them: a secret must come from a runtime file in
the launcher's directory that the command reads when it starts. The restricted
user network exposes only those forwarded guest ports. Each connection has its
own process group. Launcher cleanup checks the recorded PID's start time and
group before killing the whole group, tolerating vanished or incomplete records
so runtime cleanup and exit status survive. CI runs the wrapper outside QEMU,
runs the cleanup against stubbed records and checks the generated QEMU
arguments; the network restriction, one process per connection, the environment
seen from inside the guest and orphan cleanup after QEMU dies are proved only by
the hand-run KVM fixtures (`microvm-sandbox-door-launcher` and
`microvm-sandbox-door-lifecycle`). With `repo = true`, launch from a Git
checkout (including a linked worktree or an unborn branch). The guest starts in
`/home/sandbox/repo` at that checkout's committed HEAD, preserving its branch
name or detached state. Uncommitted host changes are excluded. Shallow and
partial repositories are refused; supported object formats are SHA-1 and
SHA-256. Git joins the guest system profile and executable PATH only in this
mode. These factory parameters do not add module options. `repoConfig = true`
requires repo mode, an absolute `SANDBOX_REPO_CONFIG` file and an absolute
`SANDBOX_SEED_OBJECTS` path at launch, where the launcher links the seed's
object directory. The runtime session launcher uses it to deliver origin and
identity through fw_cfg, included last in the clone after replacing its seed
origin URL.

Optional `signing = {port; socket;}` adds a door to the absolute host
`ssh-agent` socket. A guest bridge publishes `SSH_AUTH_SOCK` without sharing the
private key or its directory. `lib.ai.mkSshSigner pkgs` starts a dedicated host
agent, loads one key, and leaves it running until the signer is stopped.

The door is a filter, not the agent protocol. It forwards key listing and sign
requests whose data is an `SSHSIG` envelope, which `ssh-keygen -Y sign` produces
for Git. It answers every other request with a failure without contacting the
agent: adding, removing or locking keys, extensions, and SSH login challenges. A
login challenge starts with a length-prefixed session identifier, so it can
never begin with that magic. Malformed or oversized messages close the
connection. Refusals go to the launcher's private door log. While the guest
runs, it can still sign any Git object with the loaded key.
`microvm-sandbox-signing-filter` drives a real agent through the filter.

The launcher creates an isolated bare seed with templates disabled and the
host's object format. Selected push-remote tracking refs become seed branches;
HEAD becomes `refs/sandbox/head`. Selection is `branch.<name>.pushRemote`,
`remote.pushDefault`, `branch.<name>.remote`, then `origin`. Unborn seeds are
empty. The launcher copies only the history reachable from the seeded refs into
the seed's own pack (`pack-objects --revs --stdout` piped into `index-pack`), so
stashes, other branches and amended-away commits stay on the host. The seed is
the only repository share, a read-only 9p export at `/mnt/seed` relative to the
runtime directory; host config, hooks, refs, other objects and worktree metadata
stay out. The guest uses `clone --shared --no-checkout`, with system Git trust
limited to the seed mount path.

The launcher writes nothing into the host repository: it holds no refs, locks or
temporary pack files there, so host GC and maintenance run freely during a
session. A host object that disappears while the copy runs fails the launch with
a retry diagnostic.

On graceful service completion, the guest exports committed work through a
separate virtio bundle port. It includes local refs and detached HEAD and
excludes only the immutable seeded commits, which the seed holds. Changes to
`origin/*` inside the guest cannot introduce unknown bundle prerequisites. The
host verifies the bundle against the seed, validates its pack in an isolated
temporary repository, and makes it self-contained before saving it at
`$XDG_STATE_HOME/ai-sandbox/bundles/<token>.bundle` (default state root:
`~/.local/state`) and printing a fetch command. Saved bundles remain recoverable
after the seed is removed and host maintenance prunes the original commits. An
export over 1024 MiB is discarded with a diagnostic rather than saved. Empty
exports need no recovery. Export or verification failures are reported
separately from guest completion. Runner failures are reported even when
recovery also fails; nonempty failed exports are retained as
`<token>.failed.bundle`. Recovery covers committed work on graceful completion
only. Forced VM shutdown, host termination, and uncommitted files are not
recoverable through this path.

See `packages/microvm/modules/README.md` for host setup. Guest smoke tests need
Linux/KVM and run separately from sandboxed builds.
