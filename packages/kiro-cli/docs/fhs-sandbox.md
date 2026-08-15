# The nixpkgs FHS sandbox: what kiro can and cannot see

> **Last verified:** 2026-08-14 (commit pending — adds the consumer-facing
> `ai.kiro.extraPackages` path for making store-backed tools visible without
> rebuilding the FHS root, records its wrapper/PATH precedence, and clarifies
> that the FHS copy of `kiro-cli-chat` shadows the outer chat wrapper during
> launcher dispatch. Adds a structural CI guard for the upstream `/nix`, init,
> and inherited-PATH contracts). Prior: 2026-08-11 (commit pending — first
> revision, measured against the 2.16.2 `fhsenv-rootfs` derivation by reading
> the generated bwrap script and probing from inside the sandbox. Supersedes the
> "has NOT been measured" caveat in [`launcher-argv.md`](launcher-argv.md)). If
> you bump kiro-cli or touch `overlays/kiro-cli.nix`, re-measure rather than
> assuming.

**This is not Kiro's sandbox.** It is an upstream nixpkgs wrapper: since the
package split, `pkgs.ai.kiro-cli` on Linux is a `symlinkJoin` of per-command
`buildFHSEnv` sandboxes and `$out/bin/*` are bubblewrap launchers.

**It is also a different axis from Kiro's own workspace-root allowlist** (see
`dev/references/kiro-workflow-ref.md`). The discriminator is cheap: bwrap has no
concept of a workspace root and would never mention `additionalDirectories`. An
error naming an allowed root is the other axis; this one produces "command not
found" and loader failures.

**None of it applies to darwin**, where upstream returns
`kiro-cli-unwrapped.overrideAttrs` and builds no FHS layer at all — verified
byte-identical across every unwrapped-era nixpkgs checkout in the store. A Mac
sees no change from this wrapper, Homebrew included.

## The bind rule

```bash
for dir in /*; do
  if [[ -d "$dir" ]] && [[ -z "${ignored_set[$dir]:-}" ]]; then
    auto_mounts+=(--bind "$dir" "$dir")   # read-write, same path
  fi
done
```

`ignored_set` is the rootfs top level — exactly
`bin etc lib lib32 lib64 libexec nix-support sbin usr` — plus a hardcoded
`/nix /dev /proc /etc`. Everything else is bound **read-write** at the same
path: `/home`, `/opt`, `/var`, `/tmp`, `/snap`, `/mnt`, `/srv`, `/root`, all
`rw,nosuid,nodev`.

Three exclusions the loop's shape hides, all measured:

- **Hidden entries are silently dropped.** `/*` does not glob dot-entries, so a
  real `/.config` on the host is simply absent inside.
- **Non-directories are skipped** — `/swapfile` and friends.
- **`-d` follows symlinks**, so a top-level symlink _into_ a shadowed subtree
  re-exposes its target. Host `/libx32 -> usr/libx32` is not in the ignore set,
  so host `/usr/libx32` appears read-write at `/libx32` — a hole in the "`/usr`
  is replaced" story.

`/nix`, `/dev` and `/proc` are not "shadowed" either: `/nix` is bound
read-write, `/dev` is a `--dev-bind`, `/proc` is a fresh procfs in the **host
PID namespace** (no `--unshare-pid`; all six `unshare*` options default false).
Host `/etc` stays readable at `/.host-etc`. Meanwhile `/lib32` inside becomes a
**dangling** symlink to a `/usr/lib32` the rootfs does not provide, even though
the host has the real one.

## PATH survives; the entries on it may not

`/etc/profile` does `export PATH="/run/wrappers/bin:/usr/bin:/usr/sbin:$PATH"`
and nothing passes `--clearenv`, so the inherited PATH is preserved intact
(measured: `~/.nix-profile/bin` survives; `jq` and `treefmt` resolve to their
store paths).

**Preserved is not still-valid, and the failure mode is quiet.** The inherited
PATH still lists `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin`, all now
dead or pointing elsewhere:

| tool                                            | inside the sandbox               |
| ----------------------------------------------- | -------------------------------- |
| `nrfutil` — only in `/usr/local/bin`            | not resolvable                   |
| `lazygit` — in `/usr/local/bin` AND nix profile | resolves, but to the **nix** one |

The second row is the dangerous one: no error, a different build of the same
tool. A version-sensitive step changes behavior instead of failing.

The same ordering affects Kiro's own dispatch. The synthesized `/usr/bin`
contains the raw `kiro-cli-chat`, so a normal `kiro-cli` launch finds it before
the inherited profile PATH reaches this repo's outer chat wrapper. Directly
invoking the outer `kiro-cli-chat` entry still traverses that wrapper.

## Supplying missing tools

Use `ai.kiro.extraPackages` for tools Kiro needs but the synthesized root does
not provide:

```nix
ai.kiro.extraPackages = with pkgs; [
  file
  iproute2
  tree
  which
];
```

