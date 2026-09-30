# Runtime values

> **Last verified:** 2026-09-30 — reduced the pilot to caller-backed scalar and
> map shapes.

`lib.runtimeValues` is the public library, and both module sets supply `rv`
through `_module.args`. `file { path; }` and `helper { path; }` return a
reserved `_runtime` envelope with one source and `secret = false`. Declarations
stamp secrecy onto that envelope during module evaluation.

`withReferences` supports exactly `lib.types.str` and `lib.types.bool`. It
creates a literal/reference union. Secret declarations reject every non-null
literal, and all declarations preserve a reference's existing secret flag.
Callers put `nullOr` outside the union.

`keyAwareMap` supports string values and nullable string values. It runs the
ordinary `attrsOf` merge first, then classifies each effective key. This keeps
`mkDefault`, `mkForce`, and a stronger null that removes an inherited entry
working. Glab uses the string form for `extraSettings`; Kimchi uses nullable
strings for `gitTokens`.

The classifier normalizes camel case, hyphens, and dots into lowercase segments.
A key is secret when hints mark it keyring-backed or secret, its container is
secret, or its final segment contains a credential word. The real credential
keys covered today are glab's `job_token`, `oauth2_refresh_token`,
`refresh_token`, and `token`, plus `apiKey`, `gitTokens`, and `CI_JOB_TOKEN`. No
exception or locator rule is carried without a current key.

`fromSchema` converts one flat field set into nullable options. `checkOptions`
audits evaluated declarations. It understands runtime unions, guarded maps,
`nullOr`, and declared submodules; every other type fails when its option path
is classified secret. The pilot roots are glab and Kimchi's `apiKey` and
`gitTokens`, plus the four migrated MCP credential schemas.

The reader accepts `<label> <file|helper> <path>`. It rejects missing,
directory, unreadable, empty, failed-helper, and NUL-bearing inputs. Helper
output is captured in a private temporary file, and diagnostics contain only the
label and a fixed message. Shell command substitution drops all trailing
newlines. Secret values are refused when a caller requests argv delivery.

> **Settled — do not relitigate.** Wrapping arbitrary nixpkgs option types
> (recursive lifting, declaration `typeMerge`, explicit runtime descriptors,
> enum/pattern/number validation, prefix/suffix decoration, newline policy) was
> built across review rounds 3–5 of #2042 and removed on 2026-09-30: no caller
> used any of it, and every round found a new literal leak in a shape nothing
> configured. A shape enters this library together with the caller that needs
> it, never ahead of one.
