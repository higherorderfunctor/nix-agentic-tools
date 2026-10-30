## Network Proxy

> **Last verified:** 2026-10-30 — `ai.proxy` is the shared HTTP/HTTPS network
> proxy surface; inference selection remains `ai.settings.inference`.

```nix
ai.proxy.http = "http://127.0.0.1:8080";
# HTTPS uses the same proxy unless separately defined.
ai.claude.proxy.https = null;
```

The two nullable nonempty string fields are `http` and `https`, delivered as
`HTTP_PROXY` and `HTTPS_PROXY`. These select where a process's traffic leaves
the machine. Inference credentials and model routing belong to
`ai.settings.inference`; `ai.proxy` has no `instance`, registry or claims.

Each undefined field defaults to its defined sibling. Definition priority, not
whether the value is null, distinguishes undefined from explicitly configured
fields and prevents mutual default recursion. Explicit null blocks that
variable's generated value. The root copies its fields to each capable runtime
at default priority, so runtime values and nulls win field by field; an override
does not replace the other inherited field.

One generic lowering maps the two fields to environment names without knowing a
runtime or inference backend. Delivery uses an honored runtime settings file
first, otherwise an environment wrapper default the user's environment can
override, otherwise a CLI flag. A user's native value wins over the generated
default. Null suppresses generated delivery; it does not unset a user's
independently configured native value or ambient environment.

The option schema and generic mapping live in `lib/ai/proxy.nix`;
`lib/ai/sharedOptions.nix` declares the root and
`lib/ai/app/mkBackendTransform.nix` declares runtime fields and performs
copy-down. Kiro uses `ai.kiro.proxy`, outside its launcher-specific `cli`
namespace.

Both Home Manager and devenv use the same declarations and lowering. Unsupported
runtimes omit consumption in `surfaceSupport` and receive the library's default
warning for a populated root request; they never accept a silent no-op.

### Runtime delivery

| Runtime | Home Manager                                          | devenv                                            | Why this tier                                                                                                                                                                                 |
| ------- | ----------------------------------------------------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Claude  | Tier 1: `native.settings.env` in user `settings.json` | Tier 1: project `.claude/settings.json`           | Claude applies settings `env` to its process, overriding ambient uppercase variables; each lowered variable is `mkDefault`, so the same native key wins.                                      |
| Codex   | Tier 2: launcher environment defaults                 | Tier 2: launcher environment defaults             | Its outbound HTTP client reads proxy environment variables. `shell_environment_policy` and sandbox `permissions.network.proxy_url` configure spawned commands, not the CLI's own HTTP client. |
| Copilot | Unsupported; warns                                    | Unsupported; warns                                | This runtime record is github.com Copilot and ships no launcher. Repository files do not configure its process environment.                                                                   |
| Kimchi  | Tier 2: launcher environment defaults                 | Tier 2: launcher environment defaults             | Environment delivery covers both backends without relying on the unverified ACP reader of native `httpProxy`. A user's native `httpProxy` suppresses wrapper defaults.                        |
| Kiro    | Tier 2 for v3; v2 warns for nonempty proxy fields     | Tier 2 for v3; v2 warns for nonempty proxy fields | KAS's model-request handler reads standard proxy variables. The default v2 engine's model-request consumption is unverified, so `!cfg.cli.v3` declares a delivery gap.                        |

Wrapper defaults fill a variable only when both its uppercase and lowercase
names are unset, preserving even an explicitly empty ambient value. Explicit
runtime `environmentVariables` retain their existing precedence over these
defaults. `lib/ai/environment-defaults.nix` renders that one rule for every
wrapper; it does not write Home Manager session variables or devenv's shell
environment. Kiro usage tracking owns its proxy variables and rejects a
configured network proxy at evaluation. To keep tracking while other runtimes
inherit the root proxy, set `ai.kiro.proxy = {http = null; https = null;}`.

### Evidence for the delivery choice

