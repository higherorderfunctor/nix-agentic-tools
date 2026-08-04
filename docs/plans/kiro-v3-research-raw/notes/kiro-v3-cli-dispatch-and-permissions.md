# Kiro CLI v3 — process dispatch, argv rewriting, and the permission model

> **Measured:** 2026-07-30 against **kiro-cli 2.15.2** (Nix-overlay build) and
> the matching KAS 2.15.2 bundle. The argv and guard tables in §1 and §3 are real
> command output, re-run and re-confirmed. §2 is read out of `acp-server.js` and
> is only as good as that reading. Where a claim rests on reading source rather
> than observing behaviour, it says so.
>
> **This header used to assert that every table was a real measurement.** An
> adversarial audit refuted four claims that were not: §2's "a cloned repo cannot
> inject permission rules", `.kiroignore`'s effect, the capability list, and the
> `--trust-tools` mechanism. All four are corrected below. Assume the same is
> possible of anything you have not re-derived with §6.
>
> **Scope:** the two mechanics no other doc in this directory covers — how the
> `kiro-cli` process actually **dispatches** (what it resolves, what it rewrites,
> what it spawns), and how v3 **permissions** work end to end. Written for the
> Kiro reverse-engineering project.
>
> **Siblings, not duplicated here:**
>
> | File                             | Covers                                        |
> | -------------------------------- | --------------------------------------------- |
> | `kiro-acp-and-launcher-argv.md`  | the argv contract + v2-vs-v3 ACP surface diff |
> | `kiro-acp-v3-deep-dive.md`       | ACP method reference, capability tables       |
> | `kiro-v3-docs.md`                | captured vendor documentation                 |
> | `fixtures/kiro-primitives/`      | v3 engine primitives (subagents, hooks)       |

---

## !! OPEN — NOT FIXED, READ BEFORE CONVERGING PLANS !!

**Status 2026-07-30.** Everything below was found while finishing PR #617
(`fix(kiro-cli): withhold --trust-tools from acp when v3 is active`) and was
deliberately NOT fixed there. Each is measured, not suspected. Nothing here
blocks that PR; all of it is real work someone still has to do.

### O1 — `--trust-tools` is appended past a caller's `--`, breaking valid input

**Severity: high. Pre-existing, not introduced by #617.** The chat wrapper
appends `--trust-tools=<csv>` at the very END of argv. When the caller used a
`--` separator, the injected flag lands on the far side of it and clap rejects
the whole command. Measured against real 2.15.2:

```console
$ kiro-cli-chat chat -- hello                         # rc=0
$ kiro-cli-chat chat -- hello --trust-tools=fs_read   # rc=2
error: unexpected argument '--trust-tools=fs_read' found
```

So any consumer with a non-empty `trustedMcpTools` cannot pass a prompt after
`--`. The fix is to insert the flag BEFORE the first `--` rather than appending,
falling back to append when there is no `--`. It needs its own test matrix
(`--` absent, `--` with and without following tokens, `--` as an option value)
and is a behaviour change in its own right, which is why it did not ride along
with #617.

### O2 — the devenv backend cannot recover a withheld grant

