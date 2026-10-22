# Architecture

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
- **PROPOSAL (not yet vetted): runtime proxy keys are pulled by the instance.**
  A runtime routed through `ai.cliproxyapi.instances.<n>` publishes its key and
  its rules (`ai.<runtime>.proxy.allow` plus one base-URL rule per enabled
  instance provider) at `ai.internal.proxyClients`, and the instance's derived
  settings list the key and its allowlist entry; the key is an
  `ai.claims.proxy-client-key` claim. Instance `providers` lower into
  `settings.api-keys` blocks through one API table
  (`packages/cliproxyapi/lib/providers.nix`); each runtime names the API it
  speaks on its record (`proxyApi`). Pushing into the instance would create one
  a typo names, and a hand-written copy would be a second owner. See
  `lib/ai/proxy/default.nix` and `packages/cliproxyapi/modules/instances.nix`.
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
