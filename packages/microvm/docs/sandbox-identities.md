# Sandbox Git identities

> **Last verified:** 2026-11-02 — signer services and session-only relay wiring
> are checked on Home Manager and devenv. Real guest boots verify signed and
> unsigned identity launches; see [signing](sandbox-signing.md).

`ai.sandbox.git.identities` supplies author details and explicit push keys:

```nix
{inputs, ...}: let
  redact = inputs.nix-agentic-tools.lib.redact;
in {
  ai.claude.enable = true;
  ai.sandbox = {
    enable = true;
    git.identities.bot = {
      push.key = redact.file "/run/secrets/bot-push-key";
      remotes."github.com" = {};
      user = {email = "bot@example.invalid"; name = "Example Bot";};
    };
  };
}
```

Runtimes with a guest route mirror `git.identities` and `git.forges`. A runtime
assignment, including `mkDefault`, replaces the whole root set. To keep selected
entries, use
`ai.codex.sandbox.git.identities = { inherit (config.ai.sandbox.git.identities) bot; };`.
Omit entries to remove them; there is no identity `enable` option. Runtime
definitions do not flow back to the root.

`user.name`, `user.email`, and `push.key` are required. `push.key` has the
relay's `redact.types.secretFile` type, so plaintext keys are refused without
printing their contents. `signing.key` accepts the same reference type or null
(default). A non-null signing key creates one dedicated signer per routed
runtime and identity. Null means unsigned commits and no signing door.

Each `remotes.<token>.forge` defaults to `<token>`. The token is the host
exactly as written in the remote URL, including case and SSH aliases. For
example, `remotes.github-work.forge = "github.com"` maps
`git@github-work:org/repo.git` to the real forge without reading
`~/.ssh/config`. Two identities claiming the same token in a sandbox-enabled
runtime fail an assertion naming the token and both identity option paths.
Tokens and forge hosts use the relay's DNS/IPv4 grammar.

`git.forges.<host>.hostKeys`, `sshPort`, and `sshUser` default to null. Non-null
fields override the shared relay forge facts independently; null retains those
facts. Codeberg, GitHub, and GitLab have built-in pins. Endpoint defaults are
port 22 and user `git`. A custom forge needs explicit nonempty `hostKeys`:

```nix
ai.sandbox.git.forges."git.example.org" = {
  hostKeys = "[git.example.org]:2222 ssh-ed25519 <public-host-key>";
  sshPort = 2222;
  sshUser = "bot";
};
```

There is no first-use trust. Every declared identity's remote must resolve to
pins, even if that runtime is disabled. Runtime `forges` assignment also
replaces the root set before merging non-null fields over built-ins. Active
runtimes sharing a forge must resolve identical pins; divergent pins fail
evaluation with both runtime option paths.

The standalone `sandbox-select <table.json>` reads the current checkout's raw
Git config. Push-remote precedence is `branch.<name>.pushRemote`,
`remote.pushDefault`, `branch.<name>.remote`, then the sole configured remote or
`origin`. A detached HEAD skips branch-specific settings.
`remote.<name>.pushurl` takes precedence over `url`; multiple selected URLs
refuse selection and list the URLs. `insteadOf` and SSH configuration never
rewrite the token.

Accepted URL forms are `ssh://[user@]host[:port]/path`, `[user@]host:path`,
`https://host[:port]/path`, and `git://host/path`. Selection uses only the
token; local/file URLs and unmatched tokens refuse with the runtime's
identity/token list. SSH URL users and explicit SSH ports override forge
defaults; HTTPS ports do not become SSH ports. Repository paths are preserved,
including existing `.git` suffixes and the distinction between home-relative SCP
paths and absolute SSH URL paths. Nothing appends `.git`.

Success is JSON `{credential, upstream, token, identity}`; no repository or no
push remote emits JSON `null` and exits zero, meaning no doors. The pure table
builder records each token's identity, `<runtime>-<identity>` credential, real
forge, endpoint defaults, and store pin file. Keys never enter that table.

When a guest-routed runtime has identities, the module creates
`ai.git-relay.instances.sandbox` with `settings.sessions = true` and no static
repositories. Home Manager defaults to port 19418; devenv to 19419. Set the
instance's native `port` option to move it. No identities means no generated
instance. Runtimes without guest routes contribute no credentials.

Each credential carries the identity's push key and a deduplicated list of its
real forge hosts. The relay checks that current list on every push, so removing
the credential or its last route to a forge revokes forwarding there. Removing
one alias while another still authorizes the same forge retains that forge's
authorization. Native credential and forge-pin definitions win over generated
defaults. Generated pins have priority 900 to beat the relay's built-in
`mkDefault` pins; ordinary consumer definitions have priority 100. Static
repositories and turning off session-only mode are refused for this instance,
preventing guest access to predictable static repository URLs.

A runtime launcher with identities runs selection before boot. Its single notice
lists the runtime's identities, remote token and selected identity. It mentions
replacement semantics only when that runtime defines its own identity set. An
unmatched remote refuses launch. Outside a repository it boots with no doors;
inside a repository with no push remote it still seeds committed work, with no
relay door or identity. Runtimes without identities retain their existing
launcher. Kiro, Kimchi and Copilot still have no guest route.

For a match, the launcher creates a random 128-bit session token and holds its
lock before opening the relay session. It reads the relay package, port and
state directory from `ai.git-relay.instances.sandbox`, including native
overrides and backend-specific state roots. Session management uses the
service's public config template to validate credential references; it never
reads push keys or writes pin files. Session creation requires existing daemon
pins, so an old launcher cannot restore rotated or removed pins. The running
daemon and forwarding hooks use its resolved config and current pins. A
`git ls-remote` probe of the new session must succeed before boot; failures name
the instance's `port` option. Start the relay first (`devenv up` on devenv).

The guest receives a port-9418 door to that relay and a launch-time Git config
through fw_cfg; a signing identity also gets a dedicated agent door. The random
session URL never enters the store or kernel command line. After cloning the
object seed, its final config include supplies `user.name`, `user.email`,
commit/tag signing settings, and the session's `remote.origin.url`. Fetch and
push share that URL, `remote.origin.prune` is false, and an attached or unborn
branch tracks its same-named origin branch. Detached HEAD remains detached. The
final include overrides consumer identity settings; no operator identity, key or
agent is inherited.

The relay session borrows the host common object directory, so Git advertises
existing objects and pushes transfer new objects. The factory pins seeded roots
before the guest starts and retains its graceful-shutdown recovery behavior.
Shallow, partial and alternates-using repositories remain refused. Matched
SHA-256 repositories are refused because the relay initializes SHA-1 sessions;
no-door object seeds still support both formats. Fetch exposes this session's
pushed refs; refreshing from upstream remains deferred. On exit the launcher
closes its session before releasing the lock. Concurrent relay GC skips held
locks, including sessions whose guest is running.
