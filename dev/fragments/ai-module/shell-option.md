## `ai.shell` — the one override-wins surface

> **Last verified:** 2026-08-10 (commit pending — first landing of `ai.shell`.
> If you add another nullable-scalar `ai.*` option, change which runtimes
> consume this one, or touch `resolveOverride`, update this fragment in the same
> commit.)

### It is deliberately NOT collision-as-failure

Every attrset-shaped `ai.*` pool treats a shared/per-CLI duplicate key as an
error — see `collision-semantics.md`. `ai.shell` is the **one exception**, and
the exception is structural rather than a preference: a pool key names an
independent entry, so silently overriding one loses data. A nullable scalar has
nothing to lose. `ai.claude.shell` is not a second entry competing with
`ai.shell`; it is the same knob at a narrower scope, and making the pair collide
would leave no way to express "this default, except here" — the entire point of
the option.

Resolution lives in `lib/ai/ai-common.nix:resolveOverride` (non-null per-CLI
wins, `null` inherits the root, `null` at both levels means "not configured").
Do not inline the `if` at call sites; the contrast with the merge helper beside
it is the thing worth keeping easy to grep for.

### Opt-in, because two of five runtimes cannot honor it

`mkBackendTransform.nix` declares `ai.<name>.shell` **only** when the app record
sets `supportsShell = true`, and computes `resolvedShell` for the backend
callbacks. Apps that do not opt in get no option at all, so setting one is an
"option does not exist" eval error rather than a value that evaluates cleanly
and is dropped. This is the repo's standing rule that a surface without a
lossless native mapping is an explicit exclusion, not a silent no-op.

`supportsShell` is read off the RECORD, which keeps it a build-time parameter in
the same category as `backend` — it forces neither `config` nor the factory's
`pkgs`, so it cannot reintroduce the `_module.args` recursion documented against
`proxyIsSupported`.

| runtime | knob                       | delivery                                               |
| ------- | -------------------------- | ------------------------------------------------------ |
| Claude  | `CLAUDE_CODE_SHELL`        | `settings.env` → `settings.json`                       |
| Codex   | `SHELL` (own process env)  | launcher wrapper `--set`                               |
| Kiro    | `SHELL` (own process env)  | `environmentVariables` → wrapper export / devenv `env` |
| Copilot | **unknown — verified gap** | excluded                                               |
| Kimchi  | unassessed                 | excluded                                               |

Four runtimes were asked for; five go through `mkAiApp`. Kimchi is easy to miss
because the issue that requested this never mentioned it.

### The fallback behavior is asymmetric, and that is the whole safety argument

Every runtime here falls back when the configured shell is unusable, but they do
not fall back to the same place — and neither one warns in a way a consumer will
see:

- **Claude silently ignores an unusable `CLAUDE_CODE_SHELL`.** No warning,
  exit 0. Measured twice on 2.1.222 with a nonexistent path. It does **not**
  fall back to `$SHELL` — an explicit `SHELL=/usr/bin/zsh` was ignored and it
  resolved its own bash. So a bad value degrades to a working bash: the hazard
  does not return, but the OPTION silently does nothing.
- **Codex falls back to the PASSWORD-DATABASE shell.** From its own strings
  (`portable_pty::cmdbuilder`):
  `$SHELL -> … which is not executable …, falling back to password db lookup`.
  That is the opposite risk — on a machine whose passwd shell is the one being
  migrated away from, a bad value silently restores it.
- **Kiro uses `process.env.SHELL || "/bin/sh"`.** `||` is an unset-or-empty
  fallback, so an invalid path should fail loudly at spawn instead. Derived from
  the operator semantics, not yet measured.

**This is why the option takes a package, not a path.** A package is guaranteed
to exist in the store at activation and is GC-rooted by the generation that
references it, so the entire "path is wrong, moved, or collected" class is
eliminated by construction rather than by a runtime check that two of these
three runtimes demonstrably do not perform.

### Traps

- **`pkgs.bash` IS `pkgs.bashInteractive`** in this repo's pinned nixpkgs — same
  derivation, identical `drvPath`, `pname = "bash-interactive"`. Choosing
  between them is not a decision. The real distinct package is
  **`pkgs.bashNonInteractive`**. Any test asserting "the override changed the
  value" must use that one, or it passes vacuously against two names for one
  store path.
- **`--set`, never `--set-default`.** This repo reserves `--set-default` for
  polite defaults a user may override (`TERM`, `GH_TELEMETRY`). A configured
  shell must beat the ambient environment. For Codex this matters more than it
  looks, because "unset" is not neutral — it lands on the passwd shell.
- **Codex had no wrapper before this option.**
  `packages/chatgpt-codex/lib/wrapPackage.nix` is new; a Codex with no shell set
  still gets the bare upstream path, because the wrapper is skipped entirely
  when its env set is empty.
- **Do not feed `mergedEnvironmentVariables` to the Codex wrapper.** Codex has
  no `environmentVariables` option, so that value is the ROOT
  `ai.environmentVariables` pool alone — a pool whose contract is "Kiro and
  Copilot only". Passing it would silently start fanning that pool out to Codex,
  which is a different change than this one.
- **`shell_environment_policy` is not the Codex knob.** It filters what SPAWNED
  commands inherit; writing the shell there configures the children, not Codex.
- **`KIRO_CHAT_SHELL` is a dead end.** It exists only in Kiro's Rust binary, is
  absent from the v3 JS bundle, and the wrapper forces `--v3`.

### Why Copilot is a gap rather than a TODO someone can just close

Copilot ships as a **Node SEA** whose application code is a compressed blob, so
plaintext scanning of the 177 MB executable cannot answer the question. A scan
returns a couple of `SHELL` hits, but a **positive control fails** —
`githubcopilot`, `tool_use` and `gpt-` all return zero — which proves the app
code is not searchable and makes any negative result meaningless rather than
informative. The only readable hits are vendored Node internals
(`normalizeSpawnArguments`, `os.userInfo`), and Node's `shell: true` hardcodes
`/bin/sh` regardless of `$SHELL`.

Run a positive control before trusting ANY negative result against these
single-executable CLIs. Codex, by contrast, is a Rust binary whose string table
IS readable (`codex` = 1030 hits), which is why its mechanism could be settled
the same way.

To close the gap, read the universal npm tarball (`github-copilot-<ver>.tgz`)
that upstream nixpkgs switched to; it ships readable JS. Do not re-run a
plaintext scan of the SEA.

### Verifying a change here

```bash
# the option surface, both backends
nix build .#checks.x86_64-linux.options-doc-ai-parity

# semantics: precedence, inertness, exclusions, wrapper contents
nix build .#checks.x86_64-linux.module-ai-shell-per-runtime-overrides-root
nix build .#checks.x86_64-linux.module-ai-shell-codex-hm-wrapper-carries-shell
```

`module-ai-shell-accepted-for-claude` is the **positive control** for the two
exclusion tests. Those assert an eval failure, which a broken harness satisfies
for free; the control runs the identical `tryEval` shape against a supported
runtime and requires success. Delete them as a set or not at all.
