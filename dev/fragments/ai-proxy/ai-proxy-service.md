## ai.proxy services: the CLIProxyAPI instances Home Manager runs

> **Last verified:** 2026-10-14 — extracted settings and account fields use
> `lib/open-keys` for unknown-key warnings and per-instance suppressions on both
> backends; account freeform refusal uses shared credential policy and the
> owner's reconciled identity reasons. Services and account reconciliation
> retain their existing lifecycle.
>
> **Settled — do not relitigate.** Freeform `settings` with a
> `{ _secret = { file | helper }; }` marker, and a jq `. + $fields` merge of
> seven hand-typed account fields, were built and replaced on 2026-10-14: the
> marker could sit anywhere, typed or not, and the merge could not retract a
> field it had written. `git show 418f7fbe:dev/fragments/ai-proxy/ai-proxy.md`.

### Config-parity exception

`ai.proxy.instances` is declared on both backends. devenv rejects a non-empty
value with an assertion. This exception was approved by the operator on
2026-10-14: devenv has no user-service lifecycle, and it inherits the
user-global registry anyway. Linux only: there is no launchd writer in the repo,
so Darwin warns, emits no units, and still writes the registry.

### The rendered config

CLIProxyAPI v8 reads client keys only as plaintext (`access.api-keys`) and
rewrites its own config. The unit therefore renders a private copy into its
`StateDirectory` (`$XDG_STATE_HOME/ai-proxy/<name>`) on every start. It appends
the client key to any keys in `settings`, and defaults `oauth.auth-dir` there.
JSON is YAML, so `jq` writes it. The key reaches `jq` through its environment,
never argv.

- `settings` is `packages/cliproxyapi/lib/extracted.nix`'s `settingsType`: one
  `nullOr` option per extracted v8 path, default null, every object open to keys
  the extraction does not know. `render` drops nulls and empty typed objects, so
  CLIProxyAPI keeps its own defaults. Unknown keys warn with spelling
  suggestions; `allowUnrecognizedSettings` suppresses selected paths. Warnings
  inspect the rendered value at config level, behind `options ? warnings`, on
  both backends.
- The jq that completes the config at start (secrets, client key, auth dir) is
  `packages/cliproxyapi/lib/config.jq` (`configFilter`), shared with
  `cliproxyapi-config-validates` so the check loads what a service would.
- A path the hand layer marks `secret` takes `mkSecretType`: every credential,
  and every value that can carry one (each `proxy-url`, each upstream
  `headers.<name>`). `render` writes a `plain` value in place and returns each
  `file` or `helper` with its JSON path; the start script reads it with
  `mkSecretAssignment` and `setpath`s it from jq's environment, so the store
  keeps only the path. A missing or empty file, or a failing helper, stops the
  start. A file or helper path is held to the client key's pattern, because the
  assignment double-quotes it.
- The auth dir is resolved once and written into the config, so the account
  reconcile and the proxy read the same directory. Evaluation accepts only an
  absolute path, `~` or `~/…`, which resolve as CLIProxyAPI's `ResolveAuthDir`
  does; it reads `""` as its own default and a relative path against its working
  directory, where the reconcile (absolute roots only) cannot follow. An
  assertion rather than a shell mirror of `ResolveAuthDir`, so there is no
  second resolver to drift.
- `host` and `port` are lifted out of `settings` because the registry and the
  unique-port assertion read them at evaluation. They are written back into
  `settings.server`, so a value set in both places is a definition conflict.
- A blank or wildcard host binds every interface (CLIProxyAPI's default for
  `""`) and fails evaluation. Another single address, such as a sandbox bridge,
  is allowed.
- The example keys `your-api-key-{1,2,3}` put CLIProxyAPI in a safe mode that
  turns its API off, so they are rejected.
- The unit restarts on failure every 5s, at most 3 starts a minute
  (`StartLimitBurst`, `StartLimitIntervalSec`). systemd's default, 5 starts in
  10s, never trips at that spacing, so a start that always fails (a missing
  secret, an unparsable auth file) would loop instead of ending `failed`.

### Accounts

