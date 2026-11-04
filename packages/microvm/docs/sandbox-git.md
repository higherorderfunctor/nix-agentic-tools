# MicroVM sandbox Git settings

<!-- cspell:ignore maxstack rerere sendemail sshcommand -->

> **Last verified:** 2026-11-04 — `ai.sandbox.git` options, per-runtime
> copy-down, guest-fixed keys, the refused-key list, and delivery as the guest's
> system Git configuration.

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

Every runtime with a guest route mirrors the whole tree at
`ai.<runtime>.sandbox.git`, including each tool's `{enable, settings}`. Tool
`enable` installs the tool's package into that runtime's guest package list; a
runtime `enable` replaces the shared root's at any priority.

## Copy-down semantics

The raw `settings` tree copies down by DEFINITIONS, not evaluated values: a
runtime `git.settings` definition replaces the root's whole value, and otherwise
the root's definitions forward with their nested `mkOverride` wrappers intact.
So a nested `mkDefault` key at the root still loses to a runtime value or a
typed tool leaf for that key, and an equal-priority disagreement stays a loud
conflict — exactly as the host's `git.settings` behaves. A runtime that defines
only a typed tool leaf keeps the inherited raw keys. The root's typed leaves
forward into the runtime's typed tree as weak defaults: a runtime's own
definition of the same leaf replaces the root's, as a runtime `settings` or
`enable` does, and a raw key at normal priority also beats a root typed leaf. So
the owner's per-tool assertions (git-branchless's `test.jobs`/`test.strategy`
coupling, say) read root and runtime values together, wherever the tree mounts.
And because the system file is the lowest Git scope the guest reads, an unset
leaf there is upstream's default: git-branchless's lowest-scope check rejects a
`test.jobs` above 1 without `test.strategy = "worktree"`, exactly as the Home
Manager user-global tree already does.

## Guest-fixed keys

Two keys come last in the file, because the guest is not a trusted Git client:

- `core.sshCommand` runs a store script that refuses: it prints that pushes go
  through the guest's `origin` remote, which the host relay serves, and exits
  non-zero. The guest holds no credentials.
- `safe.directory` trusts `/mnt/seed`, the path `repo-guest.nix` clones from,
  even though the host owns it. An empty first value resets the list a consumer
  built.

They are appended after the consumer's render, not merged into it. Git takes the
last value of a single-valued key whatever the case of its section and key
names, so any consumer value for either key, in any spelling, loses.

## Refused keys

The file is built into the Nix store, which any local user reads, and the guest
holds no credentials. So `settings` fails evaluation when the shared root or a
runtime sets one of a fixed list of keys, in any case and under any subsection:

- the `credential`, `gpg`, `include`, `includeIf` and `sendemail` sections;
- `core.askPass`, `core.gitProxy` and `core.hooksPath` (programs and a hooks
  directory taken from the host);
- `http.cookieFile`, `http.extraHeader`, `http.sslCert` and `http.sslKey`,
  including their `http.<url>.*` forms;
- `url.*.insteadOf`, `url.*.pushInsteadOf` and `user.signingKey`;
- a `remote.*.url` or `remote.*.pushurl` value, or a `url.*` subsection, that is
  a URL with userinfo of any form (`https://user:secret@host/`,
  `https://token@host/`, `ssh://git@host/`).

The message names the key and the option that sets it. The list is what is
checked, not a scan of values: a credential in any other key (userinfo in
`http.proxy`, a secret in an `alias.*` command) is not seen, and a consumer who
puts one there still writes it into the world-readable file.

## Delivery

The merged tree renders per runtime (`lib.generators.toGitINI`), followed by the
guest-fixed keys, and installs as the guest's SYSTEM configuration,
`/etc/gitconfig`:

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
  gitConfig = lib.generators.toGitINI {core.editor = "nano";};
  outName = "sandbox-hello";
}
```

`gitConfig` defaults to null: no system configuration, and the factory call is
byte-identical to before the parameter existed. A `repo = true` call appends its
`safe.directory` entry for the seed after `gitConfig`, so a caller never lists
it by hand.

## Checks

`microvm-git-launcher` is the hand-run KVM check that runs `git config --system`
in a live guest; CI boots no VM.
