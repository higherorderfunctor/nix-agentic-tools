# Delegate sizing package

> **Last verified:** 2026-09-19 (commit ebf06268) — initial package
> implementation.

`lib/models.nix` owns the model decisions and runtime ids. `lib/render.nix`
generates one skill per runtime: first-party candidates first within each tier,
then enabled external pools. Kiro candidates intersect
`packages/kiro-cli/models.json` at build time and still require live discovery
before a workflow pins an id. Manual external entries add instructions, never
candidate rows; manual-only wins if a consumer lists a runtime in both external
lists.

Both backends import `modules/common.nix`. It maps the existing
`mkSkillPackageModule` factory over the three supported runtimes, binding a
runtime to each callback through a singleton capability set. The identical
portable enable declarations merge. Runtime-only options extend the matching
program submodule, so external pools and instruction overrides cannot be set at
`ai.programs.delegate-sizing`. No shared engine changes are needed.

Instruction presets live in `lib/presets.nix`. The source runtime's settings
control its external launch even when its skill is disabled: an enabled Codex
CLI may still serve Claude delegates without installing its own sizing skill.
`false` omits an instruction block. The packaged usage script only reads Codex
account limits; no model turn is launched.

The eight-line `fragments/skill-routing.md` is the sole always-on rule source,
delivered through the factory's rules hook. The retired monorepo fragment is
unregistered. Keep model tables and harness details in the generated skill.

Content, HM/devenv modules and eval checks are discovered through the package
owner layout. The registry excludes this generated content package from release
updates. `checks/module-eval.nix` verifies both consumer backends, including
runtime-only options, manual access without enable, custom/disabled blocks and
the short stub. Its file checks realize the generated skill directories.
