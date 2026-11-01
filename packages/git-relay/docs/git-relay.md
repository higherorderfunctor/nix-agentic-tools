# git-relay

<!-- cspell:ignore Codeberg -->

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
  credential. Each push resolves its key from the current `GIT_RELAY_CONFIG`;
  removing the credential revokes pushes without deleting the old key file.
- `settings.listen`: bind address, loopback by default. Only configured
  repositories are served; removed repositories stay on disk, unserved.

## Security

The daemon, receive-pack and hooks ignore global/system Git configuration and
inherited command-scope configuration. Empty initialization templates exclude
host hooks; new repositories use Git's built-in default HEAD branch. Forwarding
uses the repository's credential and pin file with strict host verification, no
SSH config, default-key fallback, agent, prompt or global known-hosts fallback.
It skips pre-push hooks and does not advertise push options, which are not
forwarded.

The git protocol has no authentication: anything reaching the listen address can
push to any configured repository with its assigned credential. Keep that
address private. The daemon user can read the keys; this relay protects them
from pushing agents only when those agents cannot read the host runtime files.
The relay does not synchronize later upstream changes or reconcile concurrent
upstream writes. Transport failure after upstream accepts a push can leave the
relay behind; failure cannot roll back an already accepted upstream push.
