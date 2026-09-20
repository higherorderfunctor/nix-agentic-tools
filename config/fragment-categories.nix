# config/fragment-categories.nix — central config.fragments.categories
# contribution.
#
# Declares shared/workspace categories. Owner-specific category rows live in
# packages/<owner>/registry.nix. lib/facets/registry.nix evaluates both through
# the options in lib/fragments-registry.nix; dev/generate.nix reads that result.
# Each row pairs scope globs with the markdown sources composed into it.
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
# Put package-specific rows beside their owner; keep cross-owner policy here.
_: {
  config.fragments.categories = {
    # Shared packaging guidance covers the AI CLI owners and their recipes.
    ai-clis = {
      scopes = [
        # The behavioral wrapper check belongs here for the same reason
        # `packages/kiro-cli/checks/kiro-wrapper-argv.nix` sits in `kiro-wrapper`: editing it
        # means reasoning about how Copilot discovers config, which is exactly
        # what `copilot-config-delivery` documents.
        "packages/copilot-cli/checks/copilot-wrapper-argv.nix"
        "packages/chatgpt-codex/packages/ai/chatgpt-codex/package.nix"
        "packages/claude-code/packages/ai/claude-code/package.nix"
        "packages/copilot-cli/packages/ai/copilot-cli/package.nix"
        "packages/kimchi/packages/ai/kimchi/package.nix"
        "packages/kiro-cli/packages/ai/kiro-cli/package.nix"
        "packages/kiro-gateway/packages/ai/kiro-gateway/package.nix"
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
    # to package recipes under `packages/*/packages/**` — a recipe packages a
    # binary and never decides where that binary looks for config.
    ai-config-scope = {
      scopes = [
        "devenv.nix"
        # The five AI CLI factories, listed explicitly. `packages/*/lib/mk*.nix`
        # used to stand here and matched 24 files — every MCP server factory,
        # glab, beads and semble included — so editing an unrelated `mk*.nix`
        # pulled this whole category for nothing.
        "packages/chatgpt-codex/lib/mkCodex.nix"
        "packages/claude-code/lib/mkClaude.nix"
        "packages/copilot-cli/lib/mkCopilot.nix"
        "packages/kimchi/lib/mkKimchi.nix"
        "packages/kiro-cli/lib/mkKiro.nix"
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
        "checks/*/module-eval.nix"
        "checks/ai-delivery/**"
        "checks/module-provenance/**"
        # The matrix's pure readers and live generator share the layer's
        # default-directory and independent-probe contracts.
        "config/ai-delivery*.nix"
        # The two backend adapters: the only code allowed to write the four
        # native sink paths, and the far end of every fanout these fragments
        # describe.
        "lib/ai/adapters/**"
        "lib/ai/agent.nix"
        # Home of both merge helpers these fragments describe (`mergePool`,
        # `resolveOverride`) — previously
        # unscoped, so editing them loaded no guidance.
        "lib/ai/ai-common.nix"
        "lib/ai/app/**"
        "lib/ai/default.nix"
        # The delivery layer: the router both adapters lower through, and the
        # option schema a runtime describes its files and writers with.
        "lib/ai/deliver.nix"
        "lib/ai/delivery-options.nix"
        "lib/ai/deliveryMethod.nix"
        "lib/ai/formats.nix"
        "lib/ai/hooks.nix"
        # The one factory that contributes to the pools from inside this repo,
        # so it is exactly where collision-semantics' "where a MODULE may
        # contribute" rule has to be read before editing. Previously unscoped.
        "lib/ai/mkSkillPackageModule.nix"
        # The reconciler behind the ledger-guarded, enable-independent
        # migration exception documented by the fanout fragments.
        "lib/ai/own.nix"
        "lib/ai/own.py"
        # Portable program option-tree factory. Like `mkAiApp`, it declares
        # capability-gated runtime paths and resolves root/runtime values.
        "lib/ai/program.nix"
        # Final B7 static-file registry and generic backend lowering.
        "lib/ai/runtime-files.nix"
        # The runtime registry that file and sharedOptions.nix share.
        "lib/ai/runtimes.nix"
        "lib/ai/sharedOptions.nix"
        "lib/testing/module-harness.nix"
        "packages/*/checks/module-eval.nix"
        # The five AI CLI factories, listed explicitly. `packages/*/lib/mk*.nix`
        # used to stand here and matched 24 files — every MCP server factory,
        # glab, beads and semble included — so editing an unrelated `mk*.nix`
        # pulled this whole category for nothing.
        "packages/chatgpt-codex/lib/mkCodex.nix"
        "packages/chatgpt-codex/modules/**"
        "packages/claude-code/lib/mkClaude.nix"
        "packages/claude-code/modules/**"
        "packages/copilot-cli/lib/mkCopilot.nix"
        "packages/copilot-cli/modules/**"
        "packages/delegate-sizing/modules/**"
        "packages/kimchi/lib/mkKimchi.nix"
        "packages/kiro-cli/lib/mkKiro.nix"
        "packages/kiro-cli/modules/**"
        # `ai-module-fanout.md` discusses this file as the repo's only
        # `mkProgram` consumer; the retired glob caught `lib/mkSemble.nix`
        # instead, which is a 37-line MCP defaults record.
        "packages/semble/modules/common.nix"
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
        "packages/delegate-sizing/modules/**"
        "packages/kimchi/lib/mkKimchi.nix"
        "packages/kimchi/modules/**"
        "packages/kiro-cli/lib/mkKiro.nix"
        "packages/kiro-cli/modules/**"
        "packages/stacked-workflows/modules/**"
      ];
      sources = ["skills-fanout-pattern"];
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
    facets = {
      scopes = [
        "checks/*/default.nix"
        "checks/facets/**"
        "flake.nix"
        "lib/facets.nix"
        "lib/facets/**"
        "lib/testing/**"
        "packages/*/checks.nix"
        "packages/*/packages/**"
        "packages/*/registry.nix"
      ];
      sources = ["package-ownership"];
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
        "lib/facets/**"
        "lib/testing/**"
        "lib/packaging.nix"
        "packages/*/lib/packaging.nix"
        "packages/*/packages/**/*.nix"
        "packages/*/packages/**"
      ];
      sources = [
        {
          name = "ifd-patterns";
          dir = "overlays";
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
        "checks/markdown/doubled-words-fixtures.nix"
        "checks/markdown/doubled-words-fixtures.py"
        "checks/markdown/doubled-words.nix"
        "checks/markdown/doubled-words.py"
        "checks/markdown/fixtures/doubled-words/**"
        "checks/markdown/markdown-scan.nix"
        "checks/markdown/markdown-scanners.nix"
        "checks/markdown/split-code-spans.nix"
        "checks/markdown/split-code-spans.py"
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
        "checks/*/factory-eval.nix"
        "checks/*/module-eval.nix"
        "lib/ai/app/mkBackendTransform.nix"
        "lib/ai/mcpProxy.nix"
        "lib/ai/mcpServer/**"
        "lib/ai/sharedOptions.nix"
        "lib/mcp.nix"
        "lib/testing/factory-harness.nix"
        "lib/testing/module-harness.nix"
        "packages/*/checks/factory-eval.nix"
        "packages/*/checks/module-eval.nix"
        "packages/kiro-cli/lib/mcpSecrets.nix"
        "packages/kiro-cli/lib/mkKiro.nix"
        "packages/kiro-cli/lib/wrapPackage.nix"
      ];
      sources = ["mcp-secrets"];
    };
    mcp-servers = {
      scopes = [
        "packages/*/packages/ai/mcpServers/**"
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
        "checks/*/factory-eval.nix"
        "checks/*/module-eval.nix"
        "lib/ai/mcpServer/mkServiceModule.nix"
        "lib/ai/mcpServer/serviceSchema.nix"
        "lib/testing/factory-harness.nix"
        "lib/testing/module-harness.nix"
        "packages/*/checks/factory-eval.nix"
        "packages/*/checks/module-eval.nix"
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
        "git-workflow"
        "linting"
        "peer-communication"
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
    # Scoped to package recipe files under `packages/*/packages/**`. IFD
    # guidance is NOT
    # here any more — it moved to the `ifd` row above, which re-scopes these
    # same two globs plus the CI paths that warm the IFD cache, so an
    # recipe editor still gets it.
    # Excludes content-only fragments dirs. The old exclusion for
    # `packages/*/overlay.nix` (stacked-workflows) is dropped: that file no
    # longer exists — its content derivation is now
    # `packages/stacked-workflows/packages/stacked-workflows-content/package.nix`.
    # Three globs
    # (`packages/{ai-clis,git-tools,mcp-servers}/*.nix`) were dropped here:
    # all three directories are gone, and every file they aimed at now lives
    # under `packages/<owner>/packages/**`, covered by the two globs below.
    overlays = {
      scopes = [
        "lib/facets/**"
        "lib/testing/**"
        "lib/packaging.nix"
        "packages/*/lib/packaging.nix"
        "packages/*/packages/**/*.nix"
        "packages/*/packages/**"
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
        ".github/actions/warm-ifd/**"
        ".github/workflows/ci.yml"
        ".github/workflows/update.yml"
        "config/fragment-categories.nix"
        "config/generate-update-ninja.nix"
        "config/update-targets.nix"
        "dev/generate.nix"
        "dev/scripts/ci-*.py"
        "dev/scripts/test-ci-*.py"
        "dev/scripts/test-update-*.py"
        "dev/scripts/update-*.py"
        "dev/scripts/update-*.sh"
        "dev/tasks/generate.nix"
        "lib/ai/transformers/**"
        "lib/fragments-registry.nix"
        "lib/fragments.nix"
        "lib/update.nix"
        "packages/*/registry.nix"
      ];
      sources = [
        "ci-update-workflow"
        "fragment-pipeline"
        "generation-architecture"
        "update-pipeline"
      ];
    };
  };
}
