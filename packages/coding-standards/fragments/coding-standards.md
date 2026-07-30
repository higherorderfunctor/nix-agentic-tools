## Coding Standards

### Bash

All shell scripts must use full strict mode:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
```

`-E` (errtrace), `-T` (functrace) and `inherit_errexit` are the point: they
propagate failures out of the subshells, functions and command substitutions
that the abbreviated `set -euo pipefail` silently swallows. Never use the
abbreviated form.

**No linter checks this for you.** shellcheck has no strict-mode diagnostic — a
script carrying `set -euo pipefail`, or no `set` line at all, passes it clean.
The header is a review obligation, not a gate.

Where it applies depends on whether the shell owns its own process or is spliced
into someone else's:

| Site                                       | Rule                                                                                                                |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `home.activation` bodies                   | SCOPE IT — wrap the body in a subshell; entries concatenate, so a bare header persists into home-manager's own code |
| `shellHook` / devenv `enterShell`          | DO NOT ADD — `eval`'d into the calling shell; `set -e` arms the user's interactive session                          |
| stdenv phases, `runCommand` bodies         | DO NOT ADD — `setup.sh` already sets all four, and phases share one shell                                           |
| devenv `tasks.<name>.exec`                 | REQUIRED — rendered as a standalone script                                                                          |
| shell EMITTED by a heredoc                 | REQUIRED inside the emitted script                                                                                  |
| standalone `*.sh`, CI `run:` blocks        | REQUIRED                                                                                                            |
| `writeShellApplication`                    | SPLIT — see below; `bashOptions` alone never suffices                                                               |
| `writeShellScript` / `writeShellScriptBin` | REQUIRED — nixpkgs never lints these                                                                                |
| heredocs carrying JSON, config or prose    | does not apply — not shell                                                                                          |
| pre-commit / git-hook `entry` strings      | cannot be expressed — an argv, not a script; move the logic into a `writeShellApplication`                          |

`writeShellApplication` needs the header **split across two places**, because
`bashOptions` renders `set -o <name>` lines only and `inherit_errexit` is a
`shopt`:

```nix
pkgs.writeShellApplication {
  bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
  text = ''
    shopt -s inherit_errexit 2>/dev/null || :
    …
  '';
}
```

Put the `set -o` flags in `bashOptions` rather than all five in `text`:
writeShellApplication emits them ABOVE its own generated
`export PATH="…:$PATH"`, so `nounset` covers that line. Without it, a PATH-less
invocation yields a trailing-colon PATH — which bash reads as the current
directory — instead of failing loudly.

`home.activation` needs the header **scoped**, because home-manager concatenates
every DAG entry into one script it opens with `set -eu` + `set -o pipefail`.
Flags an entry sets stay set for every later entry, home-manager's own included:

```nix
home.activation.thing = lib.hm.dag.entryAfter ["linkGeneration"] ''
  (
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  …
  )
'';
```

Only wrap bodies with no parent-shell effects (no `export`, no `cd`, no `trap`).
Failure still propagates — the subshell exits non-zero and the caller's `set -e`
sees it. End a failing body with `false`, never `exit`, which would truncate the
whole concatenated script.

Two blind spots to catch by eye in review: shellcheck does not lint heredoc
BODIES under either `<<EOF` or `<<'EOF'`, and nixpkgs runs shellcheck on
`writeShellApplication` only — `writeShellScript` gets a syntax parse and no
lint at all.

### Ordering

Keep entries sorted alphabetically within categorical groups. Use section
headers for readability, sort entries within each group. This applies to lists,
attribute sets, JSON objects, markdown tables, TOML sections, and similar
collections.

### DRY Principle

Never duplicate logic, configuration, or patterns. When the same thing appears
twice, extract it. Three similar lines is better than a premature abstraction,
but three similar blocks means it is time to extract.
