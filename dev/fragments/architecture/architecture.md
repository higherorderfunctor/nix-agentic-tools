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
  module on Home Manager and devenv. Selecting an instance by name goes through
  its `select`. This keeps every instance-shaped tool on one option shape and
  one lowering. See `packages/ai-module/docs/DESIGN.md`, Services.
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
- **Proxy selection is runtime library code.** Proxy owners add their instances
  to one registry, `ai.internal.proxyInstances`, by ordinary module merge and
  claim each name in `ai.claims.proxy-instance`; `lib/ai/proxy` names no owner.
  An instance's `clients` are optional, so an owner whose instances take no
  client key registers none. Root `ai.proxy` copies down to `ai.<runtime>.proxy`
  at default priority, so a runtime value wins field by field; a runtime
  selecting the other form (`instance` vs `url`) inherits none of the root's
  fields of that form; `instance = null` opts a runtime out. The selected
  instance's backend picks the one lowering a runtime runs, and a runtime
  without that lowering fails evaluation. Everything a backend sets, launcher
  flags included, lives in its lowering. Lowerings set native values at default
  priority, so a consumer's own native value wins. Vetted 2026-10-28. This keeps
  a second proxy owner a module merge rather than an edit to a shared owner
  table, and keeps a consumer's override a plain definition. See
  `lib/ai/proxy/default.nix`, `lib/ai/app/mkBackendTransform.nix`,
  `packages/claude-code/lib/proxy.nix` and
  `packages/chatgpt-codex/lib/proxy.nix`.
- **PROPOSAL (not yet vetted): CPA instances own named routing.** Each
  `ai.cliproxyapi.instances.<name>` declares upstream `credentials` and
  `clientKeys` once. Each client key routes only to named upstream credentials;
  OAuth rules carry exact auth-file IDs, API-key rules carry exact base URLs,
  and one API table lowers those credentials. A Harness selects
  `proxy = {instance; clientKey;}` without publishing keys or rules. External
  `url` + `key` selections add nothing to Instances. See
  `lib/ai/proxy/default.nix`, `packages/cliproxyapi/lib/providers.nix` and
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
