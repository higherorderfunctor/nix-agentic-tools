# Sandbox commit signing

Add a signing key reference to an identity to sign its guest commits and tags:

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
      signing.key = redact.file "/run/secrets/bot-signing-key";
      user = {email = "bot@example.invalid"; name = "Example Bot";};
    };
  };
}
```

`signing.key = null` is the default: commits and tags are unsigned and there is
no signing door. The signer never inherits the operator's agent or keys. A
signing key has the same `redact.types.secretFile` type as the push key;
plaintext keys fail evaluation without printing their contents. The signing key
may also be the push key: the signing door forwards only key listing and Git's
`ssh-keygen -Y sign` requests, so the guest cannot sign an SSH login with it.
While it runs, the guest can sign any Git object with the identity's key.

Each sandbox-enabled runtime with a guest route gets one service for each
identity with a signing key: `sandbox-signer-<runtime>-<identity>`. The example
creates `sandbox-signer-claude-bot`. Home Manager emits a systemd user service;
devenv emits a process started by `devenv up`. Start the relay and signer before
launching the sandbox. Runtimes without a guest route generate no signers.

`ai.services` delivers the private key in a mode-0600 file inside the service's
mode-0700 runtime directory. The dedicated SSH agent loads only that key, using
an explicitly bound `SSH_AUTH_SOCK`. The signer first writes the key's public
half to `agent.sock.pub` and removes the private file once the agent holds the
key. Home Manager's directory follows its runtime environment; devenv uses
`config.devenv.runtime`, keeping evaluations separate. The sandbox launcher
reads the directory from the evaluated service. Neither private keys nor key
paths enter the guest, its command line, or its identity blob. The guest can
request Git signatures through the filtered door.

After URL identity selection, the launcher runs `ssh-add -L` against that
identity's socket. A stopped, empty, locked or multi-key agent, or one holding a
key other than `agent.sock.pub`, refuses launch before boot and names the
service to start or restart. An unsigned identity needs no signer. No repository
or no push remote still means no doors.

For a signing identity, the final repository configuration contains
`gpg.format = ssh`, `user.signingKey = key::<public key>`, and enabled
`commit.gpgSign` and `tag.gpgSign`. Its `gpg.ssh.allowedSignersFile` points to a
public file containing `<user.email> <public key>`; signing email principals
must be nonempty, contain no whitespace or commas, and not start with `#`,
checked at evaluation. This file and the identity configuration travel through
fw_cfg at launch. Run `git verify-commit HEAD` inside the guest to verify a
commit against that file.

The factory connects guest TCP port 2222 to the selected host socket through the
agent filter described in [the sandbox factory](sandbox.md). A guest service
bridges `/run/sandbox-signing/agent.sock` to that port, and the guest command
gets that socket as `SSH_AUTH_SOCK`. The relay still transports commits and
signatures unchanged to the upstream repository. No general host SSH agent is
forwarded.

A reference-file change restarts its signer through `ai.services`. A running VM
keeps its original public signing key, so signing fails after key rotation until
relaunch. Guests sharing a runtime and identity share one agent; per-session
agents remain deferred.

The standalone factory still accepts `signing = {port; socket;}`. The runtime
identity launcher uses `socket = null` and supplies `SANDBOX_SIGNING_SOCKET` at
launch; the factory records it in the private runner directory for its door. A
signed `repoConfig` guest also requires `SANDBOX_ALLOWED_SIGNERS`, transported
alongside `SANDBOX_REPO_CONFIG` as public verification data.

`microvm-signing-*` checks cover both backends, service cardinality, key typing
and both halves of the door. `microvm-sandbox-session-boot` generates its own
keys, starts the evaluated signer service, signs and verifies guest commits,
verifies upstream signatures, refuses unavailable, non-single-key or swapped
signers, and runs an unsigned identity with no signing socket. It boots guests
one at a time and requires KVM.
