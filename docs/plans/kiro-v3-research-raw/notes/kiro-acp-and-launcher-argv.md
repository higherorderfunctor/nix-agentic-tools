# Kiro CLI — launcher argv model, engine selection, and the ACP surface

> **Measured:** 2026-07-30 against **kiro-cli 2.15.2** (nixpkgs-overlay build,
> `nix build .#kiro-cli`). Every table below is a real command's real output —
> nothing here is inferred from documentation, because essentially none of it is
> documented upstream.
>
> **Scope:** the `kiro-cli` launcher's argv parsing, how `--v3` selects an
> engine, and how the `acp` (Agent Client Protocol) subcommand differs between
> the v2 and v3 engines. Written for the Kiro-documentation side project; the
> open questions are collected in [Gaps](#gaps-for-the-side-project).
>
> **Companion:** `fixtures/kiro-primitives/` (tracked) covers the v3 engine's
> subagent/hook/workflow primitives. This file covers the CLI entry point and
> ACP, which that corpus does not. Note that corpus's README states Mode-F
> runnable fixtures "cannot be automated" because the engine needs an
> interactive shell — **that is true of the TUI, not of ACP.** ACP is a headless
> stdio protocol and everything here was driven non-interactively from a script,
> so this surface *is* automatable. See [Replayable probe](#replayable-probe).

---

## 0. Pin the binary before re-running anything

Several kiro versions accumulate in the store and on `PATH`. Resolve through the
flake, not through `PATH` — a `PATH` lookup finds the *wrapped* launcher, which
is precisely the thing under test and will silently inject flags into your
probe.

```bash
K=$(nix build --no-link --print-out-paths .#kiro-cli)
KB="$K/bin/kiro-cli"       # real launcher, unwrapped
CB="$K/bin/kiro-cli-chat"  # the chat/acp binary the launcher dispatches to
"$KB" --version            # expect: kiro-cli 2.15.2
```

**Version discrepancy worth knowing:** the CLI reports `2.15.2`, but the ACP
handshake's `agentInfo.version` reports **`2.15.1`**. Both observed in the same
run of the same binary. Do not use `agentInfo.version` to identify a build.

---

## 1. The launcher argv model

`kiro-cli` is `clap`-based with the shape `kiro-cli [OPTIONS] [SUBCOMMAND]`.
`--tui`, `--classic`, `--v3`, `-r/--resume`, `--resume-id`, `--resume-picker`,
`--agent`, `-v/--verbose`, `--help-all` are **launcher-global options**. They
are positional-sensitive in the ordinary clap way: a global option must appear
**before** the subcommand token, because after it clap parses against the
*subcommand's* parser.

This produces an asymmetry that is easy to misread as "the subcommand rejects
the flag":

| invocation                        | result                                  |
| --------------------------------- | --------------------------------------- |
| `kiro-cli --tui --v3 mcp list`    | works                                   |
| `kiro-cli --tui --v3 agent list`  | works                                   |
| `kiro-cli --tui --v3 settings all`| works                                   |
| `kiro-cli --tui --v3 whoami`      | works                                   |
| `kiro-cli --tui --v3 chat …`      | works                                   |
| `kiro-cli --tui --v3 acp`         | works — **and selects the v3 engine**   |
| `kiro-cli mcp list --tui --v3`    | `error: unexpected argument '--tui' found` |
| `kiro-cli agent list --tui --v3`  | `error: unexpected argument '--tui' found` |
| `kiro-cli whoami --tui --v3`      | `error: unexpected argument '--tui' found` |

> **The single most load-bearing fact in this document.** The flags are never
> "unsupported by `acp`". They are global options in the wrong argv position. A
> wrapper that *appends* them breaks every subcommand; a wrapper that *prepends*
> them works everywhere. This repo's wrapper appended, which is what
> `kiro-cli acp` failing with `unexpected argument '--tui'` actually meant.

### Value-taking launcher options

Only two consume the next argv token: `--agent <AGENT>` and
`--resume-id <SESSION_ID>`. This matters for any argv scanner: without skipping
the value, `kiro-cli --agent acp` parses as "the `acp` subcommand" rather than
"a bare launch with agent `acp`".

The `kiro-cli-chat` binary has its own, *different* top-level option set —
`--tui`, `--legacy-ui/--classic`, `--v3`, `-r`, `--resume-id`,
`--resume-picker`, `-v` — with **no top-level `--agent`** and **no top-level
`--trust-tools`**.

### Repeatability

| option          | repeated twice                                        |
| --------------- | ----------------------------------------------------- |
| `--agent-engine`| `error: … cannot be used multiple times`               |
| `--tui`         | `error: … cannot be used multiple times`               |
| `--trust-tools` | **accepted** (no error, on both `chat` and `acp`)      |

So any injector must be idempotent for `--tui`/`--v3`/`--agent-engine`, and must
match on the **exact argv token** — a substring scan of `"$*"` would let a
prompt like `chat "explain --tui"` suppress the real flag.

---

## 2. Engine selection

`chat` and `acp` — and only those two — declare
`--agent-engine <ENGINE>` with `[possible values: v2, v1, v3]`, **default
`v2`**. `mcp`, `agent`, and `settings` do not declare it at all.

**The launcher translates its global `--v3` into `--agent-engine=v3` on the
dispatched subcommand.** This is not documented; it is provable from the
launcher's own error text, which names a flag the caller never typed:

```console
$ kiro-cli --v3 acp --trust-tools=fs_read
error: the following arguments are not supported with --agent-engine=v3: --trust-tools
```

### Precedence — a user's explicit engine wins, upstream, for free

| invocation                                  | outcome                       |
| ------------------------------------------- | ----------------------------- |
| `kiro-cli --v3 acp --agent-engine=v2`       | runs **v2** — no error        |
| `kiro-cli --v3 acp --agent-engine=v3`       | runs v3 — no "multiple times" |
| `kiro-cli --v3 chat --agent-engine=v2 …`    | runs v2                       |

A caller-supplied `--agent-engine` therefore overrides an injected global
`--v3`, and does **not** trip the duplicate-option error. Anything wrapping this
CLI gets user-override semantics without implementing them.

---

## 3. The v3 + `acp` conflict set

`--agent-engine=v3` on `acp` is declared mutually exclusive with **every
functional option `acp` has**:

| option on `acp`          | engine v1 | engine v2 | engine v3    |
| ------------------------ | --------- | --------- | ------------ |
| `--agent <AGENT>`        | accepted  | accepted  | **CONFLICT** |
| `--model <MODEL>`        | accepted  | accepted  | **CONFLICT** |
| `--effort <EFFORT>`      | accepted  | accepted  | **CONFLICT** |
| `-a`/`--trust-all-tools` | accepted  | accepted  | **CONFLICT** |
| `--trust-tools <NAMES>`  | accepted  | accepted  | **CONFLICT** |
| `-v`/`--verbose`         | accepted  | accepted  | accepted     |

Error shape:
`error: the following arguments are not supported with --agent-engine=v3: --model`

Two scoping facts that stop this from being read as "v3 is broken":

1. **It is value-specific.** `--agent-engine=v1` and `=v2` accept all five.
2. **It is `acp`-specific.** On `chat`, engine v3 accepts *all five*:
   `chat --agent-engine=v3 --model auto`, `--agent`, `--effort`,
   `--trust-tools`, `-a` all parse.

So the conflict is a property of the **v3 ACP arm**, not of v3.

### Escape hatch

Because a caller's `--agent-engine` wins (§2), the options remain reachable
under an injected `--v3`:

```console
$ kiro-cli --v3 acp --agent-engine=v2 --model auto        # runs, no error
$ kiro-cli --v3 acp --agent-engine=v2 --trust-tools=x     # runs, no error
$ kiro-cli --v3 acp --agent-engine=v1 --effort high       # runs, no error
$ kiro-cli --v3 acp --agent-engine=v3 --model auto        # CONFLICT (asked for the impossible pair)
```

Nothing is made unreachable by prepending `--v3`; a caller opts out
per-invocation.

---

## 4. ACP: what v2 and v3 actually expose

Driven with the [probe](#replayable-probe): `initialize`, then `session/new`.
No `session/prompt` is ever sent, so **no model is invoked and no credits are
consumed**.

### v3 is the *richer* agent, not a degraded one

| | **v2** | **v3** |
| --- | --- | --- |
| `sessionCapabilities` | `{}` | `list`, `fork` (`fork` carries `messageId`) |
| `promptCapabilities` | `image`, `audio:false`, `embeddedContext:false` | `image`, `embeddedContext:true` |
| `mcpCapabilities` | `http`, `sse:false` | `http`, `sse:true` |
| Kiro extension methods | none | `_kiro/knowledge`, `_kiro/codeIntelligence`, `_kiro/session/context`, `_kiro/session/compact`, `_kiro/session/export`, `_kiro/session/history`, `_kiro/config/template` |
| checkpoints / sessionList / policyNotifications | — | all `true` |
| `sessionSources` / `sessionListScopes` / `executionTargets` | — | `["local"]` / `["workspace"]` / `["local"]` |
| `replayMarking` | — | `true` |
| structured log channels | — | `kiro`, `mcp`, `powers` under `~/.kiro/logs/<UTC-stamp>/` |
| `authMethods` | `[]` | `aws-builder-id`, `aws-iam-identity-center` |
| auth model | self-contained | **host-mediated callback (below)** |
| `modes` semantics | **agents** | **workflows** |

### The v3 auth callback — a hard client contract

v3 opens by sending a **request to the client**:

```json
{"jsonrpc":"2.0","id":0,"method":"_kiro/auth/getAccessToken","params":{}}
```

and **stalls until answered**. On stderr it announces this:
`[INFO] Auth: --auth=acp-callback (host-mediated refresh via _kiro/auth/getAccessToken)`.

v2 never does this. **An ACP client written against v2 will hang against v3**
with no error — it looks like the agent never finished starting. This is the
single most likely v2→v3 integration failure and it presents as a hang, not a
crash.

A client must implement the reverse direction (agent→client requests) to use v3
at all. A placeholder token is enough to get through `session/new` and MCP
startup, which is how the rest of this section was measured.

### `modes` means different things per engine

- **v2** — `modes.availableModes` are **agents**: `kiro_default`,
  `kiro_planner`, `kiro_guide` …, with `currentModeId: "kiro_default"`.
- **v3** — `modes.availableModes` are **workflows**: `vibe` ("Default", general
  coding assistance), `spec` ("Spec", structured feature development),
  `quick-spec` …, with session `_meta.agentMode: "vibe"`.

A client that maps ACP "modes" onto Kiro agents is correct on v2 and **wrong on
v3**.

### v3 `session/new` result shape

```json
{"_meta": {"schemaVersion":"1.0.0","id":"sess_<uuid>","title":"New Session",
           "agentMode":"vibe","workspacePaths":["<cwd>"],
           "createdAt":"…","lastModifiedAt":"…",
           "semanticReviewEnabled":true,"ftaEnabled":false,
           "workflowsEnabled":false,"specPlanEnabled":false,
           "specWorkflow":"quick","specSkipClarificationEnabled":true,
           "source":"local"},
 "sessionId":"sess_<uuid>", "modes":{"availableModes":[…]}}
```

Note the session id is `sess_<uuid>` on v3 versus a bare uuid on v2 — consistent
with the two session-store layouts already recorded elsewhere.

v3 also pushes `_kiro/mcp/status` notifications per server as MCP comes up; v2
pushes `_kiro.dev/mcp/server_initialized` plus `_kiro.dev/commands/available`.
**Even the notification namespace differs: `_kiro/` on v3, `_kiro.dev/` on v2.**

### No model vocabulary on v3 ACP

Grepping the entire v3 handshake + `session/new` stream for model-ish keys
yields **zero** `model` occurrences — only `mode`, `modes`, `currentModeId`,
`availableModes`, `agentMode`. v2's stream is the same in this respect. So on
v3, per-session model selection is exposed neither on the CLI (§3) nor,
apparently, in the ACP surface.

### The settings route

`chat.defaultModel` exists as a global setting
(`kiro-cli settings all` → `chat.defaultModel = "claude-opus-5"`), and this
repo's factory already exposes it typed as `ai.kiro.settings.chat.defaultModel`.
That is the plausible answer to "how do I set the model under v3 ACP" — **but
see [Gaps](#gaps-for-the-side-project) G2: it is not verified that the v3 ACP
arm reads it.**

---

## 4b. Engine fingerprinting (useful diagnostic)

There is no CLI flag that reports which engine a session actually got, but
there is a reliable tell on **stderr at startup**:

| engine | first stderr line on `acp` |
| ------ | -------------------------- |
| v1, v2 | *(silent)* |
| v3     | `[INFO] Auth: --auth=acp-callback (host-mediated refresh via _kiro/auth/getAccessToken)` |

So `kiro-cli acp 2>&1 >/dev/null \| head -1` answers "did v3 apply?" without
authenticating or creating a session. A second, stronger confirmation is to
provoke the conflict deliberately — `kiro-cli acp --trust-tools=x` errors with
`not supported with --agent-engine=v3` **only** when v3 is in effect, which
doubles as proof that an injected global `--v3` reached the subcommand.

Both were used to verify this repo's wrapper end-to-end after the fix.

## 5. Stream discipline

For a stdio JSON-RPC protocol this is safety-critical, so it was measured rather
than assumed:

- All `[INFO]` chatter goes to **stderr**. `stdout` carries **only** JSON-RPC
  frames.
- `kiro-cli --v3 acp` and `kiro-cli --tui --v3 acp` produce **byte-identical
  stdout (0 bytes)** before any request is sent.

So `--tui` is **inert for `acp`** — it does not emit terminal chrome onto the
protocol stream. It remains semantically meaningless there (`--tui` is
documented as "Launch chat in TUI mode"), and "inert in 2.15.2" is not a
guarantee for future versions, so a wrapper is still better off not injecting it
outside a bare launch and `chat`.

---

## 6. Consequences for anything wrapping this CLI

1. **Prepend global flags; never append.** Appending breaks every subcommand.
2. **Prepending `--v3` gives `acp` the v3 engine for free** — no
   `--agent-engine` translation needed, because the launcher already does it.
3. **Do not implement user-override precedence** — upstream already has it, and
   a caller's `--agent-engine` cleanly wins over an injected `--v3`.
4. **Keep the injection idempotent on exact tokens** — `--tui` and `--v3` both
   abort on repetition.
5. **Skip `--agent`/`--resume-id` values** when scanning for a subcommand.
6. **Restrict `--tui` to bare + `chat`.** Inert elsewhere today; meaningless by
   definition.
7. **A user who needs `--model`/`--agent`/`--effort`/`--trust-tools`/`-a` on
   `acp` must pass `--agent-engine=v2`** — worth surfacing in user-facing docs,
   because upstream's error message names `--agent-engine=v3`, a flag the user
   never typed, which is genuinely baffling on first contact.

---

## Replayable probe

`initialize` + `session/new` only, so no prompt is sent and no credits burn.
Answers the v3 auth callback with a placeholder — enough to reach `session/new`.
Requires bash + python3.

> Two traps this script exists to encode: `kiro-cli`'s `bin/` entries are bash
> wrappers that `exec` the real binary, so `Popen.kill()` kills the wrapper and
> leaves the child holding the pipes — hence `start_new_session=True` plus
> `killpg`. And stderr must go to a **file**, not a pipe, or draining it after
> the kill blocks forever. The first version of this probe hung for five minutes
> on exactly that.

```python
#!/usr/bin/env python3
import json, os, signal, subprocess, sys, tempfile, threading, time

KIRO, ARGS = sys.argv[1], sys.argv[2:]
errf = tempfile.NamedTemporaryFile(mode="w+", suffix=".err", delete=False)
proc = subprocess.Popen([KIRO, "acp", *ARGS], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=errf, text=True,
                        bufsize=1, start_new_session=True)
frames = []

def send(o):
    proc.stdin.write(json.dumps(o) + "\n"); proc.stdin.flush()

def pump():
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        frames.append(line)
        try:
            o = json.loads(line)
        except Exception:
            continue
        # v3 requests a token FROM the client and blocks until answered.
        if o.get("method") and o.get("id") is not None:
            send({"jsonrpc": "2.0", "id": o["id"],
                  "result": {"accessToken": "PROBE-PLACEHOLDER",
                             "expiresAt": "2099-01-01T00:00:00Z"}})

threading.Thread(target=pump, daemon=True).start()
send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": 1, "clientCapabilities": {}}})
time.sleep(4)
send({"jsonrpc": "2.0", "id": 2, "method": "session/new",
      "params": {"cwd": os.getcwd(), "mcpServers": []}})
time.sleep(6)
os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
for f in frames:
    print(f[:3000])
errf.seek(0); print(errf.read()[:2000], file=sys.stderr); os.unlink(errf.name)
```

Run:

```bash
K=$(nix build --no-link --print-out-paths .#kiro-cli)
python3 probe.py "$K/bin/kiro-cli" --agent-engine=v2
python3 probe.py "$K/bin/kiro-cli" --agent-engine=v3
```

### Argv-contract probe (no auth, no session, seconds to run)

The facts the wrapper depends on can be re-checked without touching ACP:

```bash
K=$(nix build --no-link --print-out-paths .#kiro-cli); KB="$K/bin/kiro-cli"
# 1. globals still parse BEFORE a subcommand, and still fail after it
"$KB" --tui --v3 whoami   >/dev/null && echo "prepend ok"
"$KB" whoami --tui --v3   2>&1 | grep -q "unexpected argument" && echo "append still fails"
# 2. --v3 still means --agent-engine=v3 (error text names the translated flag)
"$KB" --v3 acp --trust-tools=x </dev/null 2>&1 | grep -q "agent-engine=v3" && echo "translation intact"
# 3. caller's engine still wins
"$KB" --v3 acp --agent-engine=v2 --model auto </dev/null 2>&1 | grep -q "not supported" \
  && echo "REGRESSION: escape hatch gone" || echo "escape hatch intact"
```

---

## Gaps for the side project

Numbered so they can be picked up individually. None are blockers for the
wrapper work; all are real unknowns.

- **G1 — Does v2 `acp` *honor* `--model`/`--agent`/`--effort` at all?**
  `--model BOGUS-XYZ` is accepted at parse time **and** `session/new` still
  succeeds with no error or warning. So "v2 accepts it" is not evidence it does
  anything. Needs a prompt-level test comparing the model actually used, which
  costs credits — deliberately not done here.
- **G2 — Does the v3 ACP arm read `chat.defaultModel`?** The setting exists and
  holds a model; nothing proves the v3 ACP arm consumes it. This is the
  load-bearing question behind "how do I set a model on v3 ACP", so it is the
  highest-value gap.
- **G3 — Is there *any* per-session model selection on v3 ACP?** No `model` key
  appears anywhere in the handshake or `session/new`. Candidates not yet
  probed: `_kiro/config/template`, `_kiro/session/context`, and whether
  `session/prompt` accepts a model override.
- **G4 — What do the v3-only extension methods do?**
  `_kiro/knowledge`, `_kiro/codeIntelligence`, `_kiro/session/{context,compact,export,history}`,
  `_kiro/config/template` are advertised and entirely undocumented. `codeIntelligence`
  is directly relevant to the codegraph evaluation.
- **G5 — Real-auth v3 ACP end-to-end.** Measured with a *placeholder* token.
  `session/new` succeeded and MCP servers connected, but no prompt was sent, so
  it is unproven that a real session completes.
- **G6 — `agentInfo.version` reports 2.15.1 from a 2.15.2 binary.** Stale
  constant, or a separately-versioned agent component? Affects anyone
  fingerprinting the agent over ACP.
- **G7 — `kiro-cli-chat --v3 acp --trust-tools=x` does NOT conflict**, unlike
  the launcher form. Either the chat binary's `--v3` does not reach acp's engine
  selection, or it reaches it differently. Means "which binary you invoke"
  changes engine semantics — worth pinning down before documenting either as
  canonical.
- **G8 — Why does the v3 arm forbid these options at all?** Deliberate (config
  moved into the protocol / settings) or simply unimplemented plumbing? Changes
  whether the wrapper should route around it or wait for upstream.
- **G9 — `workflowsEnabled:false`, `ftaEnabled:false`, `specPlanEnabled:false`**
  appear in v3 session `_meta`. What toggles them, and what is `fta`?
- **G10 — v3 log channels** (`kiro`, `mcp`, `powers` under
  `~/.kiro/logs/<stamp>/`) are structured and undocumented. "powers" is a
  primitive name not seen elsewhere in the corpus.
