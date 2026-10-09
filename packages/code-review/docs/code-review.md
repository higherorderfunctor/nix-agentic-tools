# Native code review program

> **Last verified:** 2026-10-09 — shared local evidence core, native Kimchi and
> Kiro adapters, immutable role profiles and installed Kiro role agents.

Enable `ai.programs.code-review.enable = true` in Home Manager or devenv. Only
Kimchi and Kiro are supported. `runtimes.<runtime>.enable = false` disables one
runtime. The program contributes each runtime's `code-review` entry skill
through its existing skill writer; it does not enable the runtime itself.

The package is `pkgs.ai.code-review` (flat flake output `code-review`). Both
adapters invoke the same installed Python core, prompts and schemas. Six lanes
and three waves are the shipped limits. Native role models and efforts live in
the shipped profile JSON; `ai.programs.code-review.profile` or
`runtimes.<runtime>.profile` selects a replacement JSON file without changing
the shared payload.

Kiro receives installed named JSON agents, with a profile digest in each name. A
run generates only its saved native recipe; state paths stay in task prompts
rather than installed agent instructions. Fresh native role invocations keep
substantive contexts separate, and the shared receipt ledger limits every role
to an initial output plus two corrections. Kimchi uses fresh background agent
steps and returns a native slash command from its entry skill.

The program defaults Kiro v3 and workflows on and contributes the installed
Kimchi workflows extension. Explicit Kiro false values conflict with the program
and produce an assertion. Devenv still requires the global Kiro
`chat.enableWorkflows` setting: the existing runtime warning explains this
native scope constraint. Project Kimchi resources require host-granted project
trust.

Inputs and state are writable local files. The shared API requires a clean,
pinned checkout and places each run outside it; Kiro additionally keeps state
beneath its launch workspace because native `fileCheck` rejects outside paths.
Each run has independent arm/profile/input digests and receipts. Reports include
unresolved or exhausted work instead of inventing clean completion. Acquisition
and publication remain separate transport operations; review never publishes
automatically.
