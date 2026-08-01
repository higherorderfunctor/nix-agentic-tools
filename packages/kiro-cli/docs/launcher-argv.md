# kiro-cli wrapper: the argv contract

> **Last verified:** 2026-08-01 (commit pending — the `ai.kiro.tui` option is
> REMOVED, so nothing here injects `--tui` any more; `--tui` selects the new TUI
> harness for the OLD engine and v3 already uses it. Also corrects the chat
> binary's clap default, which is **v1** on 2.16.0 and not the `v2` this page
> asserted: measured via `kiro-cli-chat chat --tui` failing with
> `--tui cannot be used with --agent-engine=v1`. That also shows the old
> `tui`-implies-`v3` behavior was load-bearing rather than decorative — bare
> `--tui` never worked). Prior: 2026-07-31 against kiro-cli **2.16.0** (commit
> pending — qualifies the "grep the JS, not the ELF" rule, which was true for
> POLICY but false for feature GATING and nearly shipped a wrong answer: the
> rollout manifest lives in the ELF, the rust binary OVERWRITES
> `KIRO_ENABLED_FEATURES` before spawning bun, and the manifest's own "enable
> locally through KIRO_ENABLED_FEATURES" line is stale. Adds
> `ai.kiro.unlockedRolloutFeatures`. Prior: 2026-07-30 against **2.15.2** — adds
> the measured launcher FORWARDING TABLE: it injects `chat` on a bare launch,
> skips `--agent`'s value, strips `--`, rewrites `settings all` to
> `settings list`, and keeps `whoami` in-process. Corrects the `--v3` rewrite to
> its real TWO-TOKEN form `--agent-engine v3`; the `--agent-engine=v3` in the
> error text is clap's diagnostic formatting, not the argv. Prior: records that
> the launcher resolves `kiro-cli-chat` through PATH, so the two wrappers
> COMPOSE, and that `--trust-tools` therefore has to be withheld from `acp`
> under v3. Prior: first revision). If you touch `lib/idempotentFlags.nix`,
> `packages/kiro-cli/lib/wrapPackage.nix`, or bump the kiro-cli version and this
> fragment isn't updated in the same commit, stop and fix it.
>
> **How much to trust a line here.** The argv/parse claims are measured against
> 2.15.2 and re-measurable with the recipe at the end. Claims about the v3
> bundle and about this repo's Nix are sourced to the file they came from. An
> earlier revision opened with a blanket "every claim below is a MEASURED parse
> result", and that sentence is exactly what let four wrong claims ship
> unqualified — an audit refuted the `--tui` inertness mechanism, the "on
> `chat`, v3 accepts all five" claim, the `tui.js` `--trust-tools` auto-answer,
> and a probe-script reference to files that do not exist. Re-measure, don't
> reason, and prefer a probe that reaches the check you care about (see the
> input-must-be-supplied trap below).

## The one thing to know

`--tui` and `--v3` are **launcher-global** options. They are positional: a
global option must appear **before** the subcommand, because after it clap
parses against the _subcommand's_ parser.

```console
$ kiro-cli mcp list --tui --v3
error: unexpected argument '--tui' found

$ kiro-cli --tui --v3 mcp list
(works)
```

**That error does not mean `mcp` rejects `--tui`.** It means the flag was in the
wrong place. This is worth stating flatly because getting it wrong once already
cost a release: the wrapper used to _append_ these flags, which broke `acp`,
`mcp`, `agent`, `settings` and `translate`, and the failure reads exactly like
"this subcommand doesn't support the flag."

So the wrapper **prepends** them. Prepended, every subcommand accepts them.

## `--v3` reaches `acp` for free

The launcher translates its own global `--v3` into an `--agent-engine` option —
**for `acp` only.** Measured directly, by putting a `kiro-cli-chat` that prints
its argv first on `PATH`:

```console
$ kiro-cli --v3 acp        # kiro-cli-chat actually received:
acp --agent-engine v3

$ kiro-cli --v3 chat       # NOT translated — forwarded verbatim:
chat --v3

$ kiro-cli --v3 mcp list   # dropped entirely:
mcp list
```

`chat` needs no translation because the chat binary declares its own `--v3`;
`mcp`/`agent` do not take an engine at all. Do not generalize the `acp` row to
the others.

