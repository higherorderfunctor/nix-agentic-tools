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
    # unrelated overlays such as agnix.
    ai-clis = {
      scopes = [
        # The behavioral wrapper check belongs here for the same reason
        # `checks/kiro-wrapper-argv.nix` sits in `kiro-wrapper`: editing it
        # means reasoning about how Copilot discovers config, which is exactly
        # what `copilot-config-delivery` documents.
        "checks/copilot-wrapper-argv.nix"
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
      sources = ["copilot-config-delivery" "packaging-guide"];
    };
    # ai-config-scope: whether a devenv-delivered runtime reads the
    # developer's user-global config, and why every runtime answers "yes".
    # Scoped to the factories and wrappers that COULD redirect a config root,
    # plus devenv.nix where the runtimes are enabled. Deliberately NOT scoped
    # to `overlays/*` — an overlay packages a binary and never decides where
    # that binary looks for config.
    ai-config-scope = {
      scopes = [
        "devenv.nix"
        "packages/*/lib/mk*.nix"
        "packages/*/lib/wrapPackage.nix"
        "packages/*/modules/devenv/**"
      ];
      sources = ["host-config-merge"];
    };
    # ai-module: fanout semantics and per-CLI enable-as-sole-gate.
    # Post-factory, the fanout logic lives in each per-package factory
    # (packages/*/lib/mk*.nix + packages/*/modules/) and the shared
    # options barrel (lib/ai/sharedOptions.nix).
    ai-module = {
      scopes = [
        # Home of the provenance guard enforcing the root-write prohibition
        # (`rootPoolViolations`). Editing it without the fanout and collision
        # fragments loaded is how the rule gets "simplified" back out.
        "checks/module-eval.nix"
        "lib/ai/agent.nix"
        # Home of both merge helpers these fragments describe (`mergePool`,
        # `resolveOverride`) — previously
        # unscoped, so editing them loaded no guidance.
        "lib/ai/ai-common.nix"
        "lib/ai/app/**"
        "lib/ai/default.nix"
        "lib/ai/hooks.nix"
        # Lifecycle helper behind the manifest-guarded, enable-independent
        # migration exception documented by the fanout fragments.
        "lib/ai/materialize.nix"
        # The one factory that contributes to the pools from inside this repo,
        # so it is exactly where collision-semantics' "where a MODULE may
        # contribute" rule has to be read before editing. Previously unscoped.
        "lib/ai/mkSkillPackageModule.nix"
        # Portable program option-tree factory. Like `mkAiApp`, it declares
        # capability-gated runtime paths and resolves root/runtime values.
        "lib/ai/program.nix"
        # The runtime registry that file and sharedOptions.nix share.
        "lib/ai/runtimes.nix"
        # Final B7 static-file registry and generic backend lowering.
        "lib/ai/runtime-files.nix"
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
        "shell-option"
      ];
    };
    # ai-skills: uniform skill layout through native program options or shared
    # recursive helpers. Scoped to the runtime implementations, package factory
    # modules, and skill helper.
    ai-skills = {
      scopes = [
        "lib/ai/hm-helpers.nix"
        "lib/ai/mkSkillPackageModule.nix"
        "packages/chatgpt-codex/lib/mkCodex.nix"
        "packages/chatgpt-codex/modules/**"
        "packages/claude-code/lib/mkClaude.nix"
        "packages/claude-code/modules/**"
        "packages/copilot-cli/lib/mkCopilot.nix"
        "packages/copilot-cli/modules/**"
        "packages/kimchi/lib/mkKimchi.nix"
        "packages/kimchi/modules/**"
        "packages/kiro-cli/lib/mkKiro.nix"
        "packages/kiro-cli/modules/**"
        "packages/stacked-workflows/modules/**"
      ];
      sources = ["skills-fanout-pattern"];
    };
    # beads: the contained devenv lifecycle, serialized checkpoint protocol,
    # and sole raw-Dolt publication boundary.
    beads = {
      scopes = [
        "checks/beads-lifecycle.nix"
        "checks/module-eval.nix"
        "docs/beads/bd-reference.md"
        "docs/beads/dolt-git-remotes.md"
        "overlays/dev-tools/beads.nix"
        "packages/beads/**"
      ];
      sources = [
        {
          location = "package";
          name = "beads-lifecycle";
          dir = "beads";
        }
      ];
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
    # ifd: import-from-derivation eval cost and the warm-ifd composite that
    # pays it down. Split out of `overlays` because the fragment asserts a
    # same-commit update duty on paths `overlays/**` never matched — the
    # shared `.github/actions/warm-ifd/action.yml` composite and the warm
    # steps that consume it in ci.yml / devenv-test.yml / update.yml — five
    # call sites across three workflows. A fragment claiming
    # authority over a path it does not scope is unreachable from the very
    # edit it governs, and that is not hypothetical: PR #946 edited
    # warm-ifd/action.yml and loaded none of it. Scoping it here rather than
    # widening `overlays` keeps a ci.yml editor from being handed
    # unfree-guard and cache-hit-parity, which have nothing to say about CI.
    ifd = {
      scopes = [
        ".github/actions/warm-ifd/**"
        ".github/workflows/ci.yml"
        ".github/workflows/devenv-test.yml"
        ".github/workflows/update.yml"
        "overlays/*.nix"
        "overlays/**/*.nix"
      ];
      sources = [
        {
          name = "ifd-patterns";
          dir = "overlays";
        }
      ];
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
        "checks/kiro-fhs-contract.nix"
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
          name = "fhs-sandbox";
          dir = "kiro-cli";
        }
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
    # formatter choice, along with both prose scanners and the
    # `markdown-scan.nix` file set they share — the reflow this fragment
    # documents is what forces the doubled-word scan to look across a
    # newline, so the two cannot be reasoned about separately.
    markdown-formatting = {
      scopes = [
        "**/*.md"
        "checks/doubled-words-fixtures.nix"
        "checks/doubled-words-fixtures.py"
        "checks/doubled-words.nix"
        "checks/doubled-words.py"
        "checks/fixtures/doubled-words/**"
        "checks/markdown-scan.nix"
        "checks/markdown-scanners.nix"
        "checks/split-code-spans.nix"
        "checks/split-code-spans.py"
        "treefmt.nix"
      ];
      sources = ["markdown-formatting"];
    };
    # mcp-secrets: SOPS/agenix-injectable http MCP headers + url, the Kiro
    # `${env:VAR}` / activation-envsubst delivery, `mcpWriteMode`, and managed
    # proxy ownership/lowering. Scoped to the ownership and transform paths,
    # schema, shared renderer, proxy checks, Kiro secret preprocessor, and the
    # launcher wrapper that exports the decrypted values at runtime.
    mcp-secrets = {
      scopes = [
        "checks/factory-eval.nix"
        "checks/module-eval.nix"
        "lib/ai/app/mkBackendTransform.nix"
        "lib/ai/mcpProxy.nix"
        "lib/ai/mcpServer/**"
        "lib/ai/sharedOptions.nix"
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
    # mcp-services: managed HTTP service capability metadata, especially the
    # bind-address contract shared by native servers and the mcp-proxy bridge.
    mcp-services = {
      scopes = [
        "checks/factory-eval.nix"
        "checks/module-eval.nix"
        "lib/ai/mcpServer/mkServiceModule.nix"
        "lib/ai/mcpServer/serviceSchema.nix"
        "packages/*/modules/mcp-server.nix"
        "packages/mcp-services/modules/homeManager/default.nix"
      ];
      sources = ["service-host-contract"];
    };
    # monorepo: always-loaded orientation — no scoping.
    monorepo = {
      scopes = null;
      sources = [
        "architecture-fragments"
        "build-commands"
        "change-propagation"
        "delegate-sizing"
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
    # overlays: cache-hit parity, the overlay pattern, and the unfree guard.
    # Scoped to overlay package files under overlays/. IFD guidance is NOT
    # here any more — it moved to the `ifd` row above, which re-scopes these
    # same two globs plus the CI paths that warm the IFD cache, so an
    # overlays editor still gets it.
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
    # semble: program-factory integration, customization, cache ownership, and
    # the shared HM/devenv backend contract.
    semble = {
      scopes = ["packages/semble/**"];
      sources = [
        {
          location = "package";
          name = "semble";
          dir = "semble";
        }
      ];
    };
    stacked-workflows = {
      scopes = ["packages/stacked-workflows/**"];
      sources = [
        {
          location = "package";
          name = "development";
          dir = "stacked-workflows";
        }
      ];
    };
  };
}
