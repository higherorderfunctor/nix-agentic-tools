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
only a typed tool leaf keeps the inherited raw keys. A typed leaf a runtime
leaves unset inherits the root leaf's definition at the root's own priority. The
owner's per-tool assertions (git-branchless's `test.jobs`/`test.strategy`
coupling, say) hold wherever the tree mounts.

## Guest-fixed keys

Two keys are forced on top of everything, because the guest is not a trusted Git
client:

- `core.sshCommand` runs a store script that refuses: it prints that pushes go
  through the guest's `origin` remote, which the host relay serves, and exits
  non-zero. The guest holds no credentials.
- `safe.directory` trusts `/mnt/seed`, the path `repo-guest.nix` clones from,
  even though the host owns it.

A consumer value for either key loses wholly; a `safe.directory` list is
replaced, never appended.

## Delivery

The merged tree renders per runtime (`lib.generators.toGitINI`) and installs as
the guest's SYSTEM configuration, `/etc/gitconfig`:

- a protected scope, the only one `safe.directory` and a forced
  `core.sshCommand` hold in — a repository-local file cannot override them;
- a file, because git-absorb and git-revise are libgit2 and read files only.

The standalone factory takes the same render explicitly:

```nix
inputs.nix-agentic-tools.lib.ai.mkSandbox pkgs {
  exe = lib.getExe pkgs.hello;
  gitConfig = lib.generators.toGitINI {
    core.editor = "nano";
    safe.directory = ["/mnt/seed"];
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
list, the rendered file parsing with real Git, and the module-built launcher's
guest carrying the file and an enabled tool's package. The
`microvm-git-launcher` check is a hand-run KVM smoke launcher asserting
`git config --system` in a live guest; CI boots no VM.
