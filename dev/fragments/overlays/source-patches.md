## Source patches

Use `packageLib.patching {inherit pkgs;}` for source patches. Pass native
`patches` to `attrs` for stdenv or `source` for a patched tree. Pass
`patchFiles` to `command` for shell use. GNU patches require exact context and
create no backups; the Git caller may allow whitespace differences. Use
`substituteInPlace --replace-fail` for text that changes often. `patch-policy`
catches direct patch calls and flag overrides; `patch-artifacts` checks the
selected patched source trees for `.orig` and `.rej` files.
