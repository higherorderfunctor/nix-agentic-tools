# ai-module architecture decisions

> **Last verified:** 2026-11-07 — the vetted layer, secret, service, instance
> and claim decisions moved here from the repository architecture list.

## Files and activation

- **Files use layer 2.** `ai.files` owns normalization, delivery and retirement;
  backend file sinks have one writer. See `packages/ai-module/docs/DESIGN.md`,
  layer 2.
- **Finite activation uses layer 3.** `ai.activation` orders commands through
  abstract points and adds strict shell execution. See
  `packages/ai-module/docs/DESIGN.md`, layer 3.
- **Owner declarations use layer 1.** Write `ai.<owner>.files` and
  `ai.<owner>.activation`; one owner helper preserves module priorities and
  gates delivery. See `packages/ai-module/docs/DESIGN.md`, layer 1.

## Services and instances

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
- **Tool instances use the instances helper.** A tool with typed settings that
  runs as a daemon declares `ai.<owner>.instances.<name>` through
  `packages/ai-module/lib/instances.nix`: one service and port claim per
  instance, its settings rendered through `serviceEntry.files`, the same owner
  module on Home Manager and devenv. Selecting an owner's instance by name goes
  through its `select`; an inference selection names an instance across owners,
  so it looks the name up in the inference registry instead. This keeps every
  instance-shaped tool on one option shape and one lowering. See
  `packages/ai-module/docs/DESIGN.md`, Services.

## Claims

- **Exclusive resources use claims.** Owners register `ai.claims.<group>.<key>`
  for paths, ports and services; one registry validates all groups. Owners never
  assert uniqueness, and adding a group needs no validation code. See
  `packages/ai-module/modules/common.nix`.

## Model catalogs and budget reach

- **The shared catalog owns serving identity and runtime reach.**
  `lib/catalog/resolve.nix` resolves canonical model aliases and rejects
  overlapping budgets once; `modules/catalog.nix`, imported by the existing
  common module, composes credential delivery and family budget bindings into
  that graph. CPA renders client grants and routing renders launches from the
  checked result. The manual `aiModule.catalog` export uses the same resolver.
  Fit guidance, usage collection and pacing stay with their existing owners.
- **OAuth offers are open provider catalogs.** CPA grants credentials rather
  than individual OAuth models. An OAuth pool therefore offers its provider's
  whole catalog, including later registrations; API-key offers remain finite.
  Overlap compares canonical identities and catalog makers, never model-name
  prefixes. See `packages/ai-module/docs/catalog.md` for the representation and
  diagnostics.
