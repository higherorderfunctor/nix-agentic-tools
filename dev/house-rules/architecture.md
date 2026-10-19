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
- **PROPOSAL (not yet vetted): harness sandboxing uses `ai.jail`.** Jail a
  harness launcher through `ai.jail` / `ai.<runtime>.jail`, an exclusion-only
  bubblewrap profile over jail.nix applied once at the shared install seam, so
  every runtime and both backends get one mechanism and the command keeps its
  name. A per-factory wrapper or a second sandbox layer would duplicate the seam
  and drift per runtime. See `lib/ai/jail/default.nix`,
  `lib/ai/app/mkBackendTransform.nix` and `packages/jail-nix/docs/jail-nix.md`.
