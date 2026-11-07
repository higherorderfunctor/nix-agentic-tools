## Check fixtures

> **Last verified:** 2026-11-06 — launchers prepend their own arguments, so a
> stub runtime binary must not switch on `$1`.

A check that runs a generated launcher against a stub runtime binary sees the
launcher's arguments before the user's. The Kiro wrapper prepends `--v3` to
every invocation (`packages/kiro-cli/checks/kiro-wrapper-argv.nix` asserts
`--v3|chat|hello` for `chat hello`), and the Codex launcher adds its own
preflight and flags. A stub that picks its behavior with `case "$1"` therefore
sees the wrong word first and takes the wrong branch for Codex and Kiro.

Select the stub's behavior with an environment variable instead, and let the
check set it before the launch. Stubs that need no behavior switch simply ignore
argv, as the Codex fake in
`packages/chatgpt-codex/checks/chatgpt-codex-project-doc-preflight.nix` and the
Kiro stub in `checks/ai-warnings/runtime.nix` do. A stub that must observe the
argv prints it, one `ARG=` line per token, as `kiro-wrapper-argv.nix` does.
