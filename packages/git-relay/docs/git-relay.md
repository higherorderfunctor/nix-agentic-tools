# git-relay

<!-- cspell:ignore Codeberg urandom -->

`git-relay` serves `git://<listen>:<port>/<repository>.git` for agents to push
and fetch. Its pre-receive hook forwards each push atomically over SSH with a
key the agent never holds, and refuses the receive if forwarding fails. Force
pushes and deletes, including the relay's HEAD branch, pass through. The hook
writes no local refs; upstream policy decides which pushes are accepted.

## Options

`ai.git-relay.instances.<name>` uses the shared instances helper: service
`git-relay-<name>`, port `19418` by default, writable state in `stateDir`.

- `settings.credentials.<credential>.sshKeyFile`: required redact reference.
  `ai.services` delivers the key as a 0600 runtime file; plaintext and null keys
  are refused. Several credentials can share one relay instance.
- `settings.credentials.<credential>.forges`: the upstream hosts this credential
  may forward to. Every push re-reads the current config, so removing a host —
  or the whole credential — refuses the next push to it: revocation covers
  changed routing, not only deleted keys.
- `settings.forges.<host>.hostKeys`: pinned `known_hosts` lines. Built-in
  ed25519 pins cover Codeberg, GitHub and GitLab; publisher URLs live in
  `packages/git-relay/lib/forges.nix`. Consumer entries merge per host, and a
  consumer's `hostKeys` replaces that host's pins. Other hosts need explicit
  pins; the launcher writes `stateDir/known_hosts.d/<host>`. For a nondefault
  SSH port, supply matching `[host]:port` entries in that host's pins.
- `settings.repositories.<name>.upstream`: SSH URL, either
  `ssh://[user@]host[:port]/path` or `[user@]host:path`, with a DNS or IPv4
  host. Other transports and unpinned hosts are refused during evaluation and
  start.
- `settings.repositories.<name>.credential`: required name of a defined
  credential whose `forges` lists this upstream's host. Each push resolves its
  key from the current `GIT_RELAY_CONFIG`.
- `settings.sessions`: `true` serves only per-session repositories (below);
  static `repositories` are then refused.
- `settings.listen`: bind address, loopback by default. In static mode only
  configured repositories are served; removed repositories stay on disk,
  unserved.

## Sessions

`git-relay session open --token T --credential C --upstream U [--alternates DIR]`
creates `stateDir/repositories/sessions/T.git`, served as
`git://<listen>:<port>/sessions/T.git`. Session subcommands run from the
instance's state directory, like the daemon.

The caller holds `flock` on `stateDir/locks/T` for the session's whole life,
taking it BEFORE calling open; `open` and `close` refuse a lock they can take
themselves. A token is exactly 32 lowercase hex characters — 128 random bits, as
`od -An -tx1 -N16 /dev/urandom` prints — because it names the lock file, the
directory and the served URL. The upstream is validated with the same grammar as
static repositories and forwarded verbatim: scp-style `host:path` stays
home-relative, `ssh://host/path` stays absolute, and no `.git` suffix is
appended or removed. `--alternates` records one absolute object directory in the
session's `objects/info/alternates`.

`session close T` removes the session directory and its lock file; the caller's
exit trap is the usual caller. `session gc` removes session directories whose
lock it can take — a held lock marks a live session — and never touches lock
files without a session directory, which belong to callers between lock and
open. The daemon runs gc at every start, and every `open` runs it first.

An instance with `settings.sessions = true` serves only the `sessions`
directory: no static repositories may be configured, and the daemon whitelists
that one directory without `--strict-paths`, so a session opened under a running
daemon is served without a restart. Git's own request checks refuse `.` and `..`
path aliases, keeping every served path under `sessions/`; static repositories
are unreachable even when their directories remain on disk.

## Security

The daemon, receive-pack and hooks ignore global/system Git configuration and
inherited command-scope configuration. Empty initialization templates exclude
host hooks; new repositories, sessions included, use Git's built-in default HEAD
branch. Forwarding uses the repository's credential and pin file with strict
host verification, no SSH config, default-key fallback, agent, prompt or global
known-hosts fallback. It skips pre-push hooks and does not advertise push
options, which are not forwarded.

The git protocol has no authentication: anything reaching the listen address can
push to any configured repository with its assigned credential, and anything
that learns a session token can push to that session. Keep the address and
tokens private. The daemon user can read the keys; this relay protects them from
pushing agents only when those agents cannot read the host runtime files. The
relay does not synchronize later upstream changes or reconcile concurrent
upstream writes. Transport failure after upstream accepts a push can leave the
relay behind; failure cannot roll back an already accepted upstream push.
