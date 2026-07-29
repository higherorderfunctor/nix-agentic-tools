# Slice Architecture Assessment

> **Status:** distillation of an in-progress design dialog (2026-05-08).
> Captures decided direction, dropped options with rationale, and open questions
> the fixture exists to answer. **This is an assessment, not a plan** — input
> for a fresh session to draft execution against.
>
> Earlier exploration in `greenfield-package-shape.md` is partially superseded.
> That doc was scoped to one package's internal shape; this doc widens to slice
> composition and fixture-first validation.

## Background

`nix-agentic-tools` is a Nix flake monorepo whose packages are **multi-facet**:
each ships a derivation, a home-manager module, a devenv module, lib helpers,
and content (markdown fragments, skills). Nixpkgs convention is
single-derivation packages, so its canonical composition patterns don't fully
apply.

Three constraints stack and shape the architecture:

1. **Multi-facet per unit** — several distinct facets per package, all expected
   to be configurable.
2. **HM / devenv parity** — every config surface available in home-manager must
   also be available in devenv and vice versa.
3. **devenv as external CLI** — devenv is consumed externally (system profile,
   HM, NixOS, project shell), not as a flake-input runner. devenv's CLI mode
   reads `devenv.nix` directly and does not compose with flake-parts'
   `perSystem`. This blocks flake-parts as the composition layer.

The architecture has been re-derived across sessions because this constraint
stack is unusual — there is no upstream pattern to copy wholesale. The
fixture-first approach below is the discipline that breaks the re-derivation
loop.

## Decided

| Decision                                                                                                                                                                                                                                                         | Why                                                                                                                                                                                                                                                                                                                                                                               |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Four contribution facets only:** `pkg`, `lib`, `hm`, `devenv`. Data lives inside whichever facet owns it.                                                                                                                                                      | Final after eliminating speculative facets (transformers, fragments, skills, tasks, checks, apps). Each excluded with explicit reason in the Dropped table.                                                                                                                                                                                                                       |
| **Slice = unit.** Each slice is a self-contained domain (e.g., a group of MCP servers, a CLI client). A slice contributes **any subset** of the four facets — including just one.                                                                                | "Package" is misleading: many slices won't export a derivation. "Slice" matches existing project vocabulary (slice-nav).                                                                                                                                                                                                                                                          |
| **Mixed combinators, native per facet.** `pkg` rolls up via `callPackage` / `packagesFromDirectoryRecursive`; `lib` via recursive attrset merge; `hm` via the consumer's HM module-system `imports`; `devenv` via the consumer's devenv module-system `imports`. | A unified `evalModules`-everywhere approach imposes module ceremony (option declarations, `_module.args` threading) on facets that don't need it. Mixed mechanisms are more idiomatic: every mechanism is one a Nix reader already knows. Cost: two patterns instead of one. Win: lightest custom plumbing, alignment with consumer UX expectations.                              |
| **Root workspace owns tasks / checks / apps.** Slices contribute the four facets only; orchestration over those contributions lives at root.                                                                                                                     | Tasks/checks/apps in this repo are inherently cross-slice (e.g., regenerate-all-instructions) or trivially derived from a slice's `pkg` (slice-CLIs via `meta.mainProgram`, slice-tests via build derivations picked up by `nix flake check`). Per-slice declaration would add ceremony without enabling a real use case. Mirrors Cargo / npm / Bazel workspace-vs-package split. |
| **Walker is thin and structural.** Discover slices via filesystem; route each facet's contribution to its appropriate native rollup. Tens of lines.                                                                                                              | The walker is the only project-specific code in the composition path — everything downstream uses standard Nix patterns. Keeping it thin is the load-bearing property.                                                                                                                                                                                                            |
| **Fixture-first, before real-repo refactor.** Build `fixture/` subdir with asymmetric mock slices exercising **only** the architecture (no domain content). Lock fixture as reference implementation, then refactor real repo to match.                          | Real-repo refactors have been re-derived across sessions because the design is fuzzy. The fixture is the spec — concrete, reviewable, regressable. Future sessions compare against the fixture instead of re-deriving from first principles.                                                                                                                                      |

## Dropped (with reason — keep for future-session reference)

