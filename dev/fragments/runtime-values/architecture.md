# Runtime values

> **Last verified:** 2026-09-30 — documented open string map auditing.

`lib.runtimeValues` is the public library, and both module sets supply `rv`
through `_module.args`. `file { path; }` and `helper { path; }` return a
reserved `_runtime` envelope with one source and `secret = false`. Declarations
stamp secrecy onto that envelope during module evaluation. One validator checks
references at type check, `recognize`, and materialization. `_runtime` needs a
bool `secret` and one string `file` or `helper`; malformed envelopes fail with a
fixed message.

`withReferences` supports only `lib.types.str` and `lib.types.bool`. Non-secret
declarations use a literal/reference union. Secret declarations accept anything
at type-check time, but their merge admits only valid references; otherwise, an
error names the option path, never the value. Identical references merge;
different ones conflict, and their paths may be printed because paths are not
secrets. Declarations preserve secret flags. Callers put `nullOr` outside.

`keyAwareMap` supports strings and nullable strings. Entries classify keys in
their merge before the ordinary string merge and type-check non-secret keys
there. This preserves `mkDefault`, `mkForce`, and stronger null removal. Glab
uses strings for `extraSettings`; Kimchi uses nullable strings for `gitTokens`.

The classifier normalizes camel case and underscores. A key is secret when its
`keyring` hint is set, its container is secret, or a segment carries a
credential word. A name ending in `env`, `var` is a locator rather than a
payload, as in `bearerTokenEnvVar`, unless its `keyring` hint or container marks
it secret. Current keys are glab's `job_token`, `oauth2_refresh_token`,
`refresh_token`, and `token`, plus `apiKey`, `gitTokens`, and `CI_JOB_TOKEN`.
Rules require current keys.

`fromSchema` converts one flat field set into nullable options. `checkOptions`
audits evaluated declarations. It understands runtime unions, guarded maps,
`nullOr`, and declared submodules. An `attrsOf str` after `nullOr` is always a
violation because user-chosen keys require `runtimeValueMap`; every other
`attrsOf` is descended. Every other type fails when its option path is
classified secret. The pilot roots are glab, the shared and four runtime
environment maps, the shared MCP server pool, Kimchi's `apiKey` and `gitTokens`,
and the four migrated MCP credential schemas.

The reader accepts `<label> <file|helper> <path>`. It rejects missing,
directory, unreadable, empty, failed-helper, and NUL-bearing inputs. Helper
output is captured in a private temporary file, and diagnostics contain only the
label and a fixed message. The reader drops trailing newlines before its empty
check. Secret values are refused when a caller requests argv delivery.

> **Settled — do not relitigate.** Wrapping arbitrary nixpkgs option types
> (recursive lifting, declaration `typeMerge`, explicit runtime descriptors,
> enum/pattern/number validation, prefix/suffix decoration, newline policy) was
> built across review rounds 3–5 of #2042 and removed on 2026-09-30: no caller
> used any of it, and every round found a new literal leak in a shape nothing
> configured. A shape enters this library together with the caller that needs
> it, never ahead of one.
