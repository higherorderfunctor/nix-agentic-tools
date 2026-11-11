## CLIProxyAPI instance client keys and routes

> **Last verified:** 2026-11-07 — carries the proposed architecture decision for
> named routing; named client keys generate CPA access keys and allowlist rules
> from credential routes. Conflicting hand-written entries are refused.

## Architecture decisions

- **PROPOSAL (not yet vetted): CPA instances own named routing.** Each
  `ai.cliproxyapi.instances.<name>` declares upstream `credentials` and
  `clientKeys` once. Each client key routes only to named upstream credentials;
  OAuth rules carry exact auth-file IDs, API-key rules carry exact base URLs,
  and one API table lowers those credentials. A Harness selects
  `settings.inference = {instance; clientKey;}` without publishing keys or
  rules. External `url` + `key` selections add nothing to Instances. See
  `lib/ai/inference/default.nix`, `packages/cliproxyapi/lib/providers.nix` and
  `packages/cliproxyapi/modules/instances.nix`.

`ai.cliproxyapi.instances.<name>` registers an enabled instance at
`http://127.0.0.1:<port>`. Each `clientKeys.<name> = {key; routes;}` entry
contains a redacted client key and routes to named upstream credentials
(`cliproxyapi-providers.md`). The instance adds the key to `access.api-keys` and
maps its routes to an `access.key-allowlist` entry. The selected harness
receives the same key through `normalized.settings.inference`; CPA fails closed
for each listed key (`cliproxyapi-key-allowlist.md`).

A harness selects an existing instance and client key; it must not define the
instance. Defining it at the selection site would make a misspelled name look
valid, and checking existence from that definition would recurse. Multiple
harnesses can select the same named client key. A client key decides upstream
access; separate local harness state requires `CLAUDE_CONFIG_DIR` or
`CODEX_HOME`.

A named client key also listed by hand in `access.api-keys`, or given a
hand-written `access.key-allowlist` entry, is refused: a second owner could
widen or contradict its routes. Evaluation compares references, not secret
values; distinct references resolving to the same key are rejected by CPA at
startup or leave the old config on reload. `providersLib.clientKeyType` requires
a redact reference.

An external `url` selection adds no instance keys or rules. A hand-written key
of another client stays allowed, but once named client keys set the allowlist,
that key needs its own hand-written entry.

A route selecting `api = "passthrough"` grants the named JSON group through
`passthrough-<lowercase-name>`, `kind = "apikey"` and its base URL reference.
The API may be omitted when it is the credential's sole API. Groups sharing a
base URL remain separate grants. The client key and rules stay available for
`POST /v1/passthrough`, while the entire route is omitted from harness inference
credentials and model lists. See `cliproxyapi-passthrough.md` for the named Nix
shape, envelope options and secret URL references.