| Dropped                                              | Why                                                                                                                                                                                                                                                                                                                                                                                               |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Module-system-everywhere combinator.**             | Imposes evalModules ceremony on `lib` and `pkg` rollups that already have idiomatic merge mechanisms. Mixed combinators is the choice. Reopen only if the fixture surfaces real friction.                                                                                                                                                                                                         |
| **Per-slice `tasks` / `checks` / `apps` facets.**    | No load-bearing use case in this repo. Orchestration is cross-slice; slice-specific tools surface via `pkg` + `meta.mainProgram`; slice-specific tests are derivations picked up by root `nix flake check`. Add a facet later only if a real need emerges.                                                                                                                                        |
| **Transformers as a v0 fixture concept.**            | Once standalone-skills-without-Nix was dropped (next row), transformers live entirely inside slice `hm` / `devenv` module activation logic — implementation detail of specific slices, not architectural. The fixture's "module activation produces shaped output" path already covers the load-bearing behavior. Reintroduce when a slice genuinely needs cross-cutting transformer composition. |
| **Standalone skills-without-Nix.**                   | Decided earlier — skills are a CI artifact if revisited at all, not a load-bearing consumption path. Removes the "lib function must power both flake-output and module" hedge. Modules can be the only path for content artifacts.                                                                                                                                                                |
| **Doc-gen + fragment system in active scope.**       | Deferred-not-deleted. Per-ecosystem frontmatter divergence (`paths` vs `applyTo` vs `fileMatchPattern`) and string + function + computed content mixing remain real reasons the system exists; reintroduce after architecture is stable.                                                                                                                                                          |
| **End-to-end consumer integration test in fixture.** | Highest-fidelity learning, but time disappears there. Bar is read-clean + `nix flake check` + targeted CLI assertions. Promote to end-to-end only if the cheaper bar leaves real questions unanswered.                                                                                                                                                                                            |
| **Per-slice barrel (`default.nix` listing facets).** | v1 doc (`greenfield-package-shape.md`) proposed barrels for static introspection. v0 fixture uses filesystem convention instead — `<facet>.nix` existence at slice root determines contribution. Reintroduce barrels only if "what does this slice contribute?" becomes hard to answer at a glance.                                                                                               |
| **flake-parts as composition layer.**                | Skipped because devenv's external-CLI consumption mode does not compose with flake-parts `perSystem`. This is a hard constraint, not a stylistic preference. Documented in repo memory at `reference_devenv_flake_parts_dual_mode.md`.                                                                                                                                                            |

## Open — fixture is the experiment that answers these

1. **Cross-slice lib dependency.** Does the lib rollup make slice-b's helpers
   accessible to slice-a's `package.nix` at eval time without ordering tricks?
   The fixture exercises this directly.
2. **Walker placement and shape.** Where does the walker live (`flake.nix`
   inline vs `lib/walker.nix`)? What's its public API? The fixture's walker is
   the answer by example.
3. **Structural-check surface.** What does a useful root structural check
   actually assert? At least one example must earn its keep.
4. **Mixed-combinator ergonomics.** Does "`pkg` and `lib` plain merge, `hm` and
   `devenv` via module-system" feel coherent on the page or fractured? The
   fixture is the read-test.
5. **Filesystem-walk vs barrel discovery.** Fixture uses filesystem. If listing
   facets becomes cumbersome at slice level, a barrel re-enters consideration.

## Fixture spec sketch

Three slices, asymmetric. Filesystem-walked: each `<facet>.nix` file's presence
at the slice root determines what facets the slice contributes. No barrel.

```
fixture/
├── flake.nix              # walker + per-facet rollups
├── lib/
│   └── walker.nix         # discoverSlices + per-facet routing
├── slices/
│   ├── slice-a/           # pkg + hm (no devenv, no own lib)
│   │   ├── package.nix    #   consumes slice-b.lib at eval time
│   │   └── hm.nix
│   ├── slice-b/           # lib-only (leaf dependency)
│   │   └── lib.nix
│   └── slice-c/           # full-spectrum: all 4 facets
│       ├── package.nix
│       ├── lib.nix
│       ├── hm.nix
│       └── devenv.nix
└── checks/
    └── structural.nix     # cross-slice dep resolves; lib namespace has no collisions
```

**Per-slice file shapes** (idiomatic, no project-specific wrapping):

- `package.nix` — `{lib, stdenv, ...}: stdenv.mkDerivation { ... }`
  (callPackage-style). Stub via `runCommand` or `writeText`; no real builds.
- `lib.nix` — `{lib, ...}: { someHelper = ...; }` (pure function returning
  attrset). Consumed via recursive merge.
- `hm.nix` —
  `{config, lib, pkgs, ...}: { options.fixture.<slice> = ...; config = mkIf ...; }`
  (standard NixOS module shape).
- `devenv.nix` — same shape as `hm.nix`, with devenv-side option locations.

**Asymmetry intent:**

- **slice-a** (pkg + hm): "subset of facets is allowed; missing facets do not
  break the rollup."
- **slice-b** (lib-only): leaf dependency consumed by another slice.
- **slice-c** (full-spectrum): worst-case slice exercising every facet.

**Cross-slice dependency:** `slice-a/package.nix` calls `slice-b.lib.someHelper`
(resolved via the rolled-up lib). This is the load-bearing test that lib
composition works across slices.

**Root structural checks (examples):**

- The cross-slice dep evaluates without error and produces a derivation.
- The `lib` rollup contains no name collisions across slices.
- Every `hm.nix` and `devenv.nix` declares its options under a predictable
  namespace (`fixture.<slice>.*`).

**Bar for "fixture is solid":**

- `nix flake check` passes.
- `nix eval .#lib --json` shows the merged lib shape across slices.
- `nix build .#packages.<system>.slice-a` succeeds and exercises the cross-slice
  lib dep.
- A reviewer can read `flake.nix` + `lib/walker.nix` + one slice in under five
  minutes and explain how composition works.

End-to-end consumer wiring (a real HM config or `devenv shell` consuming fixture
outputs) is **out of v0 scope**.
