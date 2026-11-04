# Sandbox Git identities

> **Last verified:** 2026-11-01 — URL selection by the standalone selector. It
> reads a table of identities; identity options and relay lowering come later.

The standalone `sandbox-select <table.json>` reads the current checkout's raw
Git config. Push-remote precedence is `branch.<name>.pushRemote`,
`remote.pushDefault`, `branch.<name>.remote`, then the sole configured remote or
`origin`. A detached HEAD skips branch-specific settings.
`remote.<name>.pushurl` takes precedence over `url`; multiple selected URLs
refuse selection and list the URLs. `insteadOf` and SSH configuration never
rewrite the token.

Accepted URL forms are `ssh://[user@]host[:port]/path`, `[user@]host:path`,
`https://host[:port]/path`, and `git://host/path`. Selection uses only the
token; local/file URLs and unmatched tokens refuse with the runtime's
identity/token list. SSH URL users and explicit SSH ports override forge
defaults; HTTPS ports do not become SSH ports. Repository paths are preserved,
including existing `.git` suffixes and the distinction between home-relative SCP
paths and absolute SSH URL paths. Nothing appends `.git`.

Success is JSON `{credential, upstream, token, identity}`; no repository or no
push remote emits JSON `null` and exits zero, meaning no doors. The pure table
builder records each token's identity, `<runtime>-<identity>` credential, real
forge and endpoint defaults. Keys never enter that table. The refusal also notes
that runtime assignments replace the inherited identity set when the runtime
assigns its own.
