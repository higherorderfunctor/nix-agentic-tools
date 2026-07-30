## Linting

`nix flake check` is the CI gate. The prek pre-commit hooks are a fast local
subset: they are `lib.optionalAttrs (!isCI)` in `devenv.nix`, so they do NOT run
in CI and are not part of `nix flake check`. They can also be skipped with
`--no-verify`.

Formatters and linters are separate here — treefmt runs formatters only and
lints nothing.

**Formatters — treefmt, all write in place:**

- **JS/TS/JSX/JSON/CSS:** biome
- **Markdown/YAML and friends:** prettier (`proseWrap = "always"`)
- **Nix:** alejandra
- **Shell:** shfmt (`*.sh`, `*.bash` — extension globs only, so it never sees an
  extensionless script, shell embedded in a `.nix` string, or a heredoc body)
- **TOML:** taplo

**Linters — prek hooks, not treefmt, not `nix flake check`:**

- **Nix:** deadnix (dead code), statix (anti-patterns)
- **Shell:** `shellcheck -x`, on files prek tags `shell` — which needs a `.sh` /
  `.bash` extension OR the executable bit. Shell embedded in `.nix` strings is
  linted by nothing except `writeShellApplication`'s own build-time checkPhase.
- **Spelling:** cspell

**Commit gates — prek hooks that block the commit:**

- convco (commit message shape)
- gitleaks (staged secrets)
- reject-default-branch-commit
- treefmt `--fail-on-change`, plus treefmt-restage to re-add reformatted files

**Available in the devShell, wired to no gate:** agnix (agent config linting) —
run it by hand or via the agnix MCP server.

There is no shellharden in this repo, and no linter reads shell embedded in
`.nix` strings beyond `writeShellApplication`'s own checkPhase. See the Bash
coding standard for which sites that leaves unchecked.
