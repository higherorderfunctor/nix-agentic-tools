# kiro-cli: settled decisions

> **Last verified:** 2026-11-06 — the package targets Kiro CLI 3.0.0 only, owns
> its release pipeline, adds no Kiro config root, tiers its options by where the
> setting lives, and derives its flag tables from the binary.

Rules about how `packages/kiro-cli` is built. Each entry is a rule, its reason,
and where the mechanism lives. Decisions that already have a full write-up stay
there; the last section only points at them.

- **Release: v3 only, no backwards compatibility.** Options are pinned to the
  current release and there is no engine option or v2 path. The package owns the
  unwrapped derivation, built from the upstream tarballs, and its own Linux
  `buildFHSEnv`, whose `bin/` holds only `kiro-cli`. The updater reads the
  upstream release manifest, and bumps run through the `update.yml` workflow
  with `targets=kiro-cli` (`gh workflow run update.yml -f targets=kiro-cli`),
  never by hand. A compatibility layer would need a conflict list that rots
  every release. See `packages/kiro-cli/lib/release.nix`,
  `packages/kiro-cli/registry.nix` (`update.targets.kiro-cli`),
  `.github/workflows/update.yml` and `fhs-sandbox.md`.
- **No new config root.** The wrapper and modules never set `KIRO_HOME`,
  `KIRO_DATA_DIR`, `KIRO_AGENT_CONFIG_DIR` or a similar root, so Nix-managed
  configuration composes with the user's own instead of hiding it. The wrapper
  also carries no secret: `KIRO_API_KEY` stays out of it. Anything Kiro reads
  from outside the project is delivered by Home Manager into the user's own
  `~/.kiro`; devenv has no equivalent, and a surface that needs one is a devenv
  gap that warns through `surfaceSupport`. See
  `packages/kiro-cli/lib/mkKiro.nix` (the `surfaceSupport` record and the note
  on the missing root) and `packages/kiro-cli/checks/kiro-wrapper-argv.nix`,
  which fails a launcher carrying `KIRO_HOME` or `KIRO_DATA_DIR`.
- **Options come in two tiers.** `ai.kiro.cli.<setting>` holds settings valid in
  the repo-local `.kiro/settings.json`, plus knobs valid for both `chat` and
  `acp`. `ai.kiro.cli.chat.*` and `ai.kiro.cli.acp.*` hold knobs that exist only
  as that subcommand's flag or environment variable. Options declare settings
  only, never one-off commands such as `--version` or `--resume`. The same
  options exist on Home Manager and devenv; whatever falls outside the tiers is
  a devenv gap that warns. This keeps each option's scope readable from its
  path. See `packages/kiro-cli/lib/cliOptions.nix` and
  `packages/kiro-cli/lib/mkKiro.nix`.
- **Flag tables come from the extractor.** The binary's clap help fills the
  `cli.options.*` facts. Every extracted option is classified in
  `packages/kiro-cli/lib/cliOptions.nix` as a setting or as excluded with a
  reason, and CI fails on an unclassified or stale row. An environment variable
  joins that table only once it has been measured (see `probing.md`). A check
  holds an exact expectation only where this package's code consumes the value;
  every other row is a membership expectation, so an upstream addition is drift
  that regeneration clears instead of a red check. This keeps classification
  from drifting silently across releases. See
  `packages/kiro-cli/checks/kiro-cli-extracted.nix`,
  `packages/kiro-cli/extracted/` and the Tests section of `launcher-argv.md`.

## Decided in `launcher-argv.md`

- **Engine:** `launcher-argv.md`, "`--v3` is launcher-global, so it is
  prepended" and "`acp` takes its engine from `acp`, not from `--v3`".
- **Trust:** `launcher-argv.md`, "Tool trust is `permissions.yaml`, never a
  flag".
- **Wrapper injection:** `launcher-argv.md`, "Consumer options for `chat` and
  `acp`" and "How the scan decides (`lib/idempotentFlags.nix`)".
