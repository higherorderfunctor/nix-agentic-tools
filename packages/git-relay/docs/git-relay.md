# git-relay

> **Last verified:** 2026-11-01 — the packaged daemon forwards a push atomically
> and refuses it when the forward fails; `ai.git-relay.instances` runs it as a
> service on Home Manager and devenv; both are checked in
> `packages/git-relay/checks/`.

`git-relay` is a `git daemon` that agents push to instead of their real remote.
Its pre-receive hook forwards the whole push atomically (`git push --atomic`) to
the repository's upstream with a key the agent never holds, and refuses the push
when the forward fails, so the relay is never ahead of its upstream. Force
pushes and deletes pass through. Fetching from the relay works too.

## Options

`ai.git-relay.instances.<name>` uses the shared instances helper
(`packages/ai-module/docs/DESIGN.md`, Services): service `git-relay-<name>`,
port `19418` by default, state in `stateDir`.

- `settings.repositories.<name>.upstream`: served as
  `git://<listen>:<port>/<name>.git`. Only listed repositories are served;
  repositories dropped from the list stay on disk, unserved.
- `settings.sshKeyFile`: a redact reference to the push key, delivered as the
  path of a 0600 file (`dev/fragments/redact/redact.md`, Secret files). Null
  forwards with no ssh identity.
- `settings.knownHosts`: pinned host keys, GitHub's ed25519 key by default. The
  launcher writes them to a file in `stateDir` because ssh wants one.
- `settings.listen`: the bind address, loopback by default.

The launcher exports `GIT_SSH_COMMAND` with that identity, clearing any
inherited one; the hook reaches it through the daemon's environment.

## Security

The relay is a boundary only when the pushing agent runs in a VM or under
another uid. On the daemon's uid an agent can read the key file. The git
protocol has no authentication, so anything that reaches `listen:port` can push
to a configured repository. The relay adds no ref limit of its own: a
server-side ruleset, such as GitHub's protection of `main`, applies to the
forward.
