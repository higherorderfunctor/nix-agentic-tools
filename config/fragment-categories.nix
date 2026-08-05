# config/fragment-categories.nix — central config.fragments.categories
# contribution.
#
# Declares every fragment category's row: the `scopes` path globs its generated
# instruction file is scoped to, and the `sources` markdown fragments composed
# into it. Merged with lib/fragments-registry.nix (the option declaration) by
# lib.evalModules and read by dev/generate.nix — the single source of truth
# that replaced the two parallel category-keyed registries that used to live
# there (`packagePaths` for the globs, `devFragmentNames` for the sources).
#
# Order within a `scopes` list is load-bearing: the globs are emitted verbatim
# into the generated per-ecosystem frontmatter, so reordering them churns every
# generated instruction file. `scopes = null` means "always-loaded" (no
# scoping). Entries are sorted in BYTE order (LC_ALL=C) — what `lib.sort
# lib.lessThan` produces, and what the path filter in
# .github/workflows/devenv-test.yml uses (it lists `dev/generate.nix` before
# `devenv.lock`, which a locale-aware sort would flip). So
# `lib/fragments-registry.nix` correctly precedes `lib/fragments.nix`,
# because `-` (0x2D) sorts below `.` (0x2E). A locale-aware collation that
# ignores punctuation flips that pair; that is not the convention here, so do
# not "correct" it. Not every list here is sorted, though: `overlays` orders
# its globs by meaning, specific before recursive.
#
# A `sources` entry is either a bare string (shorthand for a fragment in
# dev/fragments/<category>/) or an attrset selecting a co-located fragment
# under packages/<dir>/docs/ or devshell/<dir>/docs/.
#
# Per-package co-location (each package carrying its own category row alongside
# its fragments) is deferred; for now add rows here.
_: {
  config.fragments.categories = {
    # ai-clis: how the AI coding-CLI binaries are packaged. The guide
    # documents six overlay files by name, so it is scoped to those six
    # explicitly. It used to lean on `packages/ai-clis/**`, a directory that
    # no longer exists — nothing else in this row covered those overlays, so
    # the glob was RE-POINTED at them rather than deleted. Do not collapse it
    # to `overlays/*.nix`: that would also load this AI-CLI-specific guide for
    # agnix and kiro-memory-distiller.
    ai-clis = {
      scopes = [
        "overlays/chatgpt-codex.nix"
        "overlays/claude-code.nix"
        "overlays/copilot-cli.nix"
        "overlays/kimchi.nix"
        "overlays/kiro-cli.nix"
        "overlays/kiro-gateway.nix"
        "packages/chatgpt-codex/**"
        "packages/copilot-cli/**"
        "packages/kiro-cli/**"
      ];
      sources = ["packaging-guide"];
    };
    # ai-module: fanout semantics and per-CLI enable-as-sole-gate.
    # Post-factory, the fanout logic lives in each per-package factory
    # (packages/*/lib/mk*.nix + packages/*/modules/) and the shared
    # options barrel (lib/ai/sharedOptions.nix).
    ai-module = {
      scopes = [
        "lib/ai/agent.nix"
        "lib/ai/app/**"
        "lib/ai/default.nix"
        "lib/ai/hooks.nix"
        "lib/ai/sharedOptions.nix"
        "packages/*/lib/mk*.nix"
        "packages/chatgpt-codex/modules/**"
        "packages/claude-code/modules/**"
        "packages/copilot-cli/modules/**"
        "packages/kiro-cli/modules/**"
      ];
      sources = [
        "ai-module-fanout"
        "collision-semantics"
        "dir-helpers"
        "layered-fanout"
      ];
    };
    # ai-skills: uniform delegation pattern (all branches go through
    # programs.<cli>.skills, no direct home.file). Scoped to the
    # per-package factory modules + the skill helper.
    ai-skills = {
      scopes = [
        "lib/ai/hm-helpers.nix"
        "packages/chatgpt-codex/modules/**"
        "packages/claude-code/modules/**"
        "packages/copilot-cli/modules/**"
        "packages/kiro-cli/modules/**"
      ];
      sources = ["skills-fanout-pattern"];
    };
    # claude-code: wrapper chain plus the heron_brook delegation-clamp
    # mitigation. Spans the claude-code overlay package and the
    # factory-built module.
    claude-code = {
      scopes = [
        "overlays/claude-code.nix"
        "packages/claude-code/**"
      ];
      sources = [
        {
          location = "package";
          name = "claude-code-wrapper";
          dir = "claude-code";
        }
        {
          location = "package";
          name = "heron-brook-clamp";
          dir = "claude-code";
        }
      ];
    };
    # devenv: devenv files.* internals + skills layout walker. Scoped
    # to per-package devenv modules and the helper file.
    devenv = {
      scopes = [
        ".github/workflows/devenv-test.yml"
        "devenv.nix"
        "lib/ai/hm-helpers.nix"
        "packages/*/modules/devenv/**"
      ];
      sources = ["ci-lean-closure" "files-internals"];
    };
    # flake: binary cache config + flake-level settings. Scoped to
    # files that touch nixConfig or cachix settings so consumers
    # editing their flake inputs get the rule, and consumers
    # editing ai modules don't.
    flake = {
      scopes = [
        "flake.nix"
        "devenv.nix"
      ];
      sources = ["binary-cache"];
    };
    # hm-modules: cross-cutting module conventions. Scoped to every
    # HM module file so conventions load whenever a contributor is
    # touching any module. Post-factory, HM modules live in
    # packages/*/modules/homeManager/.
    hm-modules = {
      scopes = [
        "packages/*/modules/homeManager/**"
      ];
      sources = ["module-conventions"];
    };
    # kimchi: two-tree factory (config.json + harness/), runtime SOPS
    # credential, wrapProgram separator + flattenDotKeys gotchas.
    kimchi = {
      scopes = [
        "packages/kimchi/**"
      ];
      sources = [
        {
          location = "package";
          name = "kimchi-factory";
          dir = "kimchi";
        }
      ];
    };
    # kiro-cli: auto-memory system (distiller pipeline, v3 hook set,
    # buffer/archive tiers, the openmemory-mem backend seam). Scoped to the
    # kiro-cli package, the distiller overlay, and the backend helper source.
    kiro-cli = {
      scopes = [
        "overlays/kiro-memory-distiller.nix"
        "overlays/kiro-memory-distiller/**"
        "overlays/mcp-servers/openmemory-mem/**"
        "packages/kiro-cli/**"
      ];
      sources = [
        {
          location = "package";
          name = "kiro-auto-memory";
          dir = "kiro-cli";
        }
      ];
    };
    # kiro-wrapper: the argv contract of the generated kiro-cli launcher /
    # chat wrappers — which subcommands accept `--tui`/`--v3`/`--trust-tools`,
    # why the appends are gated rather than unconditional, and how to
    # re-measure on a version bump. Kept OUT of the `kiro-cli` category (whose
    # fragment is the ~300-line auto-memory map) so an edit to the wrapper
    # loads the wrapper rule, not the memory pipeline. Scoped to the generic
    # shell helper, the factory's lib/ directory that consumes it, and the
    # behavioral check, since all three have to move together.
    kiro-wrapper = {
      scopes = [
        "checks/kiro-wrapper-argv.nix"
        "lib/idempotentFlags.nix"
        # The overlay's wrapProgram calls carry the darwin argv0
        # bundle-discovery fix, which is part of this argv contract.
        "overlays/kiro-cli.nix"
        "packages/kiro-cli/lib/**"
      ];
      sources = [
        {
          location = "package";
          name = "launcher-argv";
          dir = "kiro-cli";
        }
      ];
    };
    # markdown-formatting: treefmt owns markdown wrapping, and the one
    # markdown defect here that NO check can catch (a line broken
    # mid-token). Scoped broadly to `**/*.md` on purpose — since the
    # defect is not lintable, reaching the author before they write is
    # the only real control, so this has to load on any markdown edit
    # rather than only when the formatter config is touched. The config
    # paths are listed too, for whoever reconsiders `proseWrap` or the
    # formatter choice.
    markdown-formatting = {
      scopes = [
        "**/*.md"
        "checks/split-code-spans.nix"
        "checks/split-code-spans.py"
        "treefmt.nix"
      ];
      sources = ["markdown-formatting"];
    };
    # mcp-secrets: SOPS/agenix-injectable http MCP headers + url, the Kiro
    # `${env:VAR}` / activation-envsubst delivery, and `mcpWriteMode`. Scoped to
    # the schema, the shared renderer, the Kiro secret preprocessor, and the
    # launcher wrapper that exports the decrypted values at runtime.
    mcp-secrets = {
      scopes = [
        "lib/ai/mcpServer/**"
        "lib/mcp.nix"
        "packages/kiro-cli/lib/mcpSecrets.nix"
        "packages/kiro-cli/lib/mkKiro.nix"
        "packages/kiro-cli/lib/wrapPackage.nix"
      ];
      sources = ["mcp-secrets"];
    };
    mcp-servers = {
      scopes = [
        "overlays/mcp-servers/**"
      ];
      sources = [
        "js-server-packaging"
        "overlay-guide"
      ];
    };
    # monorepo: always-loaded orientation — no scoping.
    monorepo = {
      scopes = null;
      sources = [
        "architecture-fragments"
        "build-commands"
        "change-propagation"
        "git-workflow"
        "linting"
        "project-overview"
      ];
    };
    # nix-standards: broad Nix code conventions. Applies to any
    # .nix file in the tree.
    nix-standards = {
      scopes = ["**/*.nix"];
      sources = ["nix-standards"];
    };
    # overlays: cache-hit parity + IFD patterns. Scoped to overlay
    # package files and overlays/ (version helpers that trigger IFD).
    # Excludes content-only fragments dirs, and deliberately does NOT scope
    # `packages/*/overlay.nix` (stacked-workflows) — those are content
    # overlays with no `ourPkgs` seam. Three globs
    # (`packages/{ai-clis,git-tools,mcp-servers}/*.nix`) were dropped here:
    # all three directories are gone, and every file they aimed at now lives
    # under `overlays/`, covered by the two globs below.
    overlays = {
      scopes = [
        "overlays/*.nix"
        "overlays/**/*.nix"
      ];
      sources = [
        "cache-hit-parity"
        "ifd-patterns"
        "overlay-pattern"
        "unfree-guard"
      ];
    };
    # packaging: naming conventions + platform handling for overlay
    # packages. Scoped to the packages tree plus config/update-targets.nix.
    packaging = {
      scopes = [
        "config/update-targets.nix"
        "packages/**/*.nix"
      ];
      sources = [
        "naming-conventions"
        "platforms"
      ];
    };
    # pipeline: fragment composition, ecosystem transforms, update
    # pipeline, and CI workflow. Scoped to every file in the dev
    # fragment chain, update scripts, CI workflow, ninja DAG
    # generation, and both registries — config.fragments.categories
    # (this file + lib/fragments-registry.nix) and
    # config.update.targets.
    pipeline = {
      scopes = [
        ".github/workflows/update.yml"
        "config/fragment-categories.nix"
        "config/generate-update-ninja.nix"
        "config/update-targets.nix"
        "dev/generate.nix"
        "dev/scripts/update-*.sh"
        "dev/tasks/generate.nix"
        "lib/ai/transformers/**"
        "lib/fragments-registry.nix"
        "lib/fragments.nix"
        "lib/update.nix"
        "overlays/**/*.update.nix"
      ];
      sources = [
        "ci-update-workflow"
        "fragment-pipeline"
        "generation-architecture"
        "update-pipeline"
      ];
    };
    stacked-workflows = {
      scopes = ["packages/stacked-workflows/**"];
      sources = ["development"];
    };
  };
}