The Kiro launcher prepends `lib.makeBinPath` of those packages to PATH and then
preserves the caller's PATH. If `ai.kiro.environmentVariables.PATH` is set, that
explicit value becomes the preserved base instead. The wrapper references each
package, so its store path is rooted; bubblewrap preserves the resulting PATH
and bind-mounts `/nix`, so the tools remain executable inside the FHS root.

This supplies commands missing from the synthesized root; it is not an override
mechanism for commands already there. After the outer launcher runs, the FHS
`/init` sources `/etc/profile`, which puts
`/run/wrappers/bin:/usr/bin:/usr/sbin` ahead of the inherited entries. A
same-named FHS command therefore wins over the added package on Linux.

`checks/kiro-fhs-contract.nix` guards the upstream assumptions behind this
behavior. It inspects the realized Linux launcher and fails if bubblewrap stops
binding `/nix`, adds a known PATH-clearing or replacement argument, changes how
the generated `/etc` is mounted, moves `/etc/profile` sourcing after Kiro's
exec, adds another init/profile PATH mutation, or removes the incoming PATH from
the profile assignment. Those structural changes therefore force this document
and the implementation to be re-measured instead of silently invalidating
`extraPackages`.

The check is deliberately structural. It does not execute bubblewrap inside a
Nix build sandbox, where nested user-namespace support is not portable. The
wrapper sentinel test covers the configured prefix and inherited tail; the FHS
contract check pins the current launcher/init/profile literals and their
ordering. Together they cover the known structural bridge, not kernel-level
execution of it.

This is runtime-local: it changes neither the Home Manager session nor the
devenv project shell. Adding the same packages to `home.packages` or devenv's
`packages` also works when user- or project-wide availability is wanted, since
those store-backed profile entries already survive into Kiro.

Do not model this as arbitrary host paths. Visibility under `/home` or `/opt`
does not guarantee a host-built binary can load its libraries, and host `/usr`
is the directory the FHS wrapper replaces.

## `/usr/local` is unreachable, and the obvious escape hatch hard-fails

The rootfs `/usr` supplies `bin include lib lib64 libexec sbin share` and no
`local`, so `/usr/local` is **absent** inside. `/proc/<pid>/root` does not get
around it: the bwrap child user namespace cannot ptrace parent-userns processes,
so both `/proc/1/root` and a same-user host PID return **Permission denied**.

The builder exposes `extraBwrapArgs` and it IS appended last — but a trailing
`--bind /usr/local /usr/local` is not a fix:

```console
bwrap: Can't mkdir /usr/local: Read-only file system
```

A **hard launch failure**, not a silent no-op, which matters because "last mount
wins" is the natural expectation. The blocker is the `mkdir`, not the ordering:
binding _over_ an entry the rootfs already has works fine (measured —
`--bind /usr/local /usr/include` succeeded). Two shapes that do work:

- **measured** — bind to a destination outside the shadowed subtree, e.g.
  `--bind /usr/local /usr-local`.
- **inferred** — `extraBuildCommands` to `mkdir -p $out/usr/local` in the
  rootfs, then the trailing bind, since the mountpoint would then exist.

`extraBindMounts` does not exist in this builder. Do not cite it.

## Visibility is necessary, not sufficient

This is where the sandbox actually bites, and it is not a path problem.

- The FHS `/usr/bin` holds **exactly 233 entries** — coreutils, shadow, glibc,
  gawk, gnused, gnugrep, gnutar, diffutils, findutils, less, the compressors,
  wl-clipboard, and the three `kiro-cli*` binaries. There is **no `node`, no
  `python3`, no `perl`.**
- A repo-local `node_modules/.bin/<tool>` **does** run — measured,
  `pnpm --version` → `10.27.0` — but only because its `#!/usr/bin/env node`
  found node in the user's nix profile. The same tree with an apt-installed
  `/usr/bin/node` fails, because that interpreter is shadowed.
- **A host-built dynamically-linked binary can be visible and still not run.**
  Measured: `/opt/nodejs/node-v18.4.0-linux-x64/bin/node` fails with
  `libstdc++.so.6: cannot open shared object file` — even though that library is
  present at `/usr/lib64`. Root cause: `/etc/ld.so.conf` and `/etc/ld.so.cache`
  do not exist inside. The launcher symlinks glibc's copies _at_ those paths but
  nothing ever creates them, so the loader never searches `/usr/lib64`.
  `LD_LIBRARY_PATH=/usr/lib64` makes the same binary run.

So for anything outside the nix store, assume it needs its libraries found for
it. **Homebrew was not measurable** on the probe host (no `/home/linuxbrew`,
`/opt/homebrew`, or `/usr/local/Homebrew` present), so on Linux treat "linuxbrew
binaries work" as UNVERIFIED: the `/home` and `/opt` binds assure visibility,
nothing here assures execution. On darwin the question does not arise — there is
no sandbox.

## Diagnostic

```bash
# Does the launcher resolve through a bwrap path? Then these rules apply.
readlink -f "$(command -v kiro-cli)"
ls /nix/store/*-kiro-cli-*fhsenv-rootfs/usr/bin | wc -l   # 233 = the whole world
```
