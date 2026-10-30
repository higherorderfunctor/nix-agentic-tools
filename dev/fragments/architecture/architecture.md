# Architecture

> **Last verified:** 2026-10-29 — repository architecture decisions.

HITL-vetted decisions about how this repository is built. Each entry is a rule,
its reason, and where the mechanism lives. Before adding a mechanism, check this
list. A mechanism that is not here means: find the existing one with git grep,
and if none fits, propose the change to this file before building. Never add ad
hoc machinery beside an existing abstraction.

- **Owner declarations use layer 1.** Write `ai.<owner>.files` and
  `ai.<owner>.activation`; one owner helper preserves module priorities and
  gates delivery. See `packages/ai-module/docs/DESIGN.md`, layer 1.
- **Files use layer 2.** `ai.files` owns normalization, delivery and retirement;
  backend file sinks have one writer. See `packages/ai-module/docs/DESIGN.md`,
  layer 2.
- **Finite activation uses layer 3.** `ai.activation` orders commands through
  abstract points and adds strict shell execution. See
  `packages/ai-module/docs/DESIGN.md`, layer 3.
- **Secret readiness is one provider registry.** Declare a secret provider once
  in `ai.activationOrder.secretProviders` with its activation nodes and its user
  unit; activation's `secrets` point and `ai.services` units both read it. A
  unit that reads a reference or a restart-trigger file wants and orders after
  the provider units and starts with the target the provider's own unit uses,
  read from the evaluated unit; Home Manager adds sops-nix by default. Home
  Manager's post-reload service check reads the same units' last results. A
  hardcoded provider name or a second ordering mechanism would drift. See
  `packages/ai-module/lib/secrets.nix` and
  `packages/ai-module/lib/services.nix`.
- **Long-running services use `ai.services`.** Declare a daemon under
  `ai.<owner>.services`; `packages/ai-module/lib/services.nix` lowers it to
  systemd or devenv. It reads store paths and secrets at start, never
  engine-written files. One-shot jobs and file-watch units are outside this
  surface; glab keyring keeps its native mechanism.
- **Rendered service files use `serviceEntry.files`.** A daemon that reads
  secrets from a config file declares `files.<key>` on its `ai.services` entry:
  JSON content with `{$NAME}` placeholders, the redact references that fill
  them, and the variable that carries the path. The generic launcher renders the
  file at each start, so secrets stay out of the store and no tool needs a
  secret-file patch or its own start script. See
  `packages/ai-module/lib/services.nix` and `packages/ai-module/docs/DESIGN.md`,
  Services.
- **Secret files are delivered by `ai.services`.** A setting that wants the path
  of a file holding a secret is typed `redact.types.secretFile`; the consumer
  still writes a redact reference. The service launcher writes the value to a
  0600 file in the service's runtime directory and delivers that path, and
  restart triggers and provider ordering come from the reference as before. An
  owner never copies a key to disk, probes a key file or wires its trigger by
  hand, and a secret-file value reaching any other launcher fails evaluation.
  See `lib/redact/default.nix`, `packages/ai-module/lib/services.nix` and
  `dev/fragments/redact/redact.md`.
- **Tool instances use the instances helper.** A tool with typed settings that
  runs as a daemon declares `ai.<owner>.instances.<name>` through
  `packages/ai-module/lib/instances.nix`: one service and port claim per
  instance, its settings rendered through `serviceEntry.files`, the same owner
  module on Home Manager and devenv. Selecting an owner's instance by name goes
  through its `select`; an inference selection names an instance across owners,
  so it looks the name up in the inference registry instead. This keeps every
  instance-shaped tool on one option shape and one lowering. See
  `packages/ai-module/docs/DESIGN.md`, Services.
- **Typed settings come from the extracted generator.** An owner with extracted
  settings facts gets its option type from `lib/extracted/options.nix` and its
  config file from `lib/extracted/render.nix`, which lifts secrets into
  placeholders. This avoids duplicating type and render logic over extracted
  facts. The four older generators (claude-code, kimchi, glab, git tools)
  migrate to it as separate work; never add another. See
  `dev/fragments/extracted/typed-settings.md`.
- **Exclusive resources use claims.** Owners register `ai.claims.<group>.<key>`
  for paths, ports and services; one registry validates all groups. Owners never
  assert uniqueness, and adding a group needs no validation code. See
  `packages/ai-module/modules/common.nix`.
