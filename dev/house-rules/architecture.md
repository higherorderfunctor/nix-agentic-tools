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
- **Long-running services use `ai.services`.** Declare a daemon under
  `ai.<owner>.services`; `packages/ai-module/lib/services.nix` lowers it to
  systemd or devenv. It reads store paths and secrets at start, never
  engine-written files. One-shot jobs and file-watch units are outside this
  surface; glab keyring keeps its native mechanism.
- **Typed settings come from the extracted generator.** An owner with extracted
  settings facts gets its option type from `lib/extracted/options.nix` and its
  config file from `lib/extracted/render.nix`, which lifts secrets into
  placeholders. The four older generators (claude-code, kimchi, glab, git tools)
  migrate to it as separate work; never add another. See
  `dev/fragments/extracted/typed-settings.md`.
- **Exclusive resources use claims.** Owners register `ai.claims.<group>.<key>`
  for paths, ports and services; one registry validates all groups. Owners never
  assert uniqueness, and adding a group needs no validation code. See
  `packages/ai-module/modules/common.nix`.
