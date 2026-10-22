# CLIProxyAPI client-key allowlist

> **Last verified:** 2026-10-21 — `patches/key-allowlist.patch` on CPA 8.0.38
> adds `access.key-allowlist` and confines the Antigravity credits fallback; an
> `apikey` rule matches only a config-synthesized credential; the instance
> module refuses plugins beside it, null entries, and rules that cannot narrow
> or match; CPA refuses two entries with one client key at every load, and a
> refused initial load exits 1; a hot reload can serve a rotated credential
> until its delete lands (documented, not fixed); a runtime routed through an
> instance gets its entry from `ai.<runtime>.proxy.allow` and one `base-urls`
> rule per enabled instance provider, naming the provider CPA's own
> normalization records.
>
> **Settled — do not relitigate.** Plugins fail open and split instances were
> rejected (operator, 2026-10-21): one CPA instance enforces the allowlist in
> its own credential selection. A plugin scheduler that fails, unloads or
> returns unhandled leaves native selection to run over the full pool
> (`internal/pluginhost/scheduler.go:11-30`,
> `sdk/cliproxy/auth/conductor_selection.go:1000-1005`); Home mode never calls
> it. The public plugins also fail on their own terms: key-account-bind reads
> keys from headers only, so `?key=` skips it; key-provider-access widens stale
> allowed IDs; cpa-key-policy falls back to global weighted selection.

## Settings

`settings.access.key-allowlist` binds one client key to the credentials its
requests may select:

```nix
access = {
  api-keys = [claudeKey codexKey];
  key-allowlist = [
    {
      api-key = claudeKey;
      credentials = [{provider = "claude"; kind = "oauth";}];
    }
    {
      api-key = codexKey;
      credentials = [{provider = "codex"; kind = "apikey";}];
    }
  ];
};
```

`api-key` is a secret like `access.api-keys[]`: the same redact reference
appears in both and is lifted into a placeholder. A runtime routed through the
instance (`ai.<runtime>.proxy.instance`) writes both for its own key, from
`ai.<runtime>.proxy.allow` and its enabled `providers`; write entries by hand
only for other clients. A rule needs `provider` and `kind`, typed
`enum ["apikey" "oauth"]`, so a provider alone never admits both an OAuth login
and an API key. `provider` is the credential's provider as CPA records it,
`openai-compatible-<name>` for an openai-compatibility group, its name
lowercased; `openai-compatibility` and a name already carrying the prefix stay
as they are (`OpenAICompatibleProviderKey`, `internal/util/provider.go`), and a
provider's generated rule follows the same rule. Optional `ids` narrows a rule
to credential IDs; an OAuth login's ID is its file path under the auth
directory. A config API key's ID hashes the key, so narrow API keys by provider
and `base-urls`. CPA reads an empty or absent list as unrestricted; how the
module refuses an empty, null-holding or `mkIf`-emptied one is under Refinements
in `cliproxyapi-settings.md`; a null entry in the list is refused by a module
assertion on the merged value. A hand-written `config.yaml` has no such guard.
There is no tag: CPA drops the v8 group `name`
(`internal/config/config_v8.go:389-410`). `kind` is matched against CPA's own
`AuthKind()` (`sdk/cliproxy/auth/classification.go:30-50`), except that only a
credential synthesized from config counts as `apikey`: the patch's
`allowlistKind` applies the test `IsConfigAPIKeyAuth` uses. Once the watcher has
read an auth file, it sets the attribute `auth_kind=oauth`
(`internal/watcher/synthesizer/file.go:169,252`, `helpers.go:86-88`), which wins
over the file's own `auth_kind` field (`classification.go:37,40`). Before that,
a login loaded from the auth store at startup classifies from its file: an
`auth_kind: apikey` field, or a Meta refresh adding an `api_key` attribute to a
file without the field (`internal/runtime/executor/meta_executor.go:158`), makes
it `apikey`. Such a credential has no kind for the allowlist and matches no rule
until the watcher replaces it. Its provider and ID still come from the file, so
a rule is only as trustworthy as the auth directory and whoever writes to it;
use `ids` for high-value OAuth rules.

