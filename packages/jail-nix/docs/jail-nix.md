# jail.nix library

> **Last verified:** 2026-10-19 (commit 2c04311c) — `lib.ai.jail` re-exports
> jail.nix at 7cd53ace; its checks are Linux-only.

## What it is

jail.nix (`sourcehut:~alexdavid/jail.nix`) is a pure Nix library that wraps a
program in bubblewrap. It is not a NixOS module, so Home Manager and devenv need
no polyfill: a jail is a package on `PATH`.

`lib.ai.jail` re-exports it unchanged:

- `init pkgs` returns the builder `jail name exe permissions`.
- `extend {pkgs; additionalCombinators; basePermissions; bubblewrapPackage}`
  returns the same builder with those overrides.
- `src` is the pinned source tree.

The builder yields a `writeShellApplication` that `exec`s bwrap. `exe` is a
package (its `meta.mainProgram`) or a string path. Both entry points take the
caller's `pkgs`, as `lib.ai.mkSandbox` does. There is no package leaf, so
nothing reaches cachix and no pin-parity check applies.

`src` is the source path, not the flake input. The owner library walker recurses
into every non-derivation attrset, and the flake input fails it with
`cannot coerce a set to a string`.

## Upstream defaults are an allow-list

The stock `basePermissions` are `base`, `bind-nix-store-runtime-closure` and
`fake-passwd`:

- `--tmpfs ~`, `--tmpfs /tmp`, a fresh `/proc` and `/dev`.
- `--clearenv`, then forward only `LANG`, `HOME` and `TERM`. The wrapper runs
  under nounset, so all three must be set, and `HOME` must be creatable:
  `fake-passwd` writes under `~/.local/share/jail.nix`.
- Bind only the runtime closure of `exe` from the store.

The finalizer unshares the user, ipc, pid, net, uts and cgroup namespaces and
adds `--new-session` and `--die-with-parent`. `share-ns`, `network`,
`no-new-session` and `no-die-with-parent` undo those. The result forwards only
`man`, `shellPath` and `override` from `exe`; `passthru` is dropped.

## The extend seam

`basePermissions` is the one hook that replaces what every jail starts from. A
jail's own `permissions` run after it and can only add to that state, so a
per-jail list cannot take back a `--tmpfs ~` or a `--clearenv`. An
exclusion-only profile (the full host view and the environment kept, with
credential paths masked) therefore replaces `basePermissions` through `extend`.

`additionalCombinators` receives the built-in combinators and returns raw
`state -> state` functions, not the `{sig; doc; impl}` records in upstream's
`lib/combinators/*.nix`. `compose` chains them. jail.nix has no combinator for
`--unsetenv`; `unsafe-add-raw-args` emits it.

## Facts measured on the development host (2026-10-19)

- A single bwrap from `pkgs.bubblewrap` works. Nested user namespaces work when
  the OUTER bwrap is the Nix-store binary, and fail when it is `/usr/bin/bwrap`:
  Ubuntu's AppArmor profile `bwrap-userns-restrict` confines that one. jail.nix
  uses `pkgs.bubblewrap`, so a harness's own bwrap or FHS launcher can run
  inside a jail here. Other hosts may differ.
- `--unsetenv VAR` works.
- `--tmpfs <dir>` masks a directory. `--ro-bind /dev/null <file>` does not mask
  a file readably: the bind is nodev, so `open` fails with `EACCES`. Bind
  `pkgs.emptyFile` over the file instead.
- `kernel.apparmor_restrict_unprivileged_userns = 0`,
  `user.max_user_namespaces = 121707`.

## Pinning and bumps

The input URL carries the rev. Every root flake input is an auto-merging update
lane with no opt-out, and a sandbox-policy library must not move through it;
with the rev in the URL, the sweep's `nix flake update jail-nix` is a no-op.
Upstream has no inputs, so there is no `follows`.

To bump:

1. Edit the rev in the `jail-nix.url` line of `flake.nix`, then
   `nix flake lock`.
2. `devenv tasks run --mode before generate:all` regenerates `devenv.yaml`;
   `config/generate-devenv-yaml.nix` projects a sourcehut node as
   `sourcehut:<owner>/<repo>/<rev>`.
3. `devenv update jail-nix` syncs `devenv.lock`.
4. `checks.devenv-inputs-drift` compares all three, and the checks below
   exercise the new rev.

## No patch seam, no pkgs pin

There are no patches, so `src` is the input's own source tree. An `applyPatches`
seam would import from a derivation output on every evaluation for nothing. When
a patch is needed, point `src`, `init` and `extend` at a patched tree in that
change.

The library takes the caller's `pkgs` and pins nothing: no wrapper built from it
is published, so there is no cache hit to protect.

## Checks

Both live in `checks/jail-nix.nix` under
`lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux`, so their names are absent
on Darwin.

- `jail-nix-trivial` renders a jail around coreutils' `true` and requires the
  bubblewrap store path and `-- <exe>` in the wrapper. It then runs the wrapper
  only when an independent `bwrap --unshare-all --ro-bind / / -- true` succeeds
  inside the build sandbox. The log and `$out` say which branch ran:
  `JAIL-NIX-TRIVIAL: executed …` or `JAIL-NIX-TRIVIAL: structural-only …`. A
  cached result prints neither; read `$out`.
- `jail-nix-extend` adds a `probe` combinator through `extend` and requires
  `--setenv JAIL_PROBE` in the rendered wrapper.