`accounts.<name>` writes per-login fields into CLIProxyAPI's OAuth auth files
before each exec; the typed options are the extracted auth-file fields minus
identity and tokens, and `accountType` is open (`freeformType`) to the keys CPA
reads off the extracted path (`request_retry`, `websockets`, `disable_cooling`,
`cloak_*`), written as given with unknown-key warnings. Instance
`allowUnrecognizedAccountFields` suppresses paths relative to the accounts map
(`*.request_retry`). `lib/open-keys.refuse` rejects an `ignored` field using its
reconciled reason (identity, `id_token`) and any credential-shaped name
(`access_token`, `api_key`), even if allowlisted, before merging the freeform
value, so no token reaches the store plan or the ledger. The file name is a
login's only stable address: `claude-<hash>-<email>.json`, the hash being the
first 8 hex digits of sha256(organization or account uuid)
(`internal/auth/claude/filename.go`), and `codex-<hash>-<email>-<plan>.json`,
hashing the ChatGPT account id (`internal/auth/codex/filename.go`,
`sdk/auth/codex_device.go` `buildAuthRecord`).

- `proxy_url` and each `headers` value take `mkSecretType`; `renderAccount`
  returns a `file` or `helper` one with its path inside the account's fields,
  and the jq that writes the run-time plan reads it from its variable and
  `setpath`s it into that target's `units.text`. The store plan and the script
  hold only the path; the plan with values is `$state/accounts-plan.json`,
  mode 0600.
- One `lib/own` json target per account, ledger `accounts/<name>.json` under
  `$state/own`. Only declared leaves are owned: a field set in the panel and
  never declared survives, a declared field edited in the panel is reset, a
  field no longer declared is removed, and the tokens are never touched. The
  file keeps its mode.
- The plan is built at evaluation (one target per declared account, plus a
  retirement target named `@AI_PROXY_ACCOUNT@`) and narrowed at run time by jq:
  declared accounts whose file exists, plus a retirement target for every ledger
  a past run left whose file exists. `mkCommand`'s `planFile` runs it. An absent
  file is skipped silently (operator decision, 2026-10-14); a past account's
  ledger whose file is gone is deleted.
- A token refresh keeps the fields: Claude saves the whole metadata map it
  loaded (`claude_executor_auth.go` `Refresh`, `sdk/auth/filestore.go` `Save`),
  Codex applies a credentials-only patch to the file on disk (`codex_persist.go`
  `PersistCodexAuthFile`). The reconcile is a compare-and-swap, so a write that
  lands mid-run is re-read rather than overwritten.

### Logins

Everything but the OAuth tokens is configurable from Nix; logins stay native.
`cliproxyapi --config <state>/config.yaml -claude-login`, `-codex-login` or
`-codex-device-login` saves into the config's `auth-dir` (`sdk/auth/manager.go`
`Login` sets the store's base dir from it). The browser flows listen for the
redirect on localhost:54545 (Claude) and localhost:1455 (Codex)
(`sdk/auth/claude.go`, `sdk/auth/codex.go` constructors); the device flow needs
no port. The running service picks a new login up without a restart: its watcher
starts watching the auth dir at start and loads a created or written `*.json`
incrementally (`internal/watcher/events.go` `start`, `handleEvent`). Its
declared `accounts` fields are written only at the next start, before exec; the
README says to restart the unit.

A shell-start warning for an instance with no login is a README snippet
(`programs.bash.initExtra` / `programs.zsh.initContent`), deliberately not a
module option (operator decision, 2026-10-14).

### Checks

`checks/ai-proxy/module-eval.nix`: units, start limit and registry, instance
validation (auth dirs `""`, relative and `~other` rejected), typed settings (a
wrong type or enum value fails, an unknown key passes, unset options are left
out), Darwin, devenv rejection, an executed start script against a stub proxy
(literal, file and helper secrets in the config, a header and a proxy URL among
them, and none of the file or helper values in the store, a missing file and a
failing helper stopping the start, a `~` auth dir), and the account reconcile
over two starts (fields written beside panel fields and tokens, an empty prefix,
an untyped `request_retry`, a proxy URL from a file with only its path in the
store, a secret-only account's header and proxy URL set and retracted, mode
kept, an absent file skipped, a removed field and a removed account retracted,
an orphan ledger dropped). `packages/cliproxyapi/checks/` validates rendered
configs with CLIProxyAPI's own `ValidateV8Config`, and loads an instance-shaped
one with `LoadConfig` after the start script's own filter.
