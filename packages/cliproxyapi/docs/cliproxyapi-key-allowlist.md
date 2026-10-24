# CLIProxyAPI client-key allowlist

> **Last verified:** 2026-10-24 — the patch applies to CPA 8.0.41 with no fuzz;
> loading rejects duplicate client keys and startup exits 1 on refusal. Hot
> reload can briefly serve a retired config credential under newly widened
> rules, so rotation that also widens access requires a restart or an `ids`
> rule. Named instance client routes derive secret OAuth account rules or API
> base-URL rules. Model catalogs use selection's eligibility predicate.

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
eligible credentials are unavailable gets `auth_not_found`. With no upstream
credential serving a requested model, CPA returns
`400 unknown provider for model <name>`. Log in with
`cliproxyapi -config <file with auth-dir> -claude-login -no-browser` (or
`-codex-login`), or through Manager Plus; CPA watches login files and new
matching accounts become eligible when registered, without restarting the
instance.

An entry identifies one client key and grants a list of credential rules. The
client key is a redact reference shared with `access.api-keys[]`. An Instance
owns named client keys and upstream credentials (`ai-proxy.md`); each named
route generates one rule, and Harness selection adds no rules. Write settings
entries by hand only for other clients. A rule requires `provider` and `kind`
(`oauth` or `apikey`); `accounts`, `ids` and `base-urls` narrow it further.
Generated compatibility-provider rules follow CPA's name normalization in
`internal/util/provider.go`. An OAuth credential's ID is its login path relative
to `<stateDir>/auth`. Named upstream credentials require `oauth.vendor` and
`oauth.account` (a redact reference), lowering to an `accounts` rule through the
existing secret renderer. An account rule matches only OAuth with a nonempty
native `AccountInfo()` email, compared case-sensitively after trimming both
values. `AccountInfo()` reads `Metadata.email`, with a service-account
`client_email` fallback (`sdk/cliproxy/auth/types.go:788`). An account with no
matching login selects nothing; several matching logins remain eligible.
`accounts` combined with `kind = "apikey"` matches nothing. A config API key's
ID hashes its secret, so use provider and `base-urls` to address a group through
rotation. The settings types and module refinements are in
`cliproxyapi-settings.md`.

The `apikey` kind matches only credentials synthesized from config. A
store-loaded login can temporarily classify as `apikey` from its file or a Meta
refresh before the watcher marks it `oauth`; allowing it through an `apikey`
rule would cross the intended boundary. An OAuth rule can match such a login by
ID once its kind is OAuth. Whoever writes the auth directory controls
file-sourced provider and ID, so high-value OAuth rules should use `accounts` or
`ids`.

`base-urls` compares the credential's trimmed `base_url` with each listed URL
after trimming. Provider URL constraints are in `ai-proxy.md`. Scheme, host,
path, case, and trailing slash still matter. A group without an explicit base
URL may have no attribute and cannot match this narrowing; set `base-url`
explicitly for default-endpoint Claude, Gemini, and Interactions groups. A rule
with `base-urls` never matches OAuth, even if an OAuth login carries that
attribute; the instance module refuses that combination. A listed URL absent
from the configured groups is accepted but selects nothing. Key-less OpenAI
compatibility groups have no matching kind and cannot be reached while the
allowlist is set.

## Model listings

Codex's `GET /v1/models?client_version=...` already builds its picker from all
registered providers through CPA's OpenAI model registry projection. It includes
registered Claude API-key models, and Responses requests can select the Claude
executor, which translates them to Anthropic Messages. No extra catalog or
invented model metadata is needed.

With an allowlist, the shared model-response writer retains a model only when an
enabled credential passes selection's `authSelectionEligibility.allows` and its
existing route-model support check. The rules come from the Manager's current
atomic snapshot, including on hot reload. A missing or unknown client key gets
an empty catalog. An absent or empty allowlist preserves the native response,
byte for byte when it was already serialized.

For example, a `personal-codex` route granting Codex OAuth plus Anthropic
API-key credentials at `https://api.anthropic.com` lists both their registered
models, including a configured `claude-opus-5-5`. A Codex-only key does not list
that Claude API-key model. A `personal-claude` route granting only Claude OAuth
lists only those OAuth models. A credential's scheduling priority, including
`-1`, does not remove its models from this eligibility check.

The hook handles Codex `models[].slug` and OpenAI/Anthropic `data[].id`;
Anthropic `first_id` and `last_id` are recomputed after filtering. It preserves
wire IDs and existing builder metadata. Eligibility checks public route IDs,
including aliases, using selection's own route-model lookup. For Anthropic's
cloaked IDs, the hook applies the same existing inverse mapping as the request
handler before checking eligibility, and returns the original wire ID. Unknown
envelopes and missing or non-string IDs fail closed with HTTP 502. Gemini's
`models[].name` entries are deferred and receive that refusal when an allowlist
is configured. An empty or null `data` or `models` array safely becomes an empty
catalog without inspecting entry IDs.

