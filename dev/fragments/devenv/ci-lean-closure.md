# CI-lean closure taxonomy

> **Last verified:** 2026-08-03 (commit pending — updates the consumer-export
> taxonomy after dev tools move beneath `pkgs.ai.devTools`; shell membership is
> unchanged). Prior: 2026-08-02 (commit pending — the repo's beta Codex
> permission profile explicitly grants the user-global Semble cache because beta
> profiles do not compose with the legacy user sandbox table). Prior: 2026-08-02
> (commit pending — the repo-aware Codex wrapper now distinguishes runtime
> commands from administrative commands before injecting the worktree root and
> named profile; an argv-probe build lets enterTest verify runtime injection
> (including `apply` and `exec-server`) and doctor pass-through exactly). Prior:
> 2026-08-02 (PR #698 — introduced the wrapper and verified PATH precedence plus
> explicit-flag idempotence). Prior: 2026-07-22 (PR #439). If you change what
> `devenv.nix` puts in the shell, which factories install CLI wrappers, or the
> `devenv-test.yml` cache wiring, re-verify this and bump the marker.

The `devenv-test` CI gate (`.github/workflows/devenv-test.yml`) runs
`devenv test` on ephemeral runners, so **everything in the shell closure is
download cost on every cold run** and feeds the `cache-nix-action` cache size.
`devenv.nix` therefore evaluates an `isCI` branch (see the comment block at its
`isCI` binding — EVAL-time, distinct from the RUNTIME `$CI` guard in
`processes.docs.exec`).

## The four buckets

| Bucket                   | Examples                                                                  | CI closure?                                                                                                                                            | Where decided                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| Gate dependencies        | generation pipeline, coreutils-class tools, `check-jsonschema`, `cspell`… | YES — unconditional `packages`                                                                                                                         | the gate runs materialize tasks + enterTest; these feed them                                                          |
| Interactive-only dev UX  | LSPs (`nixd`→llvm, `marksman`→dotnet, `taplo`), git-hooks suite           | NO — `lib.optionals (!isCI)` / `lib.optionalAttrs (!isCI)`                                                                                             | humans use them; CI never invokes them                                                                                |
| Factory CLI wrappers     | kiro-cli-wrapped (~693 MB), copilot-cli (~219 MB)                         | YES (currently) — ride in via `mkKiro`/`mkCopilot` whenever `ai.*` modules are enabled, and enterTest needs the modules enabled for their files fanout | gating the PACKAGE needs a factory-level option (HM-parity implications) — open decision, deliberately not improvised |
| Consumer overlay exports | `pkgs.ai.devTools.*`, MCP server packages                                 | NEVER in the shell                                                                                                                                     | they are shipped artifacts: built by the CI `build` matrix (`.#packages`) and `cache-hit-parity`, not shell members   |

## The decision rule

Adding a package to `devenv.nix`? Ask: **does the CI gate (materialize tasks +
enterTest assertions) invoke it?** If not, it goes in the `!isCI` list. When in
doubt, `CI=1 devenv test` locally is the oracle — green means the gate never
needed it.

This repository additionally supplies `codexForRepository` through the shared
`ai.codex.package` override. It is a small shell wrapper around the same base
Codex package, not a second CLI closure. The wrapper injects the evaluated
`config.devenv.root` and `nix-agentic-tools` profile only when the caller did
not provide `--cd`/`-C` or `--profile`/`-p`, and only for Codex runtime command
families that accept those flags. Administrative commands such as `doctor`,
`login`, and `features` pass through unchanged. enterTest covers explicit-flag
idempotence, exact `apply`, `resume`, and `exec-server` default injection, exact
`doctor` pass-through, and the real `doctor --json` rejection that originally
exposed the bug.

The selected `nix-agentic-tools` permission profile is also the effective
filesystem policy. Codex beta permission profiles do not compose with the legacy
`sandbox_workspace_write` table from user config, so the profile grants the
effective `$XDG_CACHE_HOME/semble` path (falling back to `$HOME/.cache`) in its
own filesystem table. This admits the user-global Semble index without
duplicating Semble's MCP, instructions, or agent in project scope. A stricter
profile may deliberately omit that grant.

Two proofs to preserve when touching the gates: with `CI` unset the shell must
rebuild to the **identical store path** (local behavior unchanged — compare
`devenv shell` store paths pre/post), and `CI=1 devenv test` must stay green.
