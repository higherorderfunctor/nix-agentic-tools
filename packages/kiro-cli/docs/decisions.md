# kiro-cli: settled decisions

> **Last verified:** 2026-11-06 — the package targets Kiro CLI 3.0.0 only, owns
> its release pipeline, adds no Kiro config root, tiers its options by where the
> setting lives, and derives its flag tables from the binary.

Rules about how `packages/kiro-cli` is built. Each entry is a rule, its reason,
and where the mechanism lives. Decisions that already have a full write-up stay
there; the last section only points at them.

- **Release: v3 only, no backwards compatibility.** Options are pinned to the
  current release. The package owns the unwrapped derivation, built from the
  upstream tarballs, and its own Linux FHS layer (`fhs-sandbox.md`). The updater
  reads the upstream release manifest, and bumps run through the `update.yml`
  workflow with `targets=kiro-cli`
  (`gh workflow run update.yml -f targets=kiro-cli`), never by hand. One pinned
  release keeps every option checkable against the binary that ships. See
  `packages/kiro-cli/lib/release.nix`, `packages/kiro-cli/registry.nix`
  (`update.targets.kiro-cli`) and `.github/workflows/update.yml`.
- **No new config root.** The wrapper and modules never set `KIRO_HOME`,
  `KIRO_DATA_DIR`, `KIRO_AGENT_CONFIG_DIR` or a similar root, so Nix-managed
  configuration composes with the user's own instead of hiding it. The wrapper
  also carries no secret: `KIRO_API_KEY` stays out of it. Tool trust shows the
  cost: "Tool trust is `permissions.yaml`, never a flag" in `launcher-argv.md`
  explains why devenv cannot deliver it. See `packages/kiro-cli/lib/mkKiro.nix`
  (the note on the missing root) and
  `packages/kiro-cli/checks/kiro-wrapper-argv.nix`, which fails a launcher
  carrying `KIRO_HOME` or `KIRO_DATA_DIR`.
- **Options come in two tiers.** `ai.kiro.cli.<setting>` holds settings valid in
  the repo-local `.kiro/settings/cli.json`, plus knobs valid for both `chat` and
  `acp`. `ai.kiro.cli.chat.*` and `ai.kiro.cli.acp.*` hold knobs that exist only
  as that subcommand's flag or environment variable. Options declare settings
  only, never one-off commands such as `--version` or `--resume`. The same
  options exist on Home Manager and devenv. Normalized delivery gaps warn
  through `surfaceSupport`; native settings outside the workspace allowlist fail
  evaluation on devenv. This keeps each option's scope readable from its path.
  See `packages/kiro-cli/lib/cliOptions.nix` and
  `packages/kiro-cli/lib/mkKiro.nix`.
- **Flag tables come from the extractor.** The classification of every extracted
  `cli.options.*` row, and the check that fails on an unclassified or stale one,
  is described under "Consumer options for `chat` and `acp`" in
  `launcher-argv.md`. Two rules sit on top of it. An environment variable joins
  the table only once it has been measured (`probing.md`); the table reads the
  `--help` tables only, so an unmeasured variable would be a guess. A check
  holds an exact expectation only where this package's code consumes the value;
  every other row is a membership expectation, so an upstream addition is drift
  that regeneration clears instead of a red check. See
  `packages/kiro-cli/lib/cliOptions.nix` and
  `packages/kiro-cli/checks/kiro-cli-extracted.nix`.

## Decided in `launcher-argv.md`

- **Engine:** `launcher-argv.md`, "`--v3` is launcher-global, so it is
  prepended" and "`acp` takes its engine from `acp`, not from `--v3`".
- **Trust:** `launcher-argv.md`, "Tool trust is `permissions.yaml`, never a
  flag".
- **Wrapper injection:** `launcher-argv.md`, "Consumer options for `chat` and
  `acp`" and "How the scan decides (`lib/idempotentFlags.nix`)".