`key-allowlist = []` switches the feature off. So does a list whose every entry
sits under a false `mkIf`, which merges to `[]`; the module does not refuse it.

### One entry per client key

CPA refuses a config in which two entries have the same `api-key` once trimmed,
the comparison selection itself uses. Merged, they would be one principal
holding the union of both entries' rules, so a second entry written to narrow a
key, or a secret rotated to match another key, would widen it instead. The error
names the entries by index and never the key:

```text
access.key-allowlist: entries 0, 1 have the same api-key after trimming; give each client key one entry, since entries sharing a key would merge their credential rules
```

Keys are redact references, so the module cannot compare their values at
evaluation; CPA checks them in `LoadConfigOptional` and `ParseConfigBytes` after
decoding, not inside it, where cloud-deploy's fallback to an empty config on a
parse error would swallow the refusal. What a refusal does, by path, in 8.0.38:

- Startup logs `failed to load config: ...` and exits 1 before it serves.
  Upstream's `main` returns there (`cmd/server/main.go:599-602`) and exits 0;
  the patch makes it `os.Exit(1)`, and the service manager's restart policy
  decides what follows. A rotated `redact.file` meets this too, since a changed
  secret restarts the unit rather than hot-reloading it.
- A hot reload logs `failed to reload config: ...` and returns before touching
  the running config (`internal/watcher/config_reload.go:99-103`). The previous
  config and its allowlist stay in force, and the refused file's hash is not
  recorded, so the next valid write applies.
- A management `PUT` of the config answers 422 `invalid_config` and writes
  nothing (`internal/api/handlers/management/config_basic.go:162-165`,
  `config_v8.go:180-183`); a Home push is refused and retried
  (`sdk/cliproxy/service_home.go:542-546,682-697`).
- A `Config` built in code skips loading, so the Manager compiles such entries
  to an allowlist that grants no key anything, and logs the same error.

Entries with an empty key bind no request and are not compared.

While the list has any entry, selection fails closed. A key with no entry, or an
unauthenticated request, selects nothing; an entry whose credentials are all
unavailable errors. The client gets 503 `auth_not_found`. Unset, nothing
changes: `omitempty` keeps it out of saved configs.

### Several providers on one protocol

`ai.cliproxyapi.instances.<n>.providers` writes these blocks and rules for you
(`dev/fragments/ai-proxy/ai-proxy.md`, Providers); the shape below is what it
generates, and what a hand-written block for another client needs.

Two `api-keys.claude` groups, say z.ai and a second Anthropic-format provider,
are one provider (`claude`) and one kind (`apikey`), and their IDs hash the
secret. Optional `base-urls` tells them apart: a rule with it matches only an
API-key credential whose base URL is listed.

```nix
# api-keys.claude has a group with base-url = "https://api.z.ai/api/anthropic"
credentials = [
  {
    provider = "claude";
    kind = "apikey";
    base-urls = ["https://api.z.ai/api/anthropic"];
  }
];
```

The comparison is the one CPA stores: the config synthesizer copies each block's
`base-url` into the credential's `base_url` attribute trimmed (Go's
`strings.TrimSpace`, every Unicode space) and otherwise unchanged
(`internal/watcher/synthesizer/config.go:107-109,169-171,253-255,321,367,424`;
the sanitizers in `internal/config/config_normalization.go` only trim too). So
the URL must match the block's `base-url` exactly: scheme, host, path, case and
a trailing slash all count. Nix cannot reproduce that trim; how the instance
module keeps it out of the comparison is under Providers in `ai-proxy.md`. Per
family:

- `claude`, `gemini`, `interactions`: `base_url` is set only when the block sets
  `base-url`. A block left on the default endpoint has none, and no `base-urls`
  rule matches it; set its `base-url` explicitly to address it.
