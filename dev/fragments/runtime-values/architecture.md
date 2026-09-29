# Runtime values

> **Last verified:** 2026-09-28 — review round 2; type constraints, ancestor
> classification, and credential-name precedence are fail-closed contracts.

`lib.runtimeValues` is the public library. Both module sets supply `rv` through
`_module.args`. Constructors return a reserved `_runtime` envelope; ordinary
objects with `file` properties are not references. The source inside it is an
`attrTag`, so two modules cannot silently combine file and helper arms.

The classifier splits normalized name segments, including camel-case breaks.
Credential segments win over unrelated exceptions: `secret_tokens`,
`auth_tokens`, `client_secret_file`, and plural `tokens` are secret. Exact
`max_tokens` and `token_limit` name counts or limits. A locator suffix is exempt
only when its whole preceding stem is one credential name: `token_file`,
`token_path`, `token_env`, `token_var`, and `apiKeyHelper` are sensitive paths
or names; `client_secret_file` has an independent `secret` segment and stays
secret. This is a name heuristic; the declared option type still determines
whether the value is a path. Explicit secret hints and inherited
secret-container context always win. Secret leaves receive optional null from an
enclosing module option; non-null literals are rejected. Supported scalar leaves
keep their canonical checks and merge behavior plus references. Open maps
classify user keys during checking and merging. Effective secrecy can increase
through a declaration or `secret = true`; it cannot be downgraded by a
reference.

## Normalized schemas

`fromSchema { schema; prefix ? []; overrides ? {}; }` returns `{ options; }`. A
record has `fields`, an attribute set of child records or leaves. A leaf has
`type`, a Nix option type. Exactly one of `fields` or `type` is required.
`description`, `default`, classifier `hints`, and explicit `schema` descriptors
are optional. Leaves default to null and receive `nullOr`; records default to
`{}`. Example:

```nix
schema.fields = {
  host = { type = lib.types.str; };
  token = { type = lib.types.str; hints.keyring = true; };
};
```

`liftOptions` and `checkOptions` use one traversal. Classification context
passes through every path segment, including plain namespaces, submodules,
collection elements, and freeform types, even when auditing a nested root.
`fromSchema` builds record modules from supported scalar leaves. External
dynamic Nix types cannot be lifted safely and fail with their path and type;
this includes `nullOr`, `listOf`, `attrsOf`, submodules, and enums. The pilot
does not render structured documents or decode JSON. Collection references and
private rendering arrive in later PRs.

`withReferences` wraps the original option type and accepts only the exact
canonical `str`, `bool`, `int`, and `float` singleton types. Dynamic Nix types
contain functions whose identity cannot be proved by re-creating the type, so
the library rejects them even if they currently have no custom check. A custom
`addCheck`, merge method, or hand-built type using a familiar constructor name
fails with the option path and type. Explicit runtime schema descriptors must
equal the derived scalar schema and cannot override a predicate.

`checkOptions` inspects evaluated declarations, never configured values. Its
production roots deliberately cover only glab and migrated credential leaves.
Every rollout adds its own roots. Open maps need the guarded map type because
future user keys cannot be enumerated by a declaration scan. Positive and
negative controls live in `checks/runtime-values`. The audit also checks that a
guarded map's own classification context covers the enclosing declaration.

## Runtime delivery

The walker identifies only reserved envelopes. The materializer generates
assignments and environment exports and rejects secret-tainted argv delivery.
The same reader binary serves ordinary wrappers and glab's stdin keyring flow.
It has full Bash strict mode, captures helpers privately, rejects failed
helpers, NUL and invalid UTF-8, and emits only a successful value on stdout.
Diagnostics contain the option label and a fixed failure, never the value or
helper output.

The default removes exactly one terminal LF. `newline = "preserve"` retains all
newlines; decoration follows reading and the nonempty check. The assignment
protocol appends a sentinel before command substitution, removes that sentinel
in the parent, and retains the reader exit status. Removing the sentinel
protocol would silently trim every terminal newline. Only `decode = "string"` is
accepted. Prefix and suffix require a string schema; both the option type and
the reader reject decoration for bool, number, and enum references.

Legacy HTTP MCP `secretValue` and GitLab MCP `apiUrl` remain deferred surfaces.
The GitLab `apiUrl` credential metadata adapts its locator at that boundary;
shared MCP credential readers reject old shapes without that metadata. The
shared runtime library accepts only the canonical envelope. Kiro's separate HTTP
secret pipeline is deferred too.
