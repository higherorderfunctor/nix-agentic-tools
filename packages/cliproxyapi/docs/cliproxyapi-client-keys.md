## CLIProxyAPI instance client keys and routes

> **Last verified:** 2026-10-29 — named client keys generate CPA access keys and
> allowlist rules from credential routes. Conflicting hand-written entries are
> refused.

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