- `codex`, `xai`: a block without `base-url` is dropped at load
  (`sanitizeCodexKeyEntries`), so every credential has one.
- `meta`: defaults to `https://api.meta.ai/v1` (`sanitizeMetaKeyEntries`).
- `openai-compatibility`: always set, but each group is already its own provider
  (`openai-compatible-<name>`), so `base-urls` is rarely needed.
- `vertex`: the attribute is always written; an empty one matches nothing.

A `base-urls` rule never matches an OAuth login, whatever its `kind`. Kimi and
xAI logins do carry a `base_url` attribute (`synthesizer/file.go:254-270`,
`runtime/executor/xai_executor_auth.go:72-74`), so this is a check of its own,
not an accident of missing data. Because such a rule can never match, the
instance module refuses `kind = "oauth"` with `base-urls`. It does not check
that a listed URL names a configured block: a rule for a block that is absent,
or spelled differently, is accepted and selects nothing.

An `openai-compatibility` group with no API key, such as a local Ollama-style
upstream, has no `auth_kind` attribute and no `api_key`, so its credentials have
no kind (`synthesizer/config.go:291-404`, `classification.go:30-50`). No rule
can admit them: while the allowlist is set, no client key reaches a key-less
group.

## The patch

CPA 8.0.38 authenticates a flat key set and keeps the matched key as the
principal, from a header or from `?key=` / `?auth_token=`
(`internal/access/config_access/provider.go:65-100`). The middleware stores it
with `usage.WithAPIKey` (`internal/api/server_middleware.go:212,274`).
`authSelectionEligibility.allows` (`conductor_selection.go:116`) filters these
candidate loops: legacy single and mixed, the scheduler fast path
(`scheduler.go:408,467`), retry and cooldown waits
(`conductor_selection.go:1419`). Plugin schedulers only pick among its
survivors. Two loops in 8.0.38 skip it; they are listed below.

The patch adds the config type, its v8 path, and one rule check in `allows`
keyed to `usage.APIKeyFromContext`. `authSelectionEligibilityForRequest` takes
the Manager's compiled allowlist as an argument, so a new call to that
constructor fails to compile until it is given the allowlist. That catches
nothing else: a candidate loop that never builds an eligibility skips the
allowlist and still compiles. Two such loops exist in 8.0.38:

- Home dispatch (`pickHomeDispatchSelection`, `conductor_home.go:951`) refuses
  while the allowlist is set. A start-time check cannot replace that guard: Home
  mode comes from `-home-jwt`, and Home pushes config at runtime through
  `ParseConfigBytes` (`sdk/cliproxy/service_home.go:542,682`).
- The Antigravity credits fallback (`findAllAntigravityCreditsCandidateAuths`,
  `conductor_home.go:1279`) applies the allowlist itself. It runs when
  `quota-exceeded.antigravity-credits` is on and selection failed, which is
  exactly what the allowlist does to a key with no Antigravity rule; unpatched,
  that key spent the Antigravity login.

Outside the allowlist: plugin executors
(`sdk/api/handlers/handlers_execution.go:56-58`) choose credentials without
`allows`, and the plugin host hands any plugin every auth file through
`host.auth.get` (`internal/pluginhost/auth_callbacks.go:70-95`), so enabling
plugins voids the allowlist. The instance module refuses `plugins.enabled` with
a non-empty `access.key-allowlist` at evaluation. Model listings still name
every model.

`src = applyPatches {...}` with `patchFlags = ["-p1" "--fuzz=0"]` makes the
build, `passthru.extracted` and the settings check read one patched tree. A bump
that changes a hunk's context fails the update's vendor-hash step; one that only
moves it applies at an offset.

## Checks

- `cliproxyapi-key-allowlist` runs the patch's Go tests, which the package build
  skips (`subPackages` is `cmd/server`); each test's comment names what it
  proves. `SelectAuth` always takes the legacy candidate loop, so assertions
  through it add no scheduler coverage. The check also joins
  `checks/key_allowlist_loops_test.go` to the auth package: a go/types scan that
  fails on a `range` over `Manager.auths` whose own body, closures judged apart,
  calls no allowlist predicate, unless the function is on its commented
  exemption list.
