# MicroVM sandbox Git settings

<!-- cspell:ignore maxstack rerere sshcommand -->

> **Last verified:** 2026-11-01 — `ai.sandbox.git` options, per-runtime
> copy-down, guest-fixed keys, and delivery as the guest's system Git
> configuration.

`ai.sandbox.git` configures Git inside every enabled runtime's guest. The option
types are the host's, so one value plugs into host and sandbox alike: `settings`
is the same ini tree as `git.settings` (lib/git-tool-settings/ini-type.nix), and
each tool's typed settings are the owner's generated tree, the same one
`git.<tool>` declares on the host.

```nix
{pkgs, ...}: {
  ai.sandbox.git = {
    settings.core.editor = "nano";
    absorb.enable = true;
    branchless.settings.restack.defaultRevset = "main()";
  };
  ai.codex.sandbox.git.settings.core.editor = "vim";
}
```

Every runtime mirrors the whole tree at `ai.<runtime>.sandbox.git`, including
each tool's `{enable, settings}`. Tool `enable` installs the tool's package into
that runtime's guest package list; a runtime `enable` replaces the shared root's
at any priority.

## Copy-down semantics

The raw `settings` tree copies down by DEFINITIONS, not evaluated values: a
runtime `git.settings` definition replaces the root's whole value, and otherwise
the root's definitions forward with their nested `mkOverride` wrappers intact.
So a nested `mkDefault` key at the root still loses to a runtime value or a
typed tool leaf for that key, and an equal-priority disagreement stays a loud
conflict — exactly as the host's `git.settings` behaves. A runtime that defines
only a typed tool leaf keeps the inherited raw keys. A typed leaf's definitions
reach the runtime's typed tree forwarded at the root's own priority — a leaf
both sides define arbitrates by that priority — so the owner's per-tool
assertions (git-branchless's `test.jobs`/`test.strategy` coupling, say) read
root and runtime values together, wherever the tree mounts. And because the
system file is the lowest Git scope the guest reads, an unset leaf there is
upstream's default: git-branchless's lowest-scope check rejects a `test.jobs`
above 1 without `test.strategy = "worktree"`, exactly as the Home Manager
user-global tree already does.

## Guest-fixed keys

Two keys are forced on top of everything, because the guest is not a trusted Git
client:

- `core.sshCommand` runs a store script that refuses: it prints that pushes go
  through the guest's `origin` remote, which the host relay serves, and exits
  non-zero. The guest holds no credentials.
- `safe.directory` trusts `/run/sandbox/seed` and `/mnt/objects`, the paths
  `repo-guest.nix` reads, even though the host owns them.

A consumer value for either key loses wholly; a `safe.directory` list is
replaced, never appended. Git folds the case of section and key names and Nix
does not, so a key differing from one of these only by case renders as a second
key Git reads as the same one — and the line that renders last wins. Such a key
fails evaluation, with a message naming the fixed key.

## Delivery

The merged tree renders per runtime (`lib.generators.toGitINI`) and installs as
the guest's SYSTEM configuration, `/etc/gitconfig`:

- the protected scope `safe.directory` is honored in — Git ignores it in
  repository-local files — and a file, because git-absorb and git-revise are
  libgit2 and read files only;
- the guest's lowest Git scope. `safe.directory` cannot be re-added by a
  repository-local file (protected scope), but `core.sshCommand` follows
  ordinary Git precedence: a guest process can override it through `--global`,
  repository-local or `-c` configuration. The forced system value refuses an
  ordinary push and names `origin`; it is not an SSH boundary. The boundary is
  the guest itself, which holds no SSH credentials — pushes are meant to go
  through `origin`, which the host relay serves.

The standalone factory takes the same render explicitly:

```nix
inputs.nix-agentic-tools.lib.ai.mkSandbox pkgs {
  exe = lib.getExe pkgs.hello;
  gitConfig = lib.generators.toGitINI {
    core.editor = "nano";
    safe.directory = ["/mnt/objects" "/run/sandbox/seed"];
  };
  outName = "sandbox-hello";
}
```

`gitConfig` defaults to null: no system configuration, and the factory call is
byte-identical to before the parameter existed. A non-repo call passes null and
a repo call keeps its own `safe.directory` default; a given `gitConfig` replaces
that default.

## Checks

`packages/microvm/checks/git.nix` covers the priority matrix (raw-only, raw plus
typed leaf, nested default versus typed, whole-option replacement,
equal-priority conflict, forced keys), enable propagation into the guest package
list, the `test.jobs`/`test.strategy` coupling holding across the
root-to-runtime typed copy-down, case-variant guest-fixed keys refused, the
rendered file parsing with real Git, and the module-built launcher's guest
carrying the file and an enabled tool's package. The `microvm-git-launcher`
check is a hand-run KVM smoke launcher asserting `git config --system` in a live
guest; CI boots no VM.