This changes listing visibility only; credential selection remains the
enforcement boundary. The unused Caddy front gate was removed because it was
never wired in and cannot supply CPA's shared credential-eligibility decision.
The shared Caddy helpers remain in use by the MCP proxy.

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
schedulers receive only surviving candidates. Two 8.0.40 paths bypass that
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

## Credential tool shims

`patches/zai-tool-shims.patch` adds two opt-in credential settings for the
pinned CPA 8.0.41. They repair measured z.ai compatibility failures without
changing credential selection. Named credentials with `vendor = "z-ai"` default
both on: `apiKey.toolAliases = {ToolSearch = "ToolSearch_";}` and
`apiKey.codexShellArgCleanup = true`. Set them to `{}` and `false` to disable
them; other vendors default both off.

### Anthropic tool names

In 12/12 exact-name probes, a client tool named `ToolSearch` made z.ai hide the
other declared tools and expose its native `tool_search_tool_regex`. Renaming it
to `ToolSearch_` restored the other tools, including deferred tools;
`tool_reference` results were accepted. Removing deferred declarations or tool
references therefore addresses the wrong cause. Related public reports are
[Magpie #3253](https://github.com/yetone/magpie/issues/3253) and
[Claude Code #104309](https://github.com/anthropics/claude-code/issues/104309).

Each `api-keys.claude[]` group can set `tool-aliases`, a client-to-upstream name
map inherited by its keys. Synthesis carries that map on the selected
credential. The executor reuses its existing forward-map rewriting for
declarations, tool choice, historical tool uses and tool references, then
reverses response tool-use names in both JSON and streamed content-block starts.
These static aliases use no OAuth thread store; the existing OAuth MCP alias
behavior remains unchanged.

Both config-load paths reject names outside 1–64 ASCII letters, digits,
underscores or hyphens, duplicate upstream names and an upstream name that is
another alias source. Nix checks the same conditions on merged Claude groups and
key entries. A target colliding with another tool declared in a request is
refused before dispatch: the caller's `tools[]` is unavailable at config load.

### Codex shell arguments from chat

All 23/23 rejected `exec_command` calls in the measured sample carried an empty
`justification`. Codex treats that empty string as a present value, and
[PR #36350](https://github.com/openai/codex/pull/36350) requires an explicit
`sandbox_permissions` whenever justification is present. A model obeying the
instruction to omit sandbox permissions can therefore fail before execution
solely because it sends `justification = ""`.

`api-keys.openai-compatibility[].codex-shell-arg-cleanup` applies only when the
selected group's chat response becomes a Responses result. For `exec_command`
and `shell_command` function calls in the empty or `functions` namespace, it
removes justification when empty or when sandbox permissions are absent, and
removes an empty prefix-rule array. A real justification with
`sandbox_permissions = "require_escalated"`, nonempty prefix rules, unrelated
namespaces and custom tools survive unchanged.

Cleanup covers non-streaming output, streamed
`response.function_call_arguments.done` and `response.output_item.done`, and the
completed response's output array. Argument deltas retain their upstream bytes.
Codex rust-v0.163.0's
[SSE parser](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/codex-api/src/sse/responses.rs#L354)
dispatches the complete output item and explicitly ignores function-argument
delta/done events; its
[WebSocket transport](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/codex-api/src/endpoint/responses_websocket.rs#L866)
uses the same parser. Its
[turn handler](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/core/src/session/turn.rs#L2801)
executes the completed item, so function-call deltas need no buffering for this
client.

`cliproxyapi-tool-shims` runs config, executor, translation and synthesis tests
from the same patched source as the package and extractor. It covers aliases and
history, response reversal, namespace matching, every final argument surface,
disabled settings and preserved escalation requests. Module checks cover
defaults, overrides, omitted plain-provider settings and invalid aliases on Home
Manager and devenv.

## Bumping CPA

The package applies `patches/key-allowlist.patch`, then
`patches/zai-tool-shims.patch`, to the pinned source with `-p1 --fuzz=0`;
extraction and the Go checks read that same patched source. Fetch the version
from `sources.json` into scratch, verify its unpacked NAR hash, apply the patch
with `patch --dry-run -p1 --fuzz=0`, and inspect every changed
candidate-selection loop before regenerating the diff. Offset-only moves may
apply; changed context fails. The Go check covers behavior; the loop scan misses
the shapes listed above. Regenerate the extracted settings facts after a schema
change, then run the module assertions and Go check in CI.