Note the **two-token** form. The error text below renders it
`--agent-engine=v3`, but that is how clap prints an option in a diagnostic, not
the argv that was passed — so a probe grepping forwarded argv for the `=`
spelling finds nothing and wrongly concludes the translation is gone.
`optionValueBlock` accepts both spellings for exactly this reason.

```console
$ kiro-cli --v3 acp --trust-tools=fs_read
error: the following arguments are not supported with --agent-engine=v3: --trust-tools
```

So `ai.kiro.v3 = true` gives an ACP session the v3 engine with **no
`--agent-engine` translation in this repo**. Do not add one.

**A caller's explicit `--agent-engine` wins, upstream.**
`kiro-cli --v3 acp --agent-engine=v2` runs v2 — no error, and no "cannot be used
multiple times". The wrapper therefore implements no precedence of its own.

## What is injected where

| Binary          | Flag             | Position    | Applies to                                   |
| --------------- | ---------------- | ----------- | -------------------------------------------- |
| `kiro-cli`      | `--v3`           | **prepend** | every subcommand + bare                      |
| `kiro-cli-chat` | `--trust-tools=` | **append**  | `chat` always; `acp` unless the engine is v3 |

The `acp` condition is resolved from **argv at runtime**, not from the Nix
config — see
[the composition section](#the-two-wrappers-compose--reason-about-the-chain-not-the-binaries).

Two different rules, for two different reasons — do not "make them consistent":

- **`--v3` is global and wanted everywhere**, since it selects the engine for
  `chat` and `acp` alike.
- **`--trust-tools` is genuinely per-subcommand.** The chat binary declares it
  on `chat` and `acp` and **not** at top level, so a bare
  `kiro-cli-chat --trust-tools=…` is an "unexpected argument". It is appended
  and gated.

## THE TWO WRAPPERS COMPOSE — reason about the chain, not the binaries

**`kiro-cli` resolves `kiro-cli-chat` through `PATH`, not from its own store
directory.** Proof: drop the wrapped bin dir from `PATH` and the launcher fails
with `No such file or directory (os error 2)` rather than falling back. So in
any real profile, `kiro-cli acp` runs **both** wrappers:

```
kiro-cli acp
  -> launcher wrapper  prepends --v3
  -> launcher rewrites --v3 to `--agent-engine v3`, finds kiro-cli-chat on PATH
  -> chat wrapper      appends --trust-tools
  => error: the following arguments are not supported with --agent-engine=v3: --trust-tools
```

That shipped, and it is why `--trust-tools` is withheld from `acp` when the
engine is v3.

**What the launcher forwards**, measured by putting a `kiro-cli-chat` that
prints its argv first on `PATH`. It does not merely relay argv — it injects,
rewrites and strips:

| Invocation                            | `kiro-cli-chat` receives |
| ------------------------------------- | ------------------------ |
| `kiro-cli`                            | `chat`                   |
| `kiro-cli --`                         | `chat`                   |
| `kiro-cli --agent acp`                | `chat --agent acp`       |
| `kiro-cli --tui`                      | `chat --tui`             |
| `kiro-cli --tui --v3`                 | `chat --tui --v3`        |
| `kiro-cli --tui chat`                 | `chat`                   |
| `kiro-cli --tui --v3 chat`            | `chat --v3`              |
| `kiro-cli acp`                        | `acp`                    |
| `kiro-cli --tui acp`                  | `acp`                    |
| `kiro-cli --v3 acp`                   | `acp --agent-engine v3`  |
| `kiro-cli --v3 acp --agent-engine=v2` | `acp --agent-engine=v2`  |
| `kiro-cli --v3 mcp list`              | `mcp list`               |
| `kiro-cli settings all`               | `settings list`          |
| `kiro-cli whoami`                     | _(kept in-process)_      |

Five consequences worth holding on to. A **bare launch is dispatched too**, with
`chat` injected — so the chat wrapper's `chat` gate fires on it. The
**subcommand leads**: the launcher re-emits it first and the surviving globals
after, so `--v3 chat` arrives as `chat --v3`. **`--agent`'s value is not a
subcommand**: `--agent acp` forwards as a bare launch, which is why both
`subcommandBlock` and the check's launcher stub skip a value-taking option's
value. **`--` is stripped**, so past the launcher it can never reach the chat
binary's own scan. And **`--v3` is translated only for `acp`** — forwarded
verbatim to `chat`/bare, dropped entirely for `mcp`/`agent`, and suppressed
outright when the caller supplied their own `--agent-engine`.

**Upstream's reason is NOT that v3 replaced the flag.** Under v3, `chat` still
honours it. `--trust-tools` is a **client-side** knob: kiro's own TUI
(`~/.local/share/kiro-cli/tui.js`) re-emits it onto the downstream ACP argv.

Do not over-read that. The TUI's auto-answer — selecting `allow_always` on an
`approval_request`, with an explicit branch for the v3 (`kas`) engine — is real
but is gated on **`--trust-all-tools`**, a different flag: `trustTools` occurs
exactly ONCE in `tui.js`, in the flag-spec table, and is never written to the
store or read by the approval handler. The auto-answer reads
`trustAllToolsConfirmed`.

On the `acp` arm kiro-cli **is** the agent and the external ACP client owns that
answer, so there is nothing agent-side for the flag to bind to — `acp-server.js`
contains no `trustedTools`/`trustAllTools` at all. The guard is deliberate, not
an unfinished port: the message is a hand-rolled literal in
`crates/chat-cli/src/cli/mod.rs` carrying its own flag list.

Little is lost for a **declarative** grant, with one caveat that matters by
backend. `trustedMcpTools` is also translated into `settings/permissions.yaml`
(`mkPermissionRules`), and the v3 agent does read that: `acp-server.js` declares
`POLICY_FILENAMES = ["permissions.yaml", "permissions.json"]` and layers
built-in → admin → `~/.kiro/settings/` → `~/.kiro/workspace-roots/<hash>/`,
compiling rules to Cedar. What the CLI flag cannot participate in is the
interactive half — under v3 an `ask` rule is resolved with the client over ACP
(`session/request_permission`).

**That recovery is home-manager-only.** `mkPermissionRules` has no devenv
equivalent, so on the devenv backend a withheld `--trust-tools` is not recovered
declaratively — the grant is simply absent for that session.

> **Probing v3 at all: for POLICY, grep the JS, not the ELF.** The v3 engine is
> NOT in the Nix-store binary. It is a separately downloaded Node bundle under
> `~/.local/share/kiro-cli/kas/<version>/node_modules/@kiro/agent/`, and the
> Rust binary only spawns it. A `strings` sweep over the 555 MB ELF finds
> nothing about policy and produces a confident WRONG answer — that is measured,
> not hypothetical. Read `acp-server.js` and `tui.js` first; where the ELF and
> the JS disagree on policy, the JS wins.
>
> **Do NOT generalize that to feature GATING — there the ELF wins, and reading
> only the JS produces exactly the confident wrong answer this note warns
> about.** Measured 2026-07-31 on 2.16.0. `tui.js` gates hidden features on
> `process.env.KIRO_ENABLED_FEATURES` (a JSON array of strings, parsed once into
> a Set), which reads like an env var you can simply set. It is not: the **rust
> chat binary recomputes and OVERWRITES that variable before spawning bun.** The
> parent process held `["workflows"]` and its bun child received `["tangent"]`.
> `KIRO_ROLLOUT_FORCE_INTERNAL=1`, `KIRO_ROLLOUT_FORCE_NIGHTLY=1` and
> `KIRO_INTERNAL=1` do not move it either — `segment: "internal"` resolves off
> the authenticated identity (`lite` is documented "Amazon employees only"), not
> off the environment.
>
> The real gate is a **JSON rollout manifest carried in the ELF's rodata**, in
> TWO identical copies, parsed at runtime — see `vu.mkKiroRolloutPatch` and
> `ai.kiro.unlockedRolloutFeatures`. Its feature names are extracted into
> `overlays/kiro-cli-extracted.json` under `rolloutFeatures`, so read that file
> rather than re-deriving the list by hand (the extractor found two entries a
> careful manual read had missed). Note the manifest's own `workflows`
> description says "enable locally through KIRO_ENABLED_FEATURES" — that line is
> STALE and does not describe shipped behavior. Believing it costs a measurement
> session.
>
> **Patching the binary is necessary but NOT sufficient: the resolved engine
> must be `kas` (v3).** In `tui.js` the feature-gated slash-commands reach the
> palette only via `kasCommands`, populated as `n === "kas" ? [...TQ()] : []`
> where `n` is the resolved agent engine. `TQ()` is itself the manifest-filtered
> list (`ltn(e) = e.filter(n => !n.feature || Lr.isEnabled(n.feature))`), so
> BOTH conditions gate it — the flag must be unlocked AND the engine must be v3.
> On the legacy engine the commands are filtered out wholesale.
>
> That is why `ai.kiro.unlockedRolloutFeatures` asserts `v3 = true`. Without the
> assertion the misconfiguration is silent in the worst way: the binary is
> genuinely patched, the option is genuinely set, and `/workflow` is simply
> never there. It cost a consumer repo a debugging session before the assertion
> existed.

**"Is the engine v3" is a RUNTIME question.** A caller's `--agent-engine`
overrides the injected `--v3`, so an eval-time `hasV3` gets it wrong in both
directions, and both are measured:

```console
$ kiro-cli --v3 acp --agent-engine=v2 --trust-tools=x     # runs — v2, so trust is valid
$ kiro-cli      acp --agent-engine=v3 --trust-tools=x     # CONFLICT — v3, even with v3 off in Nix
```

Gating on `hasV3` alone would silently drop trust in the first case and break
the command in the second. So the wrapper resolves the engine from argv — the
caller's `--agent-engine` if present (either spelling), otherwise **the chat
binary's own clap default** — and withholds only when that resolves to `v3`.

That default is **`v1`** on 2.16.0, not the `v2` this fragment claimed for a
long time. Measured: `kiro-cli-chat chat --tui` fails with
`--tui cannot be used with --agent-engine=v1`. Nothing turns on the difference
here — the withhold fires only on `v3`, and neither v1 nor v2 is v3 — but a
reader reasoning about engine defaults from this page would have been wrong.

The fallback is deliberately NOT what this Nix config bakes in. The chat wrapper
cannot know whether the launcher wrapper is in the chain, and
`kiro-cli-chat acp` invoked directly runs the **v2** engine however `v3 = true`
is set — so a v3 fallback silently stripped `--trust-tools` from a session that
would have accepted it. Nothing is lost on the normal path, because the launcher
rewrites argv: `kiro-cli --v3 acp` arrives here as an explicit
`acp --agent-engine v3`, so the withhold fires on the token, never on a guess.

**The lesson generalizes past this flag.** Each wrapper was individually correct
and the pair was not, so any new injection has to be reasoned about against what
the OTHER wrapper adds on the same code path. `checks/kiro-wrapper-argv.nix` now
covers this with a launcher stub that dispatches through `PATH`; testing the two
binaries in isolation cannot see it, which is exactly how this reached a
release.

## The v3 + `acp` conflict

`--agent-engine=v3` on `acp` is declared mutually exclusive with **every
functional option `acp` has** — `--agent`, `--model`, `--effort`,
`--trust-tools`, `-a/--trust-all-tools`. Only `-v` survives.

It is value-specific — `=v1`/`=v2` accept all five — but only PARTLY
`acp`-specific. Measured per option on 2.15.2, with input supplied so the
conflict check is actually reached:

| Option under `--agent-engine=v3` | on `acp` | on `chat`    |
| -------------------------------- | -------- | ------------ |
| `--agent`, `--model`, `--effort` | conflict | accepted     |
| `--trust-tools`                  | conflict | accepted     |
| `-a` / `--trust-all-tools`       | conflict | **conflict** |

So four of the five are a property of the v3 ACP arm, but `--trust-all-tools`
conflicts under v3 on **either** subcommand. This wrapper is unaffected — it
injects `--trust-tools`, never `--trust-all-tools` — but do not generalize the
`acp`-only shape to the whole conflict set.

Probe it with input supplied. `chat --agent-engine=v3 -a` on its own reports
"Input must be supplied when running in non-interactive"; that error fires
BEFORE the conflict check and hides it, which is an easy way to measure this
wrong.

**Consequence for a consumer:** with `ai.kiro.v3 = true`, an invocation like
`kiro-cli acp --model auto` fails with upstream's conflict error. That is
deliberate. The alternative — withholding `--v3` whenever a conflicting option
appears — would silently downgrade the engine the user asked for, and would
require this repo to carry a hand-curated conflict list that rots on every
upstream release.

Nothing is made unreachable: the caller opts out per-invocation with
`--agent-engine=v2`, which upstream honours over the injected `--v3`:

```console
$ kiro-cli acp --agent-engine=v2 --model auto     # runs
```

Note the error names `--agent-engine=v3`, a flag the user never typed. That is
confusing on first contact and worth repeating in user-facing docs.

## How the scan decides (`lib/idempotentFlags.nix`)

`subcommandBlock` walks argv left to right and stops at the first token that is
neither an option nor an option's **value**:

- **Value-taking options must be listed.** `--agent <AGENT>` and
  `--resume-id <SESSION_ID>` are the launcher's only ones (`kiro-cli-chat` has
  just `--resume-id` — no top-level `--agent`). Without the skip,
  `kiro-cli --agent acp` reads as the `acp` subcommand and a bare launch
  silently loses the injection. (With `--tui` gone the LAUNCHER no longer gates
  on the subcommand at all — `--v3` is unconditional — so this now matters only
  for the chat binary's `--trust-tools` gate.) The `--opt=value` form needs no
  entry: one token, handled by the `-*` arm.
- **`--` parks on a sentinel** no gate matches, so gated injection declines
  rather than guessing.

`idempotentFlagBlock` takes an explicit `position` with **no default** — picking
the wrong one is precisely the bug above. `--v3` aborts on repetition ("cannot
be used multiple times"), so it is injected only when absent as an **exact argv
token** — not a substring scan of `"$*"`, so `kiro-cli chat 'explain --v3'`
still gets the real flag.

`--trust-tools` is not idempotence-guarded: repeating it is _accepted_ by both
`chat` and `acp` (measured), unlike the boolean flags.

## Re-measuring on a version bump

Run against the **unwrapped** binary out of `nix build` — a bare `PATH` lookup
finds the wrapper, which is the thing under test.

Pinning `$KB` is necessary but **not sufficient for the launcher**: it
re-resolves `kiro-cli-chat` through `PATH` at runtime, so a wrapped
`kiro-cli-chat` earlier on `PATH` still lands in the chain. For anything about
`acp`/`chat` parsing, invoke `$K/bin/kiro-cli-chat` directly; to measure what
the launcher FORWARDS, put a `kiro-cli-chat` that prints its argv first on
`PATH` on purpose.

```bash
K=$(nix build --no-link --print-out-paths .#kiro-cli); KB="$K/bin/kiro-cli"

# 1. globals still parse BEFORE a subcommand, and still fail after it
"$KB" --tui --v3 whoami >/dev/null && echo "prepend ok"
"$KB" whoami --tui --v3 2>&1 | grep -q "unexpected argument" && echo "append still fails"

# 2. --v3 still means --agent-engine=v3 (error text names the translated flag)
"$KB" --v3 acp --trust-tools=x </dev/null 2>&1 | grep -q "agent-engine=v3" && echo "translation intact"

# 3. a caller's engine still wins over the injected --v3
"$KB" --v3 acp --agent-engine=v2 --model auto </dev/null 2>&1 | grep -q "not supported" \
  && echo "REGRESSION: escape hatch gone" || echo "escape hatch intact"
```

Read `--help-all` for the launcher's own options (that Options block is what
"global" means here) and each subcommand's `--help` for its own. Confirm with a
parse probe rather than trusting help text — use an argument that fails
validation LATE, so "unexpected argument" versus "invalid value" distinguishes a
parse rejection from an accepted flag.

## Tests

- `checks/kiro-wrapper-argv.nix` — the real wrapper against a stub package that
  prints its argv. Covers which SIDE of the subcommand each flag lands on, the
  that nothing emits `--tui`, the value-flag skip, `--`, idempotence, and the
  env-export path. String-matching the generated bash cannot catch a flag
  emitted on the wrong side; running it can.
- `checks/module-eval.nix` (`module-kiro-wrapper-*`) — pins the SHAPE of the
  generated bash, including that reverse emission order is what makes prepends
  compose to `--tui --v3`.

## Do not break the exec line

The wrapper ends with `exec -a "$0" <realBin> "$@"`. Keep that shape: recovering
the real binary by reading the line back out of the generated wrapper is how you
probe the unwrapped CLI at all (see the re-measure recipe above), and
`checks/kiro-wrapper-argv.nix` asserts on it.

An earlier revision credited "probe scripts under `docs/plans/`" with depending
on this. Nothing there does — `grep -rl 'exec -a' docs/plans` is empty — so the
check is the only thing pinning it.