**Severity: medium. Product gap, not a bug.** #617 withholds `--trust-tools`
from `acp` under v3 on the grounds that `trustedMcpTools` is ALSO expressed as
`settings/permissions.yaml` via `mkPermissionRules`. That translation is
**home-manager-only** — there is no devenv equivalent. On the devenv backend the
withheld grant is simply absent for that session. This violates the repo's own
Config Parity rule ("if a feature can be configured in HM it must also be
configurable in devenv; gaps between methods are bugs").

### O3 — the pinned CLI does not pin the engine that runs the session

**Severity: high for reproducibility.** The Nix derivation pins `kiro-cli`, but
under v3 the agent is a Node bundle downloaded at RUNTIME into
`~/.local/share/kiro-cli/kas/<version>/`. Seven versions were found cached side
by side (2.12.3 through 2.15.2). Two machines on the identical flake lock can
therefore run different agents. No mitigation exists today.

### O4 — under v3, tui.js may not forward `--trust-tools` at all

**Severity: unknown — needs a live probe.** On the kas path `lS(e,n,t)` returns
`new CD(kasOptions)` and discards the relay argv, so the `--trust-tools` the TUI
parsed appears never to reach the engine. The real consumer of the flag under v3
was NOT located. If it turns out there is none, the flag is inert under v3 on
`chat` too, and this doc's framing of it as a client-side knob needs revisiting
again. Probe with a live v3 `chat` session and an MCP tool that would otherwise
prompt.

### O5 — the launcher stub in `checks/kiro-wrapper-argv.nix` is deliberately partial

**Severity: low.** It models dispatch, `chat` injection, the value-flag skip,
`--` stripping, and the `--v3` translation. It does NOT model
`settings all -> settings list`, nor `whoami` being kept in-process. No
assertion turns on either today; adding a test that does will need the stub
extended first.

### O6 — one assertion pins an argv the real binary already rejects

**Severity: low, needs a decision.** `expect "-- ends the engine scan"` asserts
`acp -- --agent-engine=v3 --trust-tools=fs_read,@srv`. The real binary returns
rc=2 on that. It is arguably fine — the INPUT (`acp -- --agent-engine=v3`) is
already invalid before the wrapper touches it, so the wrapper is only declining
to make it worse — but the assertion reads as though it were a valid shape.
Either re-word it or assert on the rejection.

### O7 — unverified claim left standing in the shipping fragment

**Severity: low.** `packages/kiro-cli/docs/launcher-argv.md` credits
`checks/module-eval.nix` with pinning "that reverse emission order is what makes
prepends compose to `--tui --v3`". An audit flagged the attribution as wrong
(module-eval pins `idempotentFlagBlock`'s reverse-list behaviour; the shipping
order comes from `wrapPackage.nix`'s block concatenation). It was NOT
re-measured and NOT corrected.

---

## 0. The finding that reframes everything: v3 is not in the binary

**The v3 engine is a separately downloaded Node bundle, outside the Nix store,
unpinned.**

```
~/.local/share/kiro-cli/kas/<version>-<hash>/node_modules/@kiro/agent/dist/server/acp-server.js
```

The Rust binary only **spawns** it. Confirmed three ways: `ps --forest` shows a
child `node …/acp-server.js`; the chat binary carries the literal
`Using KAS agent engine, node: , server: , server resolved from @kiro/agent package`;
and seven versions (2.12.3 → 2.15.2) were found cached side by side in that
directory.

Three consequences, in descending order of how much they will cost you:

1. **Reproducibility hole.** For a Nix-packaged kiro, the derivation pins the
   Rust CLI and **not** the thing that actually runs your session. Two machines
   on the same store path can run different v3 engines. Nothing in the flake
   expresses this.
2. **Probing method.** `strings` over the 555 MB ELF is the **wrong instrument
   for anything v3** and will produce confident wrong answers. This is measured,
   not hypothetical: an investigation that grepped only the ELFs concluded
   "nothing reads `permissions.yaml`" — a firm REFUTED — while the JS bundle
   declares the filename outright. **Grep `acp-server.js` and `tui.js` first;
   where ELF and JS disagree, the JS wins.**
3. **The bundle is readable.** It is bundled but **not minified**, and retains
   `// src/policy/…` path markers, so it reads almost like source. This is the
   single most productive artifact in the whole system.

> KAS = the "Kiro Agent Server". The vendor docs' claim of *"a single engine for
> all Kiro surfaces"* (IDE, CLI, Web) is literally this Node bundle.

---

## 1. Process dispatch

### `kiro-cli` finds `kiro-cli-chat` on `PATH`, not beside itself

Not by absolute store path, not relative to `argv[0]`. **`PATH`.** Proof — drop
the directory from `PATH` and the launcher cannot find its own sibling:

```console
$ PATH=/usr/bin:/bin  /nix/store/…-kiro-cli-wrapped/bin/kiro-cli acp
error: No such file or directory (os error 2)
```

This matters enormously for anyone wrapping kiro: **a wrapper on `kiro-cli-chat`
is in the path of `kiro-cli <anything>`.** Two independently-correct wrappers can
therefore compose into a broken argv. That is not theoretical — it shipped in
this repo and produced a hard failure (§3).

### What the launcher forwards — argv IS rewritten

Measured by putting an argv-printing stub at `kiro-cli-chat` and the **real**
`kiro-cli` at the launcher:

| you type                      | `kiro-cli-chat` actually receives               |
| ----------------------------- | ----------------------------------------------- |
| _(nothing)_                   | `[chat]` — **`chat` INJECTED**                  |
| `--`                          | `[chat]`                                        |
| `--agent acp`                 | `[chat] [--agent] [acp]` — a bare launch        |
| `--tui`                       | `[chat] [--tui]` — bare: forwarded              |
| `--tui --v3`                  | `[chat] [--tui] [--v3]`                         |
| `--tui chat`                  | `[chat]` — explicit sub: `--tui` dropped        |
| `--tui acp`                   | `[acp]`                                         |
| `acp`                         | `[acp]`                                         |
| `acp --agent-engine=v3`       | `[acp] [--agent-engine=v3]`                     |
| `acp -- --agent-engine=v3`    | `[acp] [--agent-engine=v3]` — **`--` stripped** |
| `chat -- hello`               | `[chat] [hello]` — **`--` stripped**            |
| `--v3 acp`                    | `[acp] [--agent-engine] [v3]`                   |
| `--v3 chat`                   | `[chat] [--v3]` — verbatim, NOT translated      |
| `--v3 acp --agent-engine=v2`  | `[acp] [--agent-engine=v2]` — injected dropped  |
| `--v3 mcp list`               | `[mcp] [list]` — `--v3` dropped entirely        |
| `--v3 acp -- --trust-tools=x` | `[acp] [--trust-tools=x] [--agent-engine] [v3]` |
| `settings all`                | `[settings] [list]` — **`all` rewritten**       |
| `whoami`                      | _(never dispatched — kept in-process)_          |

Note the launcher **leads with the subcommand** and re-emits the surviving
globals after it, so `--v3 chat` comes out as `chat --v3`, not `--v3 chat`.

Four rules fall out:

1. **On `acp`, the global `--v3` is translated to `--agent-engine` on the
   subcommand.** Undocumented. Also provable without a stub, from the launcher's
   own error text naming a flag you never typed:
   `kiro-cli --v3 acp --trust-tools=x` → `… not supported with --agent-engine=v3: --trust-tools`.
   **The translation is `acp`-specific**, which this doc did not originally say.
   On `chat` the launcher forwards `--v3` verbatim
   (`--v3 chat` → `[chat] [--v3]`) because `chat` declares its own `--v3` flag;
   `acp` does not.
2. **The translation uses the TWO-TOKEN form** (`[--agent-engine] [v3]`), never
   `--agent-engine=v3`. Any argv scanner must handle both spellings.
3. **The translated engine is APPENDED**, after the caller's own arguments.
4. **`--` is consumed by the launcher and never forwarded.** So through
   `kiro-cli`, a `--` terminator does not shield anything — the following tokens
   reach the chat parser as ordinary options.

### The two paths disagree about `--`

| path                        | `--` behaviour | tokens after it            |
| --------------------------- | -------------- | -------------------------- |
| via `kiro-cli` (launcher)   | **stripped**   | parsed as **options**      |
| direct `kiro-cli-chat`      | **honoured**   | positionals → error        |

Direct invocation, measured:

```console
$ kiro-cli-chat acp -- --agent-engine=v3
error: unexpected argument '--agent-engine=v3' found
```

(`acp` declares no positionals, so anything after `--` is fatal there.)

### Engine fingerprinting without authenticating

There is no flag that reports the engine in use, but v3 announces itself on
**stderr** at startup:

| engine | first stderr line on `acp`                                     |
| ------ | -------------------------------------------------------------- |
| v1, v2 | _(silent)_                                                     |
| v3     | `[INFO] Auth: --auth=acp-callback (host-mediated refresh via …)` |

Stronger, and needing no baseline: provoke the conflict. `acp --trust-tools=x`
errors with `--agent-engine=v3` **only** when v3 is actually in effect.

### `--agent-engine=kas` is an undocumented accepted alias for `v3`

`--help` lists only `v2, v1, v3`. `kas` is accepted, and the conflict guard's
error message normalises it back to `v3`. **Any extracted enum will miss this.**

---

## 2. The v3 permission model

### Where rules live, and who reads them

From `acp-server.js` (`// src/policy/…` markers intact):

- `src/policy/workspace-store.ts` —
  `var POLICY_FILENAMES = ["permissions.yaml", "permissions.json"];`
- `src/policy/policy-loader.ts` — `loadPolicy()` layers, in order:
  1. built-in scope rules
  2. admin — `/etc/kiro/managed-settings.json`
  3. **user — `~/.kiro/settings/`**
  4. **workspace — `~/.kiro/workspace-roots/<hash(workspaceRoot)>/`**
- `src/policy/policy-session.ts` — the policy engine is **session-scoped and
  rebuilt per session**, so a startup-only `strace` will not see the file open.

Rules compile to **Cedar**. Shape `{ capability, effect, match, exclude }`,
resolved most-restrictive-wins: `deny` > `ask` > first `allow`.

Note the workspace **store** is keyed by a hash of the workspace root and lives
**per-user, outside the repository**. There is no project-local
`.kiro/settings/permissions.yaml`: `loadPolicy` (`480566`) reads exactly three
on-disk locations — the admin path, `~/.kiro/settings/`, and
`getWorkspaceDir()` (`480539`), which is
`~/.kiro/workspace-roots/<hash(workspaceRoot)>/`.

**That does NOT mean a cloned repo cannot inject permission rules**, and this
doc said it did until an audit refuted it. The file store is not the only rule
source: `loadPolicy` also merges `options.agentRules`, which come from a
**repo-committed agent profile** under `.kiro/agents/*.md|json` (read by
`loadAgentProfiles`, `414399`, which passes `frontMatter.permissions` straight
into the definition). When such a profile is the session's active mode,
`resolveAgentPermissions` (`486734`) marks it
`source === "workspace-profile"`, so `parseAgentPermissions` (`481124`) parses
its rules under the **`workspace`** scope — and
`SCOPE_ALLOWED_EFFECTS.workspace` (`480000`) is `["deny", "ask", "allow"]`, so
`allow` survives parsing. The bundle's own doc comment says it outright: _"Both
permit allow effects."_

`splitWorkspaceRule` (`480640`) is not a sufficient sanitizer, because it
constrains only the **filesystem** half. An fs pattern resolving outside the
workspace root causes the whole rule to be **dropped with a warning** — it is
not clamped — while every non-fs capability is re-emitted verbatim:
`shell`, `mcp`, `subagent`, `web_fetch`, and the non-fs expansion of `all`, all
with `effect: allow` intact.

The `if (this.workspaceTrusted)` guard on profile loading (`486595`) looks like
the mitigation. It is not, on this path: both KAS entry points, `startStdio`
(`495193`) and `startWebSocket` (`495219`), construct `KiroAgent` with a
hardcoded `workspaceTrusted: true`, and nothing in the bundle ever sets it
false. So under `acp` the repo's `.kiro/agents` **always** loads. **Treat
`.kiro/agents` in an untrusted clone as privileged, exactly like
`.kiro/hooks`.**

The only things still standing between that and a grant are that the profile
must be the session's active mode, and that the `kiro`-scope hard denies below
still win under most-restrictive-wins.

### Capabilities (read out of `src/policy/capabilities.ts`, `117437`)

Base (`BUILTIN`): `fs_read`, `fs_write`, `shell`, `web_fetch`, `web_search`,
`subagent`, `skill`, `power`, `context`, `diagnostics` — plus `mcp` (pattern
`server/tool`), which is not in `BUILTIN`.

Meta, and they expand: `all` = `BUILTIN` + `mcp`; `builtin` = `BUILTIN`;
`filesystem` = `fs_read` + `fs_write`. **`filesystem` is a meta capability, not
a base one** — this doc previously listed it inline with the base set, and
omitted `power` entirely.

Hardcoded and un-overridable, in two separate mechanisms. The `kiro`-scope rule
(`479189`) denies `fs_write` to `~/.kiro/settings/`, `.kiro/settings/`,
`~/.kiro/workspace-roots/` and `~/.kiro/sandbox-state/` — the agent can edit
neither its own policy nor the sandbox lock files (tampering with those is a
cross-session isolation bypass). Separately, `.kiroignore` is a hard **deny**,
not an ask, and it is enforced in `PolicyEngine.evaluateFilesystem`
(`479571`) rather than as a `kiro`-scope rule — deliberately, so it can force
`nocase: true` unconditionally and cover the NTFS bypass variants
`.kiroignore.`, `.kiroignore ` and `kiroig~*` (`479183`). That check returns
**before** `findMatchingFilesystemRules` runs, so it never enters
most-restrictive resolution at all.

The single `effect: "ask"` rule covers `.git` (including the bare `.git`
submodule-pointer file), `.vscode`, `.kiro/agents/`, `.kiro/hooks/` (and their
`~/.kiro/` counterparts), `**/*.code-workspace` and `**/mcp.json` — each
expanded with NTFS trailing-dot, trailing-space and 8.3 short-name variants.

Two further ask-rule sets are **conditional**, not hardcoded:
`buildIgnoreFileProtectionRules` (`479232`) asks on other configured agent
ignore files, and `buildUntrustedAutoloadAskRules` (`479247`) asks on
`.kiro/{steering,skills,extensions,powers}/` only when the workspace is
untrusted — which under `acp` it never is, per the hardcoded
`workspaceTrusted: true` above.

### The interactive half

A rule with `effect: ask` is resolved **with the client**, over ACP
(`session/request_permission`). v3 additionally advertises
`policyNotifications: true` and an undocumented `_kiro/` surface, present in the
KAS JS and **0-count in the Rust binaries**:

```
_kiro/permission/respond      _kiro/permissions/explain    _kiro/permissions/list
_kiro/policy/changed          _kiro/policy/check           _kiro/policy/error
_kiro/policy/ignore_files_changed
```

### `--trust-tools` is a CLIENT-side knob — and this is the crux

The intuitive story ("v3 replaced the trust flags with `permissions.yaml`") is
**wrong**, even though the vendor's own breaking-changes table invites it:

> **Permissions** — `--trust-all-tools` and `/tools trust` replaced by
> `permissions.yaml`

What is actually true:

- Under v3, **`chat` still parses both flags** — neither is rejected. But the
  auto-answer machinery in `~/.local/share/kiro-cli/tui.js` belongs to
  **`--trust-all-tools` only**, and this doc previously mis-attributed it to
  `--trust-tools`. Measured: `grep -o trustTools tui.js | wc -l` → **1**, the
  flag-spec row `{type:"string-list",key:"trustTools",flags:["--trust-tools"]}`.
  It reaches no store key and no approval handler.
- `--trust-all-tools` does, and it is two-stage. The flag sets
  `trustAllToolsRequested`; the TUI renders a consent screen and only
  `confirmTrustAllTools()` sets `trustAllToolsConfirmed`. Once confirmed,
  `case "approval_request"` auto-selects `allow_always` ?? `allow_once` — and
  that is where the explicit `agentEngine === "kas"` branch lives, additionally
  gated on `cIe(e){return !!e.toolId||!!e.consentContext||(e.trustOptions?.length??0)>0}`,
  i.e. on the `_meta.kiro.toolId` that KAS does send. Both the `kas` branch and
  the toolId gate are real; they just hang off the other flag.
- What `--trust-tools` does in `tui.js` is get relayed. The generic argv builder
  `r7e()` re-emits it as `--trust-tools <csv>` onto the child argv — but that
  argv is used **only on the non-kas path**: `lS(e,n,t)` returns `new z7(e,n)`
  (spawns `KIRO_CHAT_CLI_BIN` with the argv) for v2, and `new CD(kasOptions)`
  for kas, discarding `n` entirely. `kasOptions` carries no trust data. **So
  under the v3/kas engine `tui.js` does not even forward it.** Whatever, if
  anything, honours `--trust-tools` under v3 is downstream of `tui.js` and this
  probe did not find it — treat that as open, not as "honoured".
- So the flag family is an **auto-answer knob on the CLIENT**, not a pre-grant
  on the agent.
- **That is exactly why `acp` refuses it.** On the `acp` arm, kiro-cli *is* the
  agent and the external ACP client owns the answer. There is nothing agent-side
  to bind to: `trustAllTools`, `trustedTools`, `trust-all-tools` all count
  **zero** in `acp-server.js`, whose entire CLI surface (`getCliArg`) is
  auth/endpoint/sandbox/transport.

So v3's model is genuinely two-part — **declarative** Cedar policy from
`permissions.yaml`, plus an **interactive** ACP round-trip for `ask` — and the
CLI flag can only ever have participated in a third thing (auto-answering as a
client) that has no meaning when you are the agent.

---

## 3. The `acp` + v3 conflict guard

### It is deliberate, hand-rolled, and not clap

The error string is a hardcoded literal in the chat binary, immediately preceded
by the guard's own flag list:

```
…crates/chat-cli/src/cli/mod.rs:869…serverstdio--agent--model--trust-all-tools--trust-tools
the following arguments are not supported with --agent-engine=v3:
```

clap's own phrasing for a conflict is the different `cannot be used with` — its
message template
`cannot be used with one or more of the other specified arguments` is in the
binary. Do **not** try to elicit it by repeating `--agent-engine`, as this doc
originally claimed: that is a different clap error class and prints
`the argument '--agent-engine <ENGINE>' cannot be used multiple times`. The
conclusion stands on the hardcoded literal above, not on that probe — this is
custom code, not a derive-macro `conflicts_with`. It is a designed exclusion,
not an unfinished port.

### Scope of the guard

| option on `acp`          | v1  | v2  | **v3**       |
| ------------------------ | --- | --- | ------------ |
| `--agent <AGENT>`        | ok  | ok  | **BLOCKED**  |
| `--model <MODEL>`        | ok  | ok  | **BLOCKED**  |
| `--effort <EFFORT>`      | ok  | ok  | **BLOCKED**  |
| `-a`/`--trust-all-tools` | ok  | ok  | **BLOCKED**  |
| `--trust-tools <NAMES>`  | ok  | ok  | **BLOCKED**  |
| `--agent-engine`         | ok  | ok  | ok           |
| `-v`/`--verbose`         | ok  | ok  | ok           |

Value-specific (v1/v2 accept all five) and **`acp`-specific** — on `chat`,
engine v3 accepts all five.

### Distinguishing the three error classes

This is the single most useful diagnostic habit with this CLI, because two of
them look alike and mean opposite things:

| error text                                              | means                                          |
| ------------------------------------------------------- | ---------------------------------------------- |
| `unexpected argument 'X' found`                         | the parser does **not know** X here — position or spelling |
| `the following arguments are not supported with Y: X`   | it **knows** X and declares it exclusive with Y |
| `invalid value 'v' for 'X'`                             | X was **accepted**; its value was rejected      |

Practical use: to prove a flag parsed, pair it with a **late-failing** argument
(`--wrap bogus`, `--agent-engine bogus`) — an `invalid value` reply proves
everything before it was accepted.

### The escape hatch

A caller's explicit `--agent-engine` overrides an injected global `--v3`, with
no "cannot be used multiple times":

```console
$ kiro-cli --v3 acp --agent-engine=v2 --model auto        # runs, v2
$ kiro-cli --v3 acp --agent-engine=v3 --model auto        # CONFLICT (asked for the impossible pair)
```

So nothing is unreachable; the engine is opt-out per invocation.

---

## 4. Consequences for anyone wrapping kiro-cli

Written as rules because each was paid for with a shipped bug:

1. **Prepend globals; never append.** `--tui`/`--v3` are launcher-global.
   Appended after a subcommand they are forwarded verbatim and parsed against
   *that* subcommand — which on `acp` means rejected, and reads exactly like
   "unsupported" when it is not. It is worse than a plain error on `chat`, which
   declares its own `--tui` and `--v3`: the token is silently accepted by the
   subcommand and the launcher-global translation never happens.
2. **A `kiro-cli-chat` wrapper is on the `kiro-cli` code path** (PATH
   resolution, §1). Reason about the **composition** of your wrappers, never
   each in isolation.
3. **Do not implement engine precedence.** Upstream already resolves a caller's
   `--agent-engine` over an injected `--v3`.
4. **"Is the engine v3" is a RUNTIME question.** It cannot be answered from
   config, because the caller can override. Both directions are real:
   `--v3 acp --agent-engine=v2 --trust-tools=x` runs, and
   `acp --agent-engine=v3 --trust-tools=x` conflicts even with v3 off in config.
5. **Handle both option spellings.** The launcher itself emits the two-token
   form.
6. **`--tui` is inert on `acp` structurally, not observably — but it is NOT
   unconditionally consumed.** It survives on a **bare launch** and is dropped
   only once the invocation carries an explicit subcommand:

   ```
   kiro-cli --tui          -> [chat] [--tui]      # bare: FORWARDED
   kiro-cli --tui --v3     -> [chat] [--tui] [--v3]
   kiro-cli --tui chat     -> [chat]              # explicit sub: dropped
   kiro-cli --tui acp      -> [acp]               # dropped
   kiro-cli --tui mcp list -> [mcp] [list]        # dropped
   ```

   So injecting `--tui` on an explicit `chat` is a no-op upstream, and on `acp`
   it could never have arrived. The byte-identical-stdout comparison this doc
   used to cite proves nothing, because the forwarded argv is identical either
   way. (Appended it IS forwarded — `kiro-cli acp --tui` → `[acp] [--tui]` —
   and the chat binary then rejects it with
   `unexpected argument '--tui' found`.) Still worth withholding.

   > **Correction, 2026-07-30.** An earlier pass of this doc said the launcher
   > "CONSUMES it and forwards it in no form". That is wrong, and it was wrong
   > because the bare-launch case was never probed — every cited example
   > happened to carry a subcommand. Re-measured with a printing
   > `kiro-cli-chat` first on `PATH`.

---

## 5. Gaps

- **G1 — Which KAS bundle does a fresh v3 session load?** Seven are cached
  (2.12.3 → 2.15.2). Source quotes here are from the 2.15.2 bundle; a live `ps`
  capture caught a 2.13.0 process. The resolution rule is unknown, and the
  permission machinery has not been diffed across versions.
- **G2 — Can the KAS download be pinned or vendored?** The highest-value
  question for Nix packaging. Today the derivation pins the CLI and not the
  engine.
- **G3 — `session/request_permission` has never been observed on the wire.**
  Both the `ask` path and the auto-answer path are proven from source only;
  observing them costs a real prompt.
- **G4 — Does v3 ACP honour `chat.defaultModel`?** Still open. `--model` is
  blocked on v3 `acp` and no `model` vocabulary appears anywhere in the v3 ACP
  handshake, so this is the only candidate route left for setting a model there.
- **G5 — v2's ACP capabilities were never read.** `acp --agent-engine=v2`
  returned 0 bytes on both streams for a byte-identical `initialize` — different
  framing, or no handshake sent. Some v2 claims elsewhere rest on Rust string
  adjacency, which is weak evidence (the linker decides layout, not the code).
- **G6 — `v3` without `tui`.** Vendor Known-gaps says *"the legacy non-TUI mode
  (`kiro-cli chat` without the TUI) does not support the v3 engine."* So
  `--v3` on `chat` without `--tui` is unsupported — but does it **error**, or
  silently fall back to v2? Unmeasured, and "silently falls back" would be the
  bad case for any config that sets v3 without tui.
- **G7 — the full guard flag list.** The extracted string window shows
  `--agent --model --trust-all-tools --trust-tools`, but `--effort` is also
  blocked and sits outside the window. Read `cli/mod.rs`'s list properly.
- **G8 — `agentInfo.version` reports `2.15.1` from a 2.15.2 binary.** Stale
  constant, or a separately-versioned component? Affects anyone fingerprinting
  over ACP.
- **G9 — `kiro-cli-chat --v3 acp --trust-tools=x` does NOT conflict**, unlike
  the launcher form. Either the chat binary's `--v3` does not reach acp's engine
  selection, or it does so differently. Means *which binary you invoke* changes
  engine semantics.
- **G10 — undocumented v3 session flags** seen in `session/new` `_meta`:
  `semanticReviewEnabled`, `ftaEnabled`, `workflowsEnabled`, `specPlanEnabled`,
  `specWorkflow`, `specSkipClarificationEnabled`. What toggles them, and what is
  `fta`?

---

## 6. Reproducing this

```bash
# 1. Pin the binary. NEVER use `kiro-cli` from PATH — that is a wrapper.
K=$(nix build --no-link --print-out-paths .#kiro-cli); KB="$K/bin/kiro-cli"

# 2. The KAS bundle — where v3 actually lives
ls ~/.local/share/kiro-cli/kas/
KAS=$(ls -d ~/.local/share/kiro-cli/kas/*/ | tail -1)
grep -o 'POLICY_FILENAMES = \[[^]]*\]' "$KAS"/node_modules/@kiro/agent/dist/server/acp-server.js
grep -c 'trustedTools\|trustAllTools' "$KAS"/node_modules/@kiro/agent/dist/server/acp-server.js  # expect 0

# 3. Spy on what the launcher forwards (the argv-rewriting table in §1)
#    Build a package whose bin/kiro-cli is the REAL launcher and whose
#    bin/kiro-cli-chat prints its argv, then put it first on PATH.

# 4. The conflict matrix, engine by engine
for e in v1 v2 v3; do
  printf '%s: ' "$e"
  timeout 20 "$KB" acp --agent-engine=$e --trust-tools=fs_read </dev/null 2>&1 | head -1
done

# 5. Engine fingerprint without auth (stderr only)
timeout 20 "$KB" acp --agent-engine=v3 </dev/null 2>&1 >/dev/null | head -1
```

The ACP handshake driver (`initialize` + `session/new`, no prompt, no credits)
is in `kiro-acp-and-launcher-argv.md` § Replayable probe. It must answer the v3
`_kiro/auth/getAccessToken` callback or v3 stalls forever.