- The scan does not see an indexed lookup (`m.auths[id]`), an alias of the map,
  the map passed to a helper, a loop over a copy (`snapshotAuths`, `List`), or
  the scheduler's own pools and pickers, which match every entry on a nil
  predicate (`scheduler.go:1412,1647`). In 8.0.38 every scheduler pick entry
  point builds its predicate with `scheduledAuthPredicate`
  (`scheduler.go:426,487,494`). No check sees these shapes, so a CPA bump that
  touches candidate selection still needs a reviewer, green or not.
- `module-service-instances-key-allowlist` starts the packaged CPA from its Home
  Manager unit against stand-in API-key upstreams. It has no OAuth login, so
  only the Go test proves the OAuth exclusion.
- `module-service-instances-key-allowlist-duplicate` starts the packaged CPA
  with two `redact.file` keys that resolve to one, and a positive-control
  instance.
- `module-service-instances` holds the evaluation refusals and acceptances in
  one table, `settingsCases`.

## Known limitation: reload ordering

Settled: the operator chose to document this and not to fix it. It exists only
on the hot-reload path, which is a management API save or an edit of the runtime
config copy. A Nix change to the settings or to a secret restarts the unit, and
a restart registers credentials before the server listens
(`sdk/cliproxy/builder.go:270`, `service_lifecycle.go:91,136,177-178`), so there
is no window.

On a hot reload the file watcher loads the new config and calls the reload
callback before it re-synthesizes credentials
(`internal/watcher/config_reload.go:95-149`, `clients.go:195-200`). The callback
applies the config to the Manager, which publishes the compiled allowlist
(`sdk/cliproxy/service_config.go:194`, `applyManagerConfig`, then
`conductor_cooldown.go`). It does not re-synthesize config credentials, since
`synthesizeConfigAuths` is false on this path (`service_config.go:48-49`). The
watcher does that afterwards in `refreshAuthState` (`dispatcher.go:143-284`) and
queues the result: a Delete for each credential ID the new config no longer
yields, applied by a consumer goroutine (`service_auth.go:51-74,236`). From the
publish to that Delete the old credentials stay in the pool under the new rules.
The length of the window has not been measured.

A config credential's ID hashes its secret, base URL, proxy, prefix and headers
(`internal/watcher/synthesizer/config.go:151`, `helpers.go:29-49`), so rotating
a key or changing one of those gives the block a new ID and deletes the old
credential. A rule matches provider, kind, `ids` and `base-urls`, never the
secret. In the window a client key can therefore select a credential the old
config had and the new config removed or rotated, when the new rule grants its
provider (a provider-only rule) or its base URL (`base-urls`). Example: the old
config has `claude-api-key = [{base-url = A; api-key = sOld}]` and no claude
rule for key K; the new config rotates the block to `sNew` and gives K
`base-urls = [A]`. Until the Delete lands, K's requests go to A signed with
`sOld`.

- The secret is never shown to the client; CPA uses it server side. Spend and
  quota land on the retired credential's account, and a credential revoked
  upstream fails with an error.
- `ids` rules are safe: IDs hash the new secret, so a new rule's ID never equals
  a removed credential's ID.
- Only a rule the new config adds or widens opens this. A credential the old
  config already admitted gains nothing.
- Revoking or narrowing takes effect at once, because the allowlist is published
  first. Removing a client key from `api-keys` refuses it in the same reload.

Reordering is unsafe and was rejected: publishing the allowlist after the
credentials would delay narrowing, revocation and the first allowlist, which
fails open, and the watcher's credential replacement is asynchronous in any
case. A fail-closed gate that refuses config credentials absent from the new
config's ID set would close the window (about 50 non-test lines in the patch),
and was not taken. If a rotation that also widens a key matters, restart the
unit, or grant by `ids`.