- Claude's shared settings writer and environment precedence are in
  `packages/claude-code/lib/mkClaude.nix` (`shellSettings`); the extracted
  native `env` schema is in
  `packages/claude-code/extracted/extracted.json:659-660`. Claude 2.1.312's
  packaged x86_64-linux `bin/claude` at byte 243563379 defines
  `applyConfigEnvironmentVariables()`: it iterates settings sources from `To()`,
  reads `pe(g)?.env`, and merges the filtered values into `process.env`. Both
  branches merge: `Object.assign(process.env,S)` directly, or
  `assignFromAboveTheRepository` (243554587). Only after that loop does it call
  `ute(),fw()` (243564585). `fw()` (240867333) reads `o1()` / `Hp()` and
  installs `undici.setGlobalDispatcher(lo(r))`; `o1(e=process.env)` (240861702)
  reads `https_proxy`, `HTTPS_PROXY`, `http_proxy`, then `HTTP_PROXY`. The agent
  constructor at 240863757 uses the selected URL for both protocols. This proves
  settings environment application precedes dispatcher construction, subject to
  Claude's native settings filtering and protocol precedence.
- Codex's pinned source `360319d8dee62d87e2d59fc0c21805d79519cfed`,
  `codex-rs/http-client/src/outbound_proxy.rs:365-387`, reads the standard proxy
  variables. Its `codex-rs/core/tests/suite/responses_system_proxy.rs:82-87,121`
  exercises a model turn through `HTTP_PROXY`. The sandbox proxy option's
  narrower meaning is documented in `packages/chatgpt-codex/lib/mkCodex.nix`
  beside `permissions.network.proxy_url`.
- Copilot's module identity and absent launcher are explicit in
  `packages/copilot-cli/lib/mkCopilot.nix:1-15`.
- Kimchi 1.23.2's packaged `bin/kimchi` has `resolveProxyEnv` reads of
  `HTTP_PROXY` and `HTTPS_PROXY` at byte offsets 120814893 and 120814987.
  `applyHttpProxySettings` at offset 109177737 fills both variables with `??=`;
  reachable global-setting reads are at 120763941 and 120773662.
  `packages/kimchi/extracted/extracted.json:2848-2853` declares `httpProxy` with
  `project = false`, and the pinned `src/cli.ts:970-972` enters Pi's main
  function. Do not put this global-only setting in a project file and call it
  delivered. Native `httpProxy` consumption in Kimchi's ACP startup is
  unverified; the reachable reader above proves the normal CLI path. Trace ACP
  startup or probe it against a local proxy before claiming the native tier
  covers ACP. Until then, both backends use launcher environment defaults,
  including when the two URLs are equal.
- Kiro's packaged KAS 2.35.2
  `node_modules/@kiro/agent/dist/server/acp-server.js:2177` resolves a request
  protocol through `QSt` and `JCn`, reading lowercase then uppercase proxy
  environment variables. Its line 17354 constructs `KiroRuntimeClient` with
  `requestHandler: c_e(S, f)`, reaching that resolver through `SY`. This is the
  model request path, not an unrelated bundled SDK reader. This proves v3 only.
  The pinned 2.35.2 v2 `bin/.kiro-cli-chat-wrapped` contains `HTTP_PROXY` /
  `HTTPS_PROXY` at bytes 95900838 / 95900858 and `aws-smithy-http-client-1.5.0`
  connector strings near 6199676 / 6201467, but those strings do not establish
  that `GenerateAssistantResponse` uses the proxy-aware connector. V2 remains
  unverified and warns. Matching source with that call chain, or an isolated
  local proxy observation of a v2 model request, would settle it; no login or
  provider request was performed.

Kiro v2 warns once per nonempty effective proxy field, naming the most specific
input: `ai.kiro.proxy.http` or `ai.kiro.proxy.https`, including for inherited
root requests. Runtime-only requests warn the same way. Setting only `http` also
defaults `https`, so both fields warn unless `https = null`. V3 and
explicit-null opt-outs stay quiet. Null blocks generated delivery; an empty
string is refused by the option type. Kiro v2 exports no generated proxy
variables.