- **Inference selection is runtime library code.** Inference proxy owners add
  their instances to one registry, `ai.internal.inferenceInstances`, by ordinary
  module merge and claim each name in `ai.claims.inference-instance`;
  `lib/ai/inference` names no owner except one: an external `url` + `key`
  selection has no registry entry, so it lowers as `cliproxyapi`, named once in
  `externalBackend`. An instance's `clients` are optional, so an owner whose
  instances take no client key registers none. Root `ai.settings.inference`
  copies its set fields down to `ai.<runtime>.settings.inference` at default
  priority, so a runtime value wins field by field; a runtime selecting the
  other form (`instance` vs `url`) inherits none of the root's fields of that
  form; `instance = null` opts a runtime out. The selected instance's backend
  picks the one lowering a runtime runs, and a runtime without that lowering
  fails an assertion naming the backend. Everything a backend sets, launcher
  flags included, lives in its lowering. Lowerings set native values at default
  priority, so a consumer's own native value wins. Vetted 2026-10-28. This keeps
  a second proxy owner a module merge rather than an edit to a shared owner
  table, and keeps a consumer's override a plain definition. See
  `lib/ai/inference/default.nix`, `lib/ai/app/mkBackendTransform.nix`,
  `packages/claude-code/lib/inference.nix` and
  `packages/chatgpt-codex/lib/inference.nix`.
- **PROPOSAL (not yet vetted): network proxy is a shared surface.**
  `ai.proxy = {instance; http; https;}` selects the network proxy for a
  process's HTTP and HTTPS traffic. Owners register
  `{enable; http; https; trust;}` in `ai.internal.proxyInstances` and claim
  names in `ai.claims.proxy-instance`, independently of inference. Explicit root
  or runtime protocol fields, including null, win only for that protocol. An
  unset field uses its instance value first, then an explicitly defined sibling
  when no instance is selected. Airlock registers both protocols at the same
  loopback origin; plain HTTP currently fails until a later stack change adds
  forwarding. An optional registry trust helper supplies CA trust through
  Claude's launcher; other runtimes warn by name (retention and precedence:
  `dev/fragments/ai-proxy/ai-proxy.md`). One generic lowering names `HTTP_PROXY`
  and `HTTPS_PROXY`; runtimes choose delivery only. Definition priority
  distinguishes explicit fields from defaults to avoid circular sibling
  fallback; instance-derived values never fill a sibling. The root selector and
  explicit protocol fields copy to `ai.<runtime>.proxy` at default priority.
  Root sibling fallback also copies when no instance is selected at runtime
  scope. Runtime overrides are field by field and explicit null blocks the
  corresponding variable. Prefer a runtime settings file that honors the value,
  then an environment wrapper default the user's environment can override, then
  a CLI flag. Native user values win; unsupported runtimes warn through
  `surfaceSupport`. Unknown or disabled instances fail with the option and
  registered names. See `lib/ai/proxy.nix`, `lib/ai/sharedOptions.nix`,
  `lib/ai/app/mkBackendTransform.nix` and `dev/fragments/ai-proxy/ai-proxy.md`.
- **PROPOSAL (not yet vetted): CPA instances own named routing.** Each
  `ai.cliproxyapi.instances.<name>` declares upstream `credentials` and
  `clientKeys` once. Each client key routes only to named upstream credentials;
  OAuth rules carry exact auth-file IDs, API-key rules carry exact base URLs,
  and one API table lowers those credentials. A Harness selects
  `settings.inference = {instance; clientKey;}` without publishing keys or
  rules. External `url` + `key` selections add nothing to Instances. See
  `lib/ai/inference/default.nix`, `packages/cliproxyapi/lib/providers.nix` and
  `packages/cliproxyapi/modules/instances.nix`.
- **PROPOSAL (not yet vetted): harness sandboxing is ours.** The host sandbox
  (the microvm) is the real protection. `ai.jail` / `ai.<runtime>.jail`
  (jail.nix, bubblewrap) is an extra layer that keeps a harness from damaging
  its own dev environment, mostly by accident while it debugs that environment;
  the two may be layered. `ai.jail` wraps every harness launcher once, in
  `lib/ai/app/mkBackendTransform.nix`, so every runtime and both backends share
  it and the command keeps its name. Copilot is the exception: it ships no
  launcher here, so it only gets a warning. Rejected: each runtime's built-in
  sandbox, because they cannot be normalized across runtimes; and a per-factory
  wrapper, which would drift per runtime. See `lib/ai/jail/default.nix` and
  `packages/jail-nix/docs/jail-nix.md`.
- **PROPOSAL (not yet vetted): Runtime support is declared in
  `surfaceSupport`.** Any shared root surface or normalized settings field a
  runtime does not declare warns when a consumer sets it, on each backend the
  runtime does not declare. This keeps a new surface or field a single
  declaration with no per-runtime edits and warns about undeclared delivery. A
  per-runtime opt-out for Copilot is future work. See
  `lib/ai/app/decompose.nix`, `lib/ai/app/checkRecord.nix` and
  `lib/ai/app/supportReasons.nix`.
