# kiro-cli wrapper: the argv contract

> **Last verified:** 2026-07-30 against kiro-cli **2.15.2** (commit pending —
> adds the measured launcher FORWARDING TABLE: it injects `chat` on a bare
> launch, skips `--agent`'s value, strips `--`, rewrites `settings all` to
> `settings list`, and keeps `whoami` in-process. Corrects the `--v3` rewrite to
> its real TWO-TOKEN form `--agent-engine v3`; the `--agent-engine=v3` in the
> error text is clap's diagnostic formatting, not the argv. Prior: records that
> the launcher resolves `kiro-cli-chat` through PATH, so the two wrappers
> COMPOSE, and that `--trust-tools` therefore has to be withheld from `acp`
> under v3. Prior: first revision). If you touch `lib/idempotentFlags.nix`,
> `packages/kiro-cli/lib/wrapPackage.nix`, or bump the kiro-cli version and this
> fragment isn't updated in the same commit, stop and fix it. Every claim below
> is a MEASURED parse result, not a reading of the docs — re-measure, don't
> reason.

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

The launcher translates its own global `--v3` into an `--agent-engine` option on
the dispatched subcommand. Measured directly, by putting a `kiro-cli-chat` that
prints its argv first on `PATH`:

```console
$ kiro-cli --v3 acp        # kiro-cli-chat actually received:
acp --agent-engine v3
```

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
| `kiro-cli`      | `--tui`          | **prepend** | bare launch and `chat` only                  |
| `kiro-cli-chat` | `--trust-tools=` | **append**  | `chat` always; `acp` unless the engine is v3 |

The `acp` condition is resolved from **argv at runtime**, not from the Nix
config — see
[the composition section](#the-two-wrappers-compose--reason-about-the-chain-not-the-binaries).

Three different rules, for three different reasons — do not "make them
consistent":

- **`--v3` is global and wanted everywhere**, since it selects the engine for
  `chat` and `acp` alike.
- **`--tui` is global but only meaningful for chat.** It is _inert_ elsewhere on
  2.15.2 — `kiro-cli --v3 acp` and `kiro-cli --tui --v3 acp` emit byte-identical
  stdout (0 bytes), and all `[INFO]` chatter goes to **stderr**, so it cannot
  corrupt `acp`'s JSON-RPC framing. But it means "launch chat in TUI mode",
  which is meaningless for a stdio protocol or for `mcp`/`settings`, and
  inert-today is not a guarantee.
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

| Invocation              | `kiro-cli-chat` receives |
| ----------------------- | ------------------------ |
| `kiro-cli`              | `chat`                   |
| `kiro-cli --agent acp`  | `chat --agent acp`       |
| `kiro-cli --tui`        | `chat --tui`             |
| `kiro-cli --`           | `chat`                   |
| `kiro-cli acp`          | `acp`                    |
| `kiro-cli --v3 acp`     | `acp --agent-engine v3`  |
| `kiro-cli settings all` | `settings list`          |
| `kiro-cli whoami`       | _(kept in-process)_      |

Three consequences worth holding on to. A **bare launch is dispatched too**,
with `chat` injected — so the chat wrapper's `chat` gate fires on it.
**`--agent`'s value is not a subcommand**: `--agent acp` forwards as a bare
launch, which is why both `subcommandBlock` and the check's launcher stub skip a
value-taking option's value. And **`--` is stripped**, so past the launcher it
can never reach the chat binary's own scan.

**Upstream's reason is NOT that v3 replaced the flag.** Under v3, `chat` still
honours it. `--trust-tools` is a **client-side auto-answer knob**: kiro's own
TUI (`~/.local/share/kiro-cli/tui.js`) maps it to store keys and auto-selects
`allow_always` on an `approval_request`, with an explicit branch for the v3
(`kas`) engine. On the `acp` arm kiro-cli **is** the agent and the external ACP
client owns that answer, so there is nothing agent-side for the flag to bind to
— `acp-server.js` contains no `trustedTools`/`trustAllTools` at all. The guard
is deliberate, not an unfinished port: the message is a hand-rolled literal in
`crates/chat-cli/src/cli/mod.rs` carrying its own flag list, and clap's own
wording for a conflict is the different `cannot be used with`.

Nothing is lost for a **declarative** grant. `trustedMcpTools` is also
translated into `settings/permissions.yaml` (`mkPermissionRules`), and the v3
agent does read that: `acp-server.js` declares
`POLICY_FILENAMES = ["permissions.yaml", "permissions.json"]` and layers
built-in → admin → `~/.kiro/settings/` → `~/.kiro/workspace-roots/<hash>/`,
compiling rules to Cedar. What the CLI flag cannot participate in is the
interactive half — under v3 an `ask` rule is resolved with the client over ACP
(`session/request_permission`).

> **Probing v3 at all: grep the JS, not the ELF.** The v3 engine is NOT in the
> Nix-store binary. It is a separately downloaded Node bundle under
> `~/.local/share/kiro-cli/kas/<version>/node_modules/@kiro/agent/`, and the
> Rust binary only spawns it. A `strings` sweep over the 555 MB ELF finds
> nothing about policy and produces a confident WRONG answer — that is measured,
> not hypothetical. Read `acp-server.js` and `tui.js` first; where the ELF and
> the JS disagree, the JS wins.

**"Is the engine v3" is a RUNTIME question.** A caller's `--agent-engine`
overrides the injected `--v3`, so an eval-time `hasV3` gets it wrong in both
directions, and both are measured:

```console
$ kiro-cli --v3 acp --agent-engine=v2 --trust-tools=x     # runs — v2, so trust is valid
$ kiro-cli      acp --agent-engine=v3 --trust-tools=x     # CONFLICT — v3, even with v3 off in Nix
```

Gating on `hasV3` alone would silently drop trust in the first case and break
the command in the second. So the wrapper resolves the engine from argv — the
caller's `--agent-engine` if present (either spelling), otherwise the value this
wrapper bakes in — and withholds only when that resolves to `v3`.

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

It is value-specific (`=v1`/`=v2` accept all five) and `acp`-specific (on
`chat`, engine v3 accepts all five). So it is a property of the v3 ACP arm, not
of v3.

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
  silently loses `--tui`. The `--opt=value` form needs no entry: one token,
  handled by the `-*` arm.
- **`--` parks on a sentinel** no gate matches, so gated injection declines
  rather than guessing.

`idempotentFlagBlock` takes an explicit `position` with **no default** — picking
the wrong one is precisely the bug above. Both `--tui` and `--v3` abort on
repetition ("cannot be used multiple times"), so each is injected only when
absent as an **exact argv token** — not a substring scan of `"$*"`, so
`kiro-cli chat 'explain --tui'` still gets the real flag.

`--trust-tools` is not idempotence-guarded: repeating it is _accepted_ by both
`chat` and `acp` (measured), unlike the boolean flags.

## Re-measuring on a version bump

Run against the **unwrapped** binary out of `nix build` — a `PATH` lookup finds
the wrapper, which is the thing under test.

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
  `--tui` confinement, the value-flag skip, `--`, idempotence, and the
  env-export path. String-matching the generated bash cannot catch a flag
  emitted on the wrong side; running it can.
- `checks/module-eval.nix` (`module-kiro-wrapper-*`) — pins the SHAPE of the
  generated bash, including that reverse emission order is what makes prepends
  compose to `--tui --v3`.

## Do not break the exec line

The wrapper ends with `exec -a "$0" <realBin> "$@"`. Probe scripts under
`docs/plans/` recover the real binary by reading that line back out of the
generated wrapper, so keep its shape; `checks/kiro-wrapper-argv.nix` asserts on
it.
