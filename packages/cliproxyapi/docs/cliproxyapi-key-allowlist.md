# CLIProxyAPI client-key allowlist

> **Last verified:** 2026-10-22 — the patch applies to CPA 8.0.38 with no fuzz;
> loading rejects duplicate client keys and startup exits 1 on refusal. Hot
> reload can briefly serve a retired config credential under newly widened
> rules, so rotation that also widens access requires a restart or an `ids`
> rule.

## Why selection lives in CPA

One CPA instance must bind an authenticated client key to eligible upstream
credentials. A plugin cannot enforce this: if its scheduler fails, unloads, or
returns unhandled, native selection resumes over the full pool. Home mode never
invokes the plugin scheduler. The instance module therefore refuses
`plugins.enabled` with a nonempty allowlist, and CPA refuses Home dispatch while
the allowlist is set. Separate instances were rejected by the operator on
2026-10-21.

CPA's access middleware records the authenticated key for headers, `?key=`, and
`?auth_token=`. The patch uses that recorded principal in candidate selection.
Missing or unknown keys select nothing while the allowlist is set; an absent or
empty allowlist leaves native selection unchanged. A configured key whose
eligible credentials are unavailable gets `auth_not_found`. Model listings still
expose all models.

An entry identifies one client key and grants a list of credential rules. The
client key is a redact reference shared with `access.api-keys[]`. A rule
requires `provider` and `kind` (`oauth` or `apikey`); `ids` and `base-urls`
narrow it further. The provider is CPA's credential provider, including
`openai-compatible-<name>` for compatibility groups. An OAuth credential's ID is
its auth-file path. A config API key's ID hashes its secret, so use provider and
`base-urls` to address a group through rotation. The settings types and module
refinements are documented in `cliproxyapi-settings.md`.

The `apikey` kind matches only credentials synthesized from config. A
store-loaded login can temporarily classify as `apikey` from its file or a Meta
refresh before the watcher marks it `oauth`; allowing it through an `apikey`
rule would cross the intended boundary. An OAuth rule can match such a login by
ID once its kind is OAuth. Whoever writes the auth directory controls
file-sourced provider and ID, so high-value OAuth rules should use `ids`.

`base-urls` compares the credential's trimmed `base_url` with each listed URL
after trimming. Scheme, host, path, case, and trailing slash still matter. A
group without an explicit base URL may have no attribute and cannot match this
narrowing; set `base-url` explicitly for default-endpoint Claude, Gemini, and
Interactions groups. A rule with `base-urls` never matches OAuth, even if an
OAuth login carries that attribute; the instance module refuses that
combination. A listed URL absent from the configured groups is accepted but
selects nothing. Key-less OpenAI compatibility groups have no matching kind and
cannot be reached while the allowlist is set.

## Duplicate keys and load paths

Two entries with the same trimmed client key would merge rules into one
principal and widen access. CPA rejects them by entry index, without logging the
secret. Validation runs after decoding in both `LoadConfigOptional` and
`ParseConfigBytes`: cloud-deploy turns decode errors into an empty config, so
validation inside the decoder would erase a refusal. Initial load (including
cloud-deploy's optional load), hot reload, management writes, and Home pushes
all reach one of these paths. Startup exits 1 before serving; hot reload retains
the previous config and retries a later valid write; management `PUT` answers
422 without writing; a Home push is refused. A caller that constructs `Config`
directly bypasses loading, so the Manager compiles duplicate entries into an
allowlist granting no key any credential. Empty client keys bind no request.

The eligibility predicate covers the legacy candidate loop, scheduler fast path,
retry, and cooldown waits. `SelectAuth` always uses the legacy loop; mixed
`Execute` with a built-in selector exercises the scheduler fast path. Plugin
schedulers receive only surviving candidates. Two 8.0.38 paths bypass that
predicate: Home dispatch, which is refused, and the Antigravity credits
fallback, which checks the allowlist itself. The fallback matters when selection
fails because a client key has no Antigravity rule. Plugin executors and
`host.auth.get` bypass eligibility; this is why enabling plugins must be
refused. `checks/key_allowlist_loops_test.go`, a go/types scan joined to the
auth package, fails on a `range` over `Manager.auths` whose own body calls no
allowlist predicate, unless the function is on its commented exemption list. It
does not see an indexed lookup (`m.auths[id]`), an alias of the map, the map
passed to a helper, or a loop over a copy (`snapshotAuths`, `List`), so a bump
that touches candidate selection still needs source review even if it is green.

## Reload ordering limitation

The watcher publishes the new allowlist before it re-synthesizes config
credentials and asynchronously deletes retired IDs. During that interval an old
credential remains selectable if the new rule grants its provider or base URL.
For example, a reload rotates a Claude key at URL A from secret `sOld` to `sNew`
and grants client K URL A: K may briefly spend on `sOld`. The interval has not
been measured. The secret stays server-side. Narrowing and revocation take
effect first; `ids` rules are safe because the new secret produces a new ID. A
service restart registers credentials before listening and has no such window.
Publishing the allowlist after credential replacement would instead delay
revocation and could fail open, so that reorder was rejected.

## Bumping CPA

The package applies `patches/key-allowlist.patch` to the pinned source with
`-p1 --fuzz=0`; extraction and the Go check read that patched source. Fetch the
version from `sources.json` into scratch, verify its unpacked NAR hash, apply
the patch with `patch --dry-run -p1 --fuzz=0`, and inspect every changed
candidate-selection loop before regenerating the diff. Offset-only moves may
apply; changed context fails. The Go check covers behavior; the loop scan misses
the shapes listed above. Regenerate the extracted settings facts after a schema
change, then run the module assertions and Go check in CI.
