# Architecture

> **Last verified:** 2026-11-07 — router to the architecture decisions held by
> their owners; each decision keeps its rule, reason, mechanism pointer and
> vetted date beside the code it governs.

HITL-vetted decisions about how this repository is built live in the owner
documents below, so they load whenever their files are edited. Each entry is a
rule, its reason, and where the mechanism lives. Before adding a mechanism,
check this list and read the owner document. A mechanism that is not listed
means: find the existing one with git grep, and if none fits, propose the change
to the owner document before building. Never add ad hoc machinery beside an
existing abstraction.

- `dev/fragments/ai-inference/ai-inference.md` — inference selection is runtime
  library code.
- `dev/fragments/ai-module/runtime-support.md` — runtime support is declared in
  `surfaceSupport` (proposed).
- `dev/fragments/ai-proxy/ai-proxy.md` — the shared network proxy surface and
  its proposed instance selection.
- `dev/fragments/extracted/extraction-method.md` — packages pin the current
  upstream release only; extraction methods rank CodeQL, eval, AST, regex.
- `dev/fragments/extracted/typed-settings.md` — typed settings come from the
  extracted generator.
- `packages/ai-module/docs/architecture.md` — files, activation, secret
  readiness, services, instances and claims.
- `packages/airlock/docs/airlock.md` — Airlock rebuilt as a stack of small PRs.
- `packages/cliproxyapi/docs/cliproxyapi-client-keys.md` — proposed CPA named
  routing.
- `packages/jail-nix/docs/jail-nix.md` — proposed harness sandboxing.
- `packages/microvm/docs/sandbox.md` — the VM sandbox factory and VM git access.
