## Path-scoped rules

Before editing a path that matches an entry below, read every document listed
for it. When several entries match, their guidance composes.

This fallback index applies only to: `codex`, `kimchi`. Runtimes with native
rule injection already receive their applicable rules; do not follow this
fallback index to load additional guidance. If your runtime is not named, skip
this index.

- **`ai-clis`**
  - Match:
    - `packages/chatgpt-codex/packages/ai/chatgpt-codex/package.nix`
    - `packages/claude-code/packages/ai/claude-code/package.nix`
    - `packages/copilot-cli/packages/ai/copilot-cli/package.nix`
    - `packages/kimchi/packages/ai/kimchi/package.nix`
    - `packages/kiro-cli/packages/ai/kiro-cli/package.nix`
    - `packages/kiro-gateway/packages/ai/kiro-gateway/package.nix`
    - `packages/chatgpt-codex/**`
    - `packages/copilot-cli/**`
    - `packages/kiro-cli/**`
  - Read:
    - [`dev/fragments/ai-clis/copilot-config-delivery.md`](dev/fragments/ai-clis/copilot-config-delivery.md)
    - [`dev/fragments/ai-clis/packaging-guide.md`](dev/fragments/ai-clis/packaging-guide.md)
- **`ai-config-scope`**
  - Match:
    - `dev/ai.nix`
    - `devenv.nix`
    - `packages/chatgpt-codex/lib/mkCodex.nix`
    - `packages/claude-code/lib/mkClaude.nix`
    - `packages/copilot-cli/lib/mkCopilot.nix`
    - `packages/kimchi/lib/mkKimchi.nix`
    - `packages/kiro-cli/lib/mkKiro.nix`
    - `packages/*/modules/devenv/**`
  - Read:
    - [`dev/fragments/ai-config-scope/host-config-merge.md`](dev/fragments/ai-config-scope/host-config-merge.md)
- **`ai-module-contract`**
  - Match:
    - `.github/workflows/devenv-test.yml`
    - `checks/*/module-eval.nix`
    - `checks/module-provenance/**`
    - `config/ai-delivery*.nix`
    - `devenv.nix`
    - `lib/ai/agent.nix`
    - `lib/ai/ai-common.nix`
    - `lib/ai/app/**`
    - `lib/ai/default.nix`
    - `lib/ai/hm-helpers.nix`
    - `lib/ai/hooks.nix`
    - `lib/ai/launcher.nix`
    - `lib/ai/mkSkillPackageModule.nix`
    - `lib/ai/program.nix`
    - `lib/ai/runtimes.nix`
    - `lib/ai/sharedOptions.nix`
    - `lib/generated-guard.py`
    - `lib/generated.nix`
    - `lib/markdown/**`
    - `lib/testing/module-harness.nix`
    - `packages/*/checks/module-eval.nix`
    - `packages/*/modules/devenv/**`
    - `packages/*/modules/homeManager/**`
    - `packages/ai-module/**`
    - `packages/chatgpt-codex/lib/mkCodex.nix`
    - `packages/chatgpt-codex/modules/**`
    - `packages/claude-code/lib/mkClaude.nix`
    - `packages/claude-code/modules/**`
    - `packages/copilot-cli/lib/mkCopilot.nix`
    - `packages/copilot-cli/modules/**`
    - `packages/delegate-routing/modules/**`
    - `packages/kimchi/lib/mkKimchi.nix`
    - `packages/kiro-cli/lib/mkKiro.nix`
    - `packages/kiro-cli/modules/**`
    - `packages/semble/modules/common.nix`
  - Read:
    - [`packages/ai-module/docs/contract.md`](packages/ai-module/docs/contract.md)
- **`ai-skills`**
  - Match:
    - `lib/ai/hm-helpers.nix`
    - `lib/ai/mkSkillPackageModule.nix`
    - `packages/chatgpt-codex/lib/mkCodex.nix`
    - `packages/chatgpt-codex/modules/**`
    - `packages/claude-code/lib/mkClaude.nix`
    - `packages/claude-code/modules/**`
    - `packages/copilot-cli/lib/mkCopilot.nix`
    - `packages/copilot-cli/modules/**`
    - `packages/delegate-routing/modules/**`
    - `packages/kimchi/lib/mkKimchi.nix`
    - `packages/kimchi/modules/**`
    - `packages/kiro-cli/lib/mkKiro.nix`
    - `packages/kiro-cli/modules/**`
    - `packages/peer-communication/modules/**`
    - `packages/stacked-workflows/modules/**`
  - Read:
    - [`dev/fragments/ai-skills/skills-fanout-pattern.md`](dev/fragments/ai-skills/skills-fanout-pattern.md)
- **`airlock`**
  - Match:
    - `packages/airlock/**`
  - Read:
    - [`packages/airlock/docs/airlock.md`](packages/airlock/docs/airlock.md)
- **`beads`**
  - Match:
    - `packages/beads/**`
  - Read:
    - [`packages/beads/docs/beads-lifecycle.md`](packages/beads/docs/beads-lifecycle.md)
- **`claude-code`**
  - Match:
    - `packages/claude-code/packages/ai/claude-code/package.nix`
    - `packages/claude-code/**`
  - Read:
    - [`packages/claude-code/docs/claude-code-wrapper.md`](packages/claude-code/docs/claude-code-wrapper.md)
    - [`packages/claude-code/docs/heron-brook-clamp.md`](packages/claude-code/docs/heron-brook-clamp.md)
- **`cliproxyapi`**
  - Match:
    - `packages/cliproxyapi/**`
  - Read:
    - [`packages/cliproxyapi/docs/cliproxyapi-extraction.md`](packages/cliproxyapi/docs/cliproxyapi-extraction.md)
    - [`packages/cliproxyapi/docs/cliproxyapi-key-allowlist.md`](packages/cliproxyapi/docs/cliproxyapi-key-allowlist.md)
    - [`packages/cliproxyapi/docs/cliproxyapi-settings.md`](packages/cliproxyapi/docs/cliproxyapi-settings.md)
- **`codeql`**
  - Match:
    - `packages/codeql/**`
  - Read:
    - [`packages/codeql/docs/codeql.md`](packages/codeql/docs/codeql.md)
    - [`packages/codeql/docs/customize.md`](packages/codeql/docs/customize.md)
- **`codex-daemon`**
  - Match:
    - `packages/chatgpt-codex/**`
  - Read:
    - [`packages/chatgpt-codex/docs/codex-daemon.md`](packages/chatgpt-codex/docs/codex-daemon.md)
- **`cpa-manager-plus`**
  - Match:
    - `packages/cpa-manager-plus/**`
  - Read:
    - [`packages/cpa-manager-plus/docs/cpa-manager-plus-extraction.md`](packages/cpa-manager-plus/docs/cpa-manager-plus-extraction.md)
    - [`packages/cpa-manager-plus/docs/cpa-manager-plus-settings.md`](packages/cpa-manager-plus/docs/cpa-manager-plus-settings.md)
- **`delegate-routing`**
  - Match:
    - `packages/delegate-routing/**`
  - Read:
    - [`packages/delegate-routing/docs/development.md`](packages/delegate-routing/docs/development.md)
- **`dev/fragments/ai-module`**
  - Match:
    - `checks/*/module-eval.nix`
    - `checks/ai-context/module-eval.nix`
    - `checks/ai-factory/factory-eval.nix`
    - `checks/module-provenance/**`
    - `config/ai-delivery*.nix`
    - `lib/ai/agent.nix`
    - `lib/ai/ai-common.nix`
    - `lib/ai/app/**`
    - `lib/ai/default.nix`
    - `lib/ai/dir-helpers.nix`
    - `lib/ai/hooks.nix`
    - `lib/ai/launcher.nix`
    - `lib/ai/mkSkillPackageModule.nix`
    - `lib/ai/program.nix`
    - `lib/ai/runtimes.nix`
    - `lib/ai/sharedOptions.nix`
    - `lib/generated-guard.py`
    - `lib/generated.nix`
    - `lib/markdown/**`
    - `lib/testing/module-harness.nix`
    - `packages/*/checks/module-eval.nix`
    - `packages/ai-module/**`
    - `packages/chatgpt-codex/checks/module-eval.nix`
    - `packages/chatgpt-codex/lib/mkCodex.nix`
    - `packages/chatgpt-codex/modules/**`
    - `packages/claude-code/checks/module-eval.nix`
    - `packages/claude-code/lib/mkClaude.nix`
    - `packages/claude-code/modules/**`
    - `packages/copilot-cli/checks/module-eval.nix`
    - `packages/copilot-cli/lib/mkCopilot.nix`
    - `packages/copilot-cli/modules/**`
    - `packages/delegate-routing/modules/**`
    - `packages/kimchi/checks/module-eval.nix`
    - `packages/kimchi/lib/mkKimchi.nix`
    - `packages/kiro-cli/checks/module-eval.nix`
    - `packages/kiro-cli/lib/mkKiro.nix`
    - `packages/kiro-cli/modules/**`
    - `packages/semble/modules/common.nix`
  - Read:
    - [`AGENTS.md.rules/7783e19f85259a8f9ae98a7ca89792066a7101688f9945bc27a87ca2c6517f6c.md`](AGENTS.md.rules/7783e19f85259a8f9ae98a7ca89792066a7101688f9945bc27a87ca2c6517f6c.md)
- **`dev/fragments/ai-proxy`**
  - Match:
    - `checks/ai-proxy/**`
    - `lib/ai/proxy/**`
    - `packages/chatgpt-codex/checks/chatgpt-codex-proxy.nix`
    - `packages/chatgpt-codex/checks/proxy-test.py`
    - `packages/chatgpt-codex/lib/proxy.nix`
    - `packages/claude-code/checks/claude-proxy.nix`
    - `packages/claude-code/lib/proxy.nix`
  - Read:
    - [`AGENTS.md.rules/5a70e8a2a50fb97e8c092d25292c2142bf9d010880956be85ce1bf334c2a6d54.md`](AGENTS.md.rules/5a70e8a2a50fb97e8c092d25292c2142bf9d010880956be85ce1bf334c2a6d54.md)
- **`dev/fragments/overlays`**
  - Match:
    - `.github/actions/warm-ifd/**`
    - `.github/workflows/ci.yml`
    - `.github/workflows/devenv-test.yml`
    - `.github/workflows/update.yml`
    - `lib/facets/**`
    - `lib/packaging.nix`
    - `lib/testing/**`
    - `lib/toolchains.nix`
    - `packages/*/lib/packaging.nix`
    - `packages/*/packages/**`
    - `packages/*/packages/**/*.nix`
    - `packages/*/patches/**`
  - Read:
    - [`AGENTS.md.rules/25581e95421380b923246a11efb2dde817edd1180385a851b81116183db4e8bf.md`](AGENTS.md.rules/25581e95421380b923246a11efb2dde817edd1180385a851b81116183db4e8bf.md)
- **`devenv`**
  - Match:
    - `.github/workflows/devenv-test.yml`
    - `devenv.nix`
    - `lib/ai/hm-helpers.nix`
    - `packages/*/modules/devenv/**`
  - Read:
    - [`dev/fragments/devenv/ci-lean-closure.md`](dev/fragments/devenv/ci-lean-closure.md)
    - [`dev/fragments/devenv/files-internals.md`](dev/fragments/devenv/files-internals.md)
- **`extracted`**
  - Match:
    - `checks/extracted/**`
    - `lib/extracted/**`
    - `lib/git-tool-settings/**`
    - `packages/*/extract/**`
    - `packages/*/extracted/**`
    - `packages/chatgpt-codex/lib/**`
    - `packages/claude-code/lib/**`
    - `packages/cliproxyapi/lib/**`
    - `packages/cpa-manager-plus/lib/**`
    - `packages/delegate-routing/probes/**`
    - `packages/git-absorb/lib/**`
    - `packages/git-branchless/lib/**`
    - `packages/git-revise/lib/**`
    - `packages/glab/lib/**`
    - `packages/kimchi/lib/**`
    - `packages/kiro-cli/lib/**`
    - `packages/semble/lib/**`
  - Read:
    - [`dev/fragments/extracted/extraction-method.md`](dev/fragments/extracted/extraction-method.md)
    - [`dev/fragments/extracted/facts-architecture.md`](dev/fragments/extracted/facts-architecture.md)
    - [`dev/fragments/extracted/facts-contract.md`](dev/fragments/extracted/facts-contract.md)
    - [`dev/fragments/extracted/typed-settings.md`](dev/fragments/extracted/typed-settings.md)
- **`facets`**
  - Match:
    - `checks/**`
    - `flake.nix`
    - `lib/facets.nix`
    - `lib/facets/**`
    - `lib/testing/**`
    - `packages/*/checks.nix`
    - `packages/*/checks/**`
    - `packages/*/packages/**`
    - `packages/*/registry.nix`
  - Read:
    - [`dev/fragments/facets/package-ownership.md`](dev/fragments/facets/package-ownership.md)
- **`flake`**
  - Match:
    - `.github/actions/check-cache/**`
    - `.github/workflows/hestia-gc.yml`
    - `flake.nix`
    - `devenv.nix`
  - Read:
    - [`dev/fragments/flake/binary-cache.md`](dev/fragments/flake/binary-cache.md)
- **`git`**
  - Match:
    - `checks/git-config/**`
    - `lib/git-tool-settings/ini-type.nix`
    - `lib/git-tool-settings/repo-config.nix`
    - `lib/git-tool-settings/repo-config.sh`
    - `lib/git-tool-settings/tool-module.nix`
    - `packages/git-absorb/modules/**`
    - `packages/git-branchless/modules/**`
    - `packages/git-revise/modules/**`
    - `packages/git/**`
    - `packages/stacked-workflows/modules/**`
  - Read:
    - [`packages/git/docs/git.md`](packages/git/docs/git.md)
- **`git-branchless`**
  - Match:
    - `packages/git-branchless/**`
  - Read:
    - [`packages/git-branchless/docs/extraction.md`](packages/git-branchless/docs/extraction.md)
- **`git-tool-settings`**
  - Match:
    - `checks/git-tool-settings/**`
    - `lib/git-tool-settings/**`
    - `packages/git-absorb/**`
    - `packages/git-branchless/**`
    - `packages/git-revise/**`
  - Read:
    - [`dev/fragments/git-tool-settings/git-tool-settings.md`](dev/fragments/git-tool-settings/git-tool-settings.md)
- **`hm-modules`**
  - Match:
    - `packages/*/modules/homeManager/**`
  - Read:
    - [`dev/fragments/hm-modules/module-conventions.md`](dev/fragments/hm-modules/module-conventions.md)
- **`jail-nix`**
  - Match:
    - `checks/ai-jail/**`
    - `lib/ai/jail/**`
    - `packages/jail-nix/**`
  - Read:
    - [`packages/jail-nix/docs/jail-nix.md`](packages/jail-nix/docs/jail-nix.md)
- **`kiro-model-catalog`**
  - Match:
    - `dev/tasks/check.nix`
    - `packages/kiro-cli/checks/module-eval.nix`
    - `packages/kiro-cli/lib/mkKiro.nix`
    - `packages/kiro-model-catalog/**`
  - Read:
    - [`packages/kiro-model-catalog/docs/model-catalog.md`](packages/kiro-model-catalog/docs/model-catalog.md)
- **`markdown-formatting`**
  - Match:
    - `**/*.md`
    - `checks/markdown/doubled-words-fixtures.nix`
    - `checks/markdown/doubled-words-fixtures.py`
    - `checks/markdown/doubled-words.nix`
    - `checks/markdown/doubled-words.py`
    - `checks/markdown/fixtures/doubled-words/**`
    - `checks/markdown/fixtures/guards-consumer/**`
    - `checks/markdown/generated-files.nix`
    - `checks/markdown/guards-consumer.nix`
    - `checks/markdown/markdown-scan.nix`
    - `checks/markdown/markdown-scanners.nix`
    - `checks/markdown/split-code-spans.nix`
    - `lib/generated.nix`
    - `lib/generated-guard.py`
    - `lib/markdown/**`
    - `lib/treefmt-module.nix`
    - `treefmt.nix`
  - Read:
    - [`dev/fragments/markdown-formatting/markdown-formatting.md`](dev/fragments/markdown-formatting/markdown-formatting.md)
- **`mcp-secrets`**
  - Match:
    - `checks/*/factory-eval.nix`
    - `checks/*/module-eval.nix`
    - `lib/ai/app/mkBackendTransform.nix`
    - `lib/ai/caddy.nix`
    - `lib/ai/mcpProxy.nix`
    - `lib/ai/mcpServer/**`
    - `lib/ai/sharedOptions.nix`
    - `lib/mcp.nix`
    - `lib/testing/factory-harness.nix`
    - `lib/testing/module-harness.nix`
    - `packages/*/checks/factory-eval.nix`
    - `packages/*/checks/module-eval.nix`
    - `packages/kiro-cli/lib/mcpSecrets.nix`
    - `packages/kiro-cli/lib/mkKiro.nix`
    - `packages/kiro-cli/lib/wrapPackage.nix`
    - `packages/slack-mcp/modules/mcp-server.nix`
  - Read:
    - [`dev/fragments/mcp-secrets/mcp-secrets.md`](dev/fragments/mcp-secrets/mcp-secrets.md)
- **`mcp-servers`**
  - Match:
    - `packages/*/packages/ai/mcpServers/**`
  - Read:
    - [`dev/fragments/mcp-servers/js-server-packaging.md`](dev/fragments/mcp-servers/js-server-packaging.md)
    - [`dev/fragments/mcp-servers/overlay-guide.md`](dev/fragments/mcp-servers/overlay-guide.md)
- **`mcp-services`**
  - Match:
    - `checks/*/factory-eval.nix`
    - `checks/*/module-eval.nix`
    - `lib/ai/mcpServer/mkServiceModule.nix`
    - `lib/ai/mcpServer/serviceSchema.nix`
    - `lib/testing/factory-harness.nix`
    - `lib/testing/module-harness.nix`
    - `packages/*/checks/factory-eval.nix`
    - `packages/*/checks/module-eval.nix`
    - `packages/*/modules/mcp-server.nix`
    - `packages/mcp-services/modules/homeManager/default.nix`
  - Read:
    - [`dev/fragments/mcp-services/service-host-contract.md`](dev/fragments/mcp-services/service-host-contract.md)
- **`microvm`**
  - Match:
    - `packages/microvm/**`
  - Read:
    - [`packages/microvm/docs/sandbox.md`](packages/microvm/docs/sandbox.md)
- **`nix-standards`**
  - Match:
    - `**/*.nix`
  - Read:
    - [`dev/fragments/nix-standards/nix-standards.md`](dev/fragments/nix-standards/nix-standards.md)
- **`open-keys`**
  - Match:
    - `checks/open-keys/**`
    - `lib/open-keys/**`
    - `lib/redact/classify.nix`
    - `packages/chatgpt-codex/lib/mkCodex.nix`
    - `packages/claude-code/lib/mkClaude.nix`
    - `packages/kiro-cli/lib/mkKiro.nix`
  - Read:
    - [`dev/fragments/open-keys/open-keys.md`](dev/fragments/open-keys/open-keys.md)
- **`packages/kimchi/docs`**
  - Match:
    - `checks/references/kimchi-egress-report.nix`
    - `dev/skills/kimchi-egress-report/**`
    - `packages/kimchi/**`
  - Read:
    - [`AGENTS.md.rules/a2567642799f79c918dee2ed1bd1fd6a01bbec44b6c56afa61fbf9ab787f54b9.md`](AGENTS.md.rules/a2567642799f79c918dee2ed1bd1fd6a01bbec44b6c56afa61fbf9ab787f54b9.md)
- **`packages/kiro-cli/docs`**
  - Match:
    - `lib/ai/ai-common.nix`
    - `lib/ai/transformers/kiro.nix`
    - `lib/idempotentFlags.nix`
    - `packages/kiro-cli/**`
  - Read:
    - [`AGENTS.md.rules/6c15eb97325a151e073ef2e34d5bb59cb6fe4cda0567d2665c88718301a7ce35.md`](AGENTS.md.rules/6c15eb97325a151e073ef2e34d5bb59cb6fe4cda0567d2665c88718301a7ce35.md)
- **`packaging`**
  - Match:
    - `config/update-targets.nix`
    - `packages/**/*.nix`
  - Read:
    - [`dev/fragments/packaging/naming-conventions.md`](dev/fragments/packaging/naming-conventions.md)
    - [`dev/fragments/packaging/platforms.md`](dev/fragments/packaging/platforms.md)
- **`pipeline`**
  - Match:
    - `.github/actions/check-cache/**`
    - `.github/actions/warm-ifd/**`
    - `.github/repo-settings.yml`
    - `.github/workflows/ci.yml`
    - `.github/workflows/hestia-gc.yml`
    - `.github/workflows/update.yml`
    - `config/fragment-categories.nix`
    - `config/update-targets.nix`
    - `dev/ai.nix`
    - `dev/ci-check-evaluator.nix`
    - `dev/generate.nix`
    - `dev/scripts/ci-*.py`
    - `dev/scripts/test-ci-*.py`
    - `dev/scripts/test-update-*.py`
    - `dev/scripts/update-*.py`
    - `dev/scripts/update-*.sh`
    - `dev/tasks/generate.nix`
    - `lib/ai/transformers/**`
    - `lib/fragments-registry.nix`
    - `lib/fragments.nix`
    - `lib/generated.nix`
    - `lib/update.nix`
    - `packages/*/registry.nix`
    - `renovate.json5`
  - Read:
    - [`dev/fragments/pipeline/ci-update-workflow.md`](dev/fragments/pipeline/ci-update-workflow.md)
    - [`dev/fragments/pipeline/fragment-pipeline.md`](dev/fragments/pipeline/fragment-pipeline.md)
    - [`dev/fragments/pipeline/generation-architecture.md`](dev/fragments/pipeline/generation-architecture.md)
    - [`dev/fragments/pipeline/update-pipeline.md`](dev/fragments/pipeline/update-pipeline.md)
- **`redact`**
  - Match:
    - `checks/redact/**`
    - `lib/redact/**`
  - Read:
    - [`dev/fragments/redact/redact.md`](dev/fragments/redact/redact.md)
- **`semble-integration`**
  - Match:
    - `packages/semble/**`
  - Read:
    - [`packages/semble/docs/semble.md`](packages/semble/docs/semble.md)
- **`shell-activation`**
  - Match:
    - `.envrc`
    - `devenv.yaml`
    - `lib/traceSource.nix`
  - Read:
    - [`dev/fragments/shell-activation/activation-mechanism.md`](dev/fragments/shell-activation/activation-mechanism.md)
- **`stacked-workflows`**
  - Match:
    - `packages/stacked-workflows/**`
  - Read:
    - [`packages/stacked-workflows/docs/development.md`](packages/stacked-workflows/docs/development.md)

<!-- rule: delegate-routing-router -->

Apply this rule only in: `codex`, `kimchi`, `kiro`.

# Delegate routing

### Architecture

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
- **Secret readiness is one provider registry.** Declare a secret provider once
  in `ai.activationOrder.secretProviders` with its activation nodes and its user
  unit; activation's `secrets` point and `ai.services` units both read it. A
  unit that reads a reference or a restart-trigger file wants and orders after
  the provider units and starts with the target the provider's own unit uses,
  read from the evaluated unit; Home Manager adds sops-nix by default. Home
  Manager's post-reload service check reads the same units' last results. A
  hardcoded provider name or a second ordering mechanism would drift. See
  `packages/ai-module/lib/secrets.nix` and
  `packages/ai-module/lib/services.nix`.
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
- **Secret files are delivered by `ai.services`.** A setting that wants the path
  of a file holding a secret is typed `redact.types.secretFile`; the consumer
  still writes a redact reference. The service launcher writes the value to a
  0600 file in the service's runtime directory and delivers that path, and
  restart triggers and provider ordering come from the reference as before. An
  owner never copies a key to disk, probes a key file or wires its trigger by
  hand, and a secret-file value reaching any other launcher fails evaluation.
  See `lib/redact/default.nix`, `packages/ai-module/lib/services.nix` and
  `dev/fragments/redact/redact.md`.
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
- **PROPOSAL (not yet vetted): CPA instances own named routing.** Each
  `ai.cliproxyapi.instances.<name>` declares upstream `credentials` and
  `clientKeys` once. Each client key routes only to named upstream credentials;
  OAuth rules carry exact auth-file IDs, API-key rules carry exact base URLs,
  and one API table lowers those credentials. A Harness selects
  `proxy = {instance; clientKey;}` without publishing keys or rules. External
  `url` + `key` selections add nothing to Instances. See
  `lib/ai/proxy/default.nix`, `packages/cliproxyapi/lib/providers.nix` and
  `packages/cliproxyapi/modules/instances.nix`.
- **PROPOSAL (not yet vetted): harness sandboxing is ours.** The host sandbox
  (the microvm) is the real protection. `ai.jail` / `ai.<runtime>.jail`
  (jail.nix, bubblewrap) is an extra layer that keeps a harness from damaging
  its own dev environment, mostly by accident while it debugs that environment;
  the two may be layered. `ai.jail` wraps every harness launcher once, in
  `lib/ai/app/mkBackendTransform.nix`, so every runtime and both backends share
  it and the command keeps its name. Copilot is the exception: it ships no
  launcher here, so it only gets a warning. Rejected: each runtime's built-in
  sandbox, because they cannot be normalized across runtimes; and a per-factory
  wrapper, which would drift per runtime. See `lib/ai/jail/default.nix` and
  `packages/jail-nix/docs/jail-nix.md`.

### Load delegate-routing

Before you hand work to a subagent, another CLI or a workflow, load the
delegate-routing skill. It lists the models and tools you can use, and how to
set model and effort for each.

### Local limits

On this machine, run at most two external CLI delegates at once. This is not a
parallelism limit for native subagents or workflow nodes.

### Orchestrator session

Keep this session for talking with the user, deciding, and checking results.
Hand bulk reading, searching, measuring and edit-and-test loops to delegates.
Have them write large output to files and report a short summary with its
evidence. Give each delegate one task: one part of the system, or one question.

### Validate the result

Give each delegate one clear goal and say what result proves it's done. Require
an evidence chain for every claim it reports: file and line, or the exact
command and its output. Each claim comes back as verified, retracted (checked
and not an issue, with the reason), or unknown (not checked, with what would
settle it). Delegates never drop a claim silently.

At each level of orchestration, validate those claims before passing them up.
Pick the check the claim needs:

- A claim that rests on a command: re-run it, or have a separate step re-run it.
  An exit code of 0 alone isn't proof. Check what depends on the changed files,
  such as generated files and tests.
- A claim that rests on reading: judge it with the full picture you hold. A
  finding that only looks wrong from the reviewer's narrower scope, for example
  two things that "conflict" where one is deliberately scoped, is retracted with
  the reason, not escalated.

When something fails, name why: a concept problem needs a stronger model,
missing evidence needs fetching, an execution slip needs fixing. Fix small
things yourself. Bring the user only what is real and needs their decision,
written the way their communication rules ask, if they have any.

<!-- rule: peer-communication-router -->

Apply this rule only in: `codex`, `kimchi`, `kiro`.

# Peer communication

When you are talking with a person, load the peer-communication skill before
your first reply and follow it for every reply after. Skip it when your brief
says you run non-interactively and report to an orchestrator.

<!-- rule: semble -->

Apply this rule only in: `codex`, `kiro`.

Use `semble search` to discover code by behavior or meaning. Use exact text
searches, filename searches, and direct reads when you know the identifier or
path or need to verify a result.

```bash
semble search "authentication flow" ./my-project --max-snippet-lines 10
semble search "save_pretrained" ./my-project
semble search "save model to disk" ./my-project --top-k 10
```

Results are cached automatically on first run and invalidated when files change.

`--content` selects one or more categories to search:

```bash
semble search "deployment guide" ./my-project --content docs
semble search "database host port" ./my-project --content config
semble search "authentication" ./my-project --content code docs
semble search "authentication" ./my-project --content all
```

Use `semble find-related` to discover code similar to a known location. Pass the
`file_path` and `line` from a prior search result:

```bash
semble find-related src/auth.py 42 ./my-project
```

The path defaults to the current directory when omitted; Git URLs are accepted.

Pass several known paths or URLs when the question spans related repositories:

```bash
semble search "invoice endpoint" ./service-a ../service-b
```

Results from several repositories prefix `file_path` with a repository label.
The `repos` map identifies each label's source. For a local source, replace the
label with that source path before reading the file. For a URL, use a known
checkout or repository read tool. When calling `semble find-related`, retain the
returned `file_path` including its label and pass the same repository paths and
content selection.

### Workflow

1. Search with a focused description of the behavior. Pass `--content` when
   searching beyond code: `docs`, `config`, several categories such as
   `code docs`, or `all`.
2. Treat ranked results as candidates. Read enough surrounding source, callers,
   and tests to verify their relevance before proposing an edit.
3. Refine the query, expand the snippets or result count, or use exact text and
   filename searches when results are incomplete or ambiguous. Search known
   dependent or sibling repositories together when relevant.
4. Optionally use `semble find-related` with a promising result's `file_path`
   and a `line` within its returned range, such as `start_line`, to discover
   similar implementations. Similarity results do not enumerate every caller or
   reference; use exact searches or language-aware reference tools when
   completeness matters.

<!-- rule: stacked-workflows-router -->

Apply this rule only in: `codex`, `kimchi`, `kiro`.

<!-- Fragment: packages/stacked-workflows/fragments/skill-routing.md -->

## Skill Routing — MANDATORY

**RULE: Before running any git-branchless, git-absorb, or git-revise command via
Bash, check whether a `stack-*` skill covers the operation.** Skills carry
pre-flight checks, dry-run previews, conflict guidance, and post-operation
verification that the equivalent hand-run commands miss.

Each skill's own description states which operations it covers.

# nix-agentic-tools

Project instructions for AI coding assistants working in this repository.

<!-- Generated by dev/generate.nix -->
<!-- Fragment: packages/coding-standards/fragments/coding-standards.md -->

## Coding Standards

### Bash

All shell scripts must use full strict mode:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
```

`-E` (errtrace), `-T` (functrace) and `inherit_errexit` are the point: they
propagate failures out of the subshells, functions and command substitutions
that the abbreviated `set -euo pipefail` silently swallows. Never use the
abbreviated form.

**No linter checks this for you.** shellcheck has no strict-mode diagnostic — a
script carrying `set -euo pipefail`, or no `set` line at all, passes it clean.
The header is a review obligation, not a gate.

Where it applies depends on whether the shell owns its own process or is spliced
into someone else's:

| Site                                                      | Rule                                                                                                                  |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `home.activation` bodies                                  | SCOPE IT — wrap the body in a subshell; entries concatenate, so a bare header persists into home-manager's own code   |
| `ai.<owner>.activation` commands, `content.run` renderers | ADDED FOR YOU — ai-module runs each in its own `bash` or subshell with the full header; `exit` ends only that command |
| `shellHook` / devenv `enterShell`                         | DO NOT ADD — `eval`'d into the calling shell; `set -e` arms the user's interactive session                            |
| stdenv phase bodies                                       | REQUIRED in the first custom phase body; later phases inherit it — but see the `nounset` exception below              |
| `runCommand` bodies                                       | REQUIRED inside the body — add the full header; `setup.sh` leaves `-u`, `-E`, and `-T` disabled                       |
| devenv `tasks.<name>.exec`                                | REQUIRED — rendered as a standalone script                                                                            |
| shell EMITTED by a heredoc                                | REQUIRED inside the emitted script                                                                                    |
| standalone `*.sh`, CI `run:` blocks                       | REQUIRED                                                                                                              |
| `writeShellApplication`                                   | SPLIT — see below; `bashOptions` alone never suffices                                                                 |
| `writeShellScript` / `writeShellScriptBin`                | REQUIRED — nixpkgs never lints these                                                                                  |
| heredocs carrying JSON, config or prose                   | does not apply — not shell                                                                                            |
| pre-commit / git-hook `entry` strings                     | cannot be expressed — an argv, not a script; move the logic into a `writeShellApplication`                            |

Probes of `runCommand`, `buildPhase`, and `installPhase` all start with
`errexit`, `pipefail`, and `inherit_errexit` enabled, but with `errtrace`,
`functrace`, and `nounset` disabled. Add the complete header shown above rather
than only the three missing options. stdenv phases run in one shell, so a header
in the first custom phase also governs later phases; that persistence is
intentional, and later phases do not need another copy.

The exception is a builder whose own phases are not `nounset`-clean.
`buildGoModule`'s `buildPhase` reads `$excludedPackages` without a default, so a
bare header in a Go recipe's `preBuild` fails the build with
`excludedPackages: unbound variable`. In such a recipe, wrap each custom phase
body in a subshell with its own header, as `home.activation` bodies are, and
give a later custom phase such as `installCheckPhase` its own header.

`writeShellApplication` needs the header **split across two places**, because
`bashOptions` renders `set -o <name>` lines only and `inherit_errexit` is a
`shopt`:

```nix
pkgs.writeShellApplication {
  bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
  text = ''
    shopt -s inherit_errexit 2>/dev/null || :
    …
  '';
}
```

Put the `set -o` flags in `bashOptions` rather than all five in `text`:
writeShellApplication emits them ABOVE its own generated
`export PATH="…:$PATH"`, so `nounset` covers that line. Without it, a PATH-less
invocation yields a trailing-colon PATH — which bash reads as the current
directory — instead of failing loudly.

`home.activation` needs the header **scoped**, because home-manager concatenates
every DAG entry into one script it opens with `set -eu` + `set -o pipefail`.
Flags an entry sets stay set for every later entry, home-manager's own included:

```nix
home.activation.thing = lib.hm.dag.entryAfter ["linkGeneration"] ''
  (
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  …
  )
'';
```

Only wrap bodies with no parent-shell effects (no `export`, no `cd`, no `trap`).
Failure still propagates — the subshell exits non-zero and the caller's `set -e`
sees it. End a failing body with `false`, never `exit`, which would truncate the
whole concatenated script.

Two blind spots to catch by eye in review: shellcheck does not lint heredoc
BODIES under either `<<EOF` or `<<'EOF'`, and nixpkgs runs shellcheck on
`writeShellApplication` only — `writeShellScript` gets a syntax parse and no
lint at all.

### Ordering

Keep entries sorted alphabetically within categorical groups. Use section
headers for readability, sort entries within each group. This applies to lists,
attribute sets, JSON objects, markdown tables, TOML sections, and similar
collections.

### DRY Principle

Never duplicate logic, configuration, or patterns. When the same thing appears
twice, extract it. Three similar lines is better than a premature abstraction,
but three similar blocks means it is time to extract.

<!-- Fragment: packages/coding-standards/fragments/commit-convention.md -->

## Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:** `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`,
`style`, `test`

**Scopes** (optional but encouraged): package or module name (e.g.,
`context7-mcp`, `copilot-cli`, `fragments`), directory name (`overlay`,
`module`, `lib`), or `flake` for root changes.

Keep descriptions lowercase, imperative mood, no trailing period.

<!-- Fragment: packages/coding-standards/fragments/config-parity.md -->

## Config Parity

Three configuration methods exist with the same rough interface:

- **lib/** — manual functions for consumers wiring config directly
- **HM modules** (`modules/`) — declarative home-manager (system-level)
- **devenv modules** (`modules/devenv/`) — project-local dev shell

If a feature can be configured in HM, it must also be configurable in devenv and
vice versa. Gaps between methods are bugs.

Surfaces to keep aligned across all three methods: skills,
instructions/steering, MCP servers, settings, hooks, agents, environment
variables, permissions.

The `ai.*` module (both HM and devenv) provides a unified interface that fans
out shared surfaces to enabled ecosystems (Claude, Codex, Copilot, Kimchi, Kiro)
with ecosystem-specific translation. A surface without a lossless native mapping
is an explicit exclusion, not a silent no-op.

<!-- Fragment: packages/coding-standards/fragments/tooling-preference.md -->

## External Tooling

When accessing external services, prefer the highest-fidelity integration
available:

1. **MCP server** — richest context, structured responses, stays in-conversation
2. **CLI tool** (e.g., `gh`, `curl`) — scriptable, good for batch operations
3. **Direct web access** — last resort, use only when MCP and CLI are
   unavailable

<!-- Fragment: packages/coding-standards/fragments/validation.md -->

## Validation

### Formatting

After editing any file — regardless of how it was modified (Edit, Write, Bash,
sed, etc.) — run `treefmt <file>` on the changed file. treefmt handles Nix (via
alejandra) and markdown (via prettier).

<!-- Fragment: dev/fragments/monorepo/build-commands.md -->

## Build & Validation Commands

> **Last verified:** 2026-10-25 — context measurements estimate Copilot tuning
> costs; generation includes devenv.yaml; lock resolution remains an explicit
> network operation.

```bash
nix flake show                # List all outputs
nix flake check               # The CI gate: formatting, structural/module eval,
                              # runtime contracts, and validator corpus scans
                              # (does NOT build the package output set)
nix build .#<package>         # Build a specific package
devenv shell                  # Enter the devenv shell with all tools
treefmt                       # Format all files (formats only — lints nothing)
devenv tasks run devenv:git-hooks:run # Manual-stage local all-files diagnostic

# Regenerate instructions, repo documents and devenv.yaml. `--mode before` is
# load-bearing: without it devenv runs the aggregate and skips the leaves.
devenv tasks run --mode before generate:all

# After adding or changing a flake input, sync its devenv lock (may use network).
devenv update <input>
```

For context tuning, run `bash dev/scripts/measure-context.sh` for corpus totals
or supply repository-relative paths, including deleted paths:

```bash
bash dev/scripts/measure-context.sh packages/chatgpt-codex/checks/module-eval.nix
```

The initial soft engineering target is **128 KiB for root AGENTS.md plus matched
Copilot native instructions**, counting each file once: roughly 32K tokens at 4
bytes/token, with sensitivity about 26K–44K at 5–3 bytes/token. This chosen
target is neither a GitHub limit nor a pass/fail gate. Estimates exclude diff,
system, organization, and retrieved content; path matching approximates native
globs. Fallback child indexes are excluded from native instruction totals.
Codex's separate 32 KiB project-document read window remains its own contract.

<!-- Fragment: dev/fragments/monorepo/change-propagation.md -->

## Change Propagation

When removing or renaming a concept, update ALL surfaces that reference it in
the same commit:

- Fragments and generated instruction files
- CLAUDE.md, AGENTS.md, Kiro steering, Copilot instructions
- Routing tables in skills
- README feature matrix and server reference
- flake.nix output lists
- config.update.targets entries (owner registry.nix)
- CI workflow matrices
- Home-manager module registrations
- Overlay export lists
- Structural check expectations

The structural check (`nix flake check`) validates cross-references. The
pre-commit hook runs a fast subset. If something is removed, grep for it across
the repo before committing.

<!-- Fragment: dev/fragments/monorepo/operating-policy.md -->

## Repository operating policy

> **Last verified:** 2026-10-25 — the monorepo category loads these decisions;
> the linked guides retain procedures, rationale and settled evidence and must
> be read before the actions named below.

### Repository writes and Git operations

Before planning a repository change or writing the first repo-destined file,
read [Git Workflow](dev/fragments/monorepo/git-workflow.md). Read it again
before creating a worktree, planning commits, pushing, rebasing, changing hooks
or repository settings, handling bot updates, or cleaning up a merged PR if it
is not already in your current context. Its settled constraints remain binding.

Every change goes through an isolated worktree and PR. This includes untracked
drafts; only a session scratchpad outside the repository is exempt. Before the
first write, run `git rev-parse --path-format=absolute --git-dir`: a path ending
in `.git/worktrees/<slug>` is a linked worktree; the primary checkout's `.git`
means create a worktree first. The primary checkout belongs to the operator.

Create worktrees from `origin/main` beside the primary checkout, deriving their
parent from the absolute Git common directory as the guide specifies. Do not
bootstrap them by default. Hook configuration comes from the launch checkout;
hook state comes from the committing worktree. A branch adding a local gate
still gets its own CI validation. Materialize a worktree only to test its devenv
output; never bypass missing hook configuration. Keep the shared hooks path and
serialize stack operations against the shared branchless database.

Use the existing `stack-*` skills for operations they cover. Push the first
commit and subsequent work as it lands. Amend an existing PR for its own review
fixes, intended follow-ups and defects; open another PR only for unrelated work.
Before rewriting history, push a backup under `archive/<slug>/<what>` to
`origin` in the same command sequence. Local tags and branches are unsafe
backups. Regenerate conflicting lockfiles; never hand-merge them.

Human PRs are squash-merged by the operator. Bot `update/*` PRs auto-merge after
required checks and review-thread resolution; do not restore a manual batch
merge path. Once a PR merges, its implementing agent removes its worktree, local
branch and `archive/<slug>/*` backup refs before declaring completion. Retain
backups when a PR closes unmerged until the operator says otherwise.

Before writing shared agent memory, read the guide's **What is shared across
worktrees — and what is not** section. List recent memory files and search the
concept before choosing a filename; extend an existing record rather than
creating a concurrent duplicate.

### PR ownership and review

Before opening or updating a PR against `main`, pushing to one, responding to
review, or investigating its checks, load the `pr-review-loop` skill and the Git
Workflow guide above. Own the loop through green checks and completed review, or
a decision only the operator can make. Never end on an unarmed promise to check
later: run the skill's background watcher for the pushed head, react to its
first failure, read the failing log, fix and re-arm. An empty check list with
`mergeStateStatus: DIRTY` means rebase, not wait.

Open ready when dev-complete; reserve drafts for WIP or an explicit preview.
Copilot automatically reviews once when a PR becomes ready. Never request the
first review manually or infer a missed trigger from an ordinary push. Read both
inline threads and the whole review body, including suppressed findings. Reply
to and resolve each gating thread in the same turn as its fix.

Re-request only for new scope, a new mechanism, or an approach rewritten since
the last review. Applying findings, rewording, formatting and renaming do not
qualify. Further paid review needs such a change or the operator's instruction.
Do not restore the Devenv Diagnostic as a required or automatic PR context; read
the guide's evidence and the live ruleset before changing repository gates.

Use a separate reviewer from a different vendor when Copilot errors, lacks
quota, never reviewed a draft, or the change since its last review meets the
re-request test. Give requirements and the diff; the PR body is not evidence.
Report dismissed findings as well as fixes. Never review your own diff.

For work going to `main`, use delegate-routing's **Work and review** workflow.
Use its three blind checks when dismissing a reviewer finding, or when a diff
touches `lib/**`, `packages/*/lib/**`, `packages/*/patches/**`,
`packages/*/packages/**/*.nix`, or adds, removes or retypes a `mkOption` under
`packages/*/modules/**` or `lib/ai/**`. Otherwise use one reviewer. Drafts and
unsettled experiment branches forgo this escalation. Run these checks locally,
never through github.com Copilot, and size each role separately. Do not route
escalation on an undefined judgment of "complexity".

### Instruction and validation changes

Before changing instruction sources, their registration, generation or delivery,
read [Architecture Fragments](dev/fragments/monorepo/architecture-fragments.md)
and the applicable path-scoped pipeline guidance. Before changing an abstraction
a fragment describes, read that fragment and update it in the same commit.

Edit authoritative sources, never generated instruction projections. Use owner
registries for package categories and `config/fragment-categories.nix` for
workspace categories. Keep one current verification marker; retain settled
rejections and their evidence, not a changelog. Add fragments for non-inferable
knowledge, not signatures or ephemeral work. Target fewer than 150 lines per
fragment and split longer topics by concern. Regenerate after source or registry
changes with `devenv tasks run --mode before generate:all`; `--mode before` is
required to run dependency leaves. Sync input locks separately with
`devenv update <input>` when needed.

Before changing hooks, validators, formatter configuration, or diagnostic and
shell-activation wiring, read [Linting](dev/fragments/monorepo/linting.md) and
the Git Workflow guide's shared-hook rules. `config/repo-validation.nix` owns
validation policy; every local validator needs its declared CI backend.
`nix flake check` is authoritative; local changeset success or a bypassed hook
does not prove corpus correctness. Treefmt formats and lints nothing. Keep
corpus diagnostics off shell activation; the diagnostic hook runner must
explicitly request the manual stage.

<!-- Fragment: dev/fragments/monorepo/project-overview.md -->

## Project Overview

> **Last verified:** 2026-10-16 — owner-local `extracted/` directories hold
> declared facts and measured raws; owner checks expose their regeneration; the
> files and activation layers and the files engine live in
> `packages/ai-module/`.

nix-agentic-tools is a Nix flake monorepo providing:

- **Stacked workflow skills** — SKILL.md files for stacked commit workflows
  using git-branchless, git-absorb, and git-revise
- **MCP server packages** — Model Context Protocol servers packaged as Nix
  derivations with typed settings and credential handling
- **Home-manager modules** — declarative configuration for Claude Code, Copilot
  CLI, Kiro CLI, stacked workflows, and MCP services
- **Devenv modules** — per-project AI tool configuration without home-manager
- **Git tool overlays** — git-absorb, git-branchless, git-revise

Skills work without Nix. Nix unlocks overlays, home-manager modules, and devenv
modules.

This flake's own nixpkgs builds every package it ships. `overlays.default` and
the module package defaults hand consumers those same builds, so they hit the
cache whatever nixpkgs the consumer uses. Unfree packages are left out of
`packages` and need the consumer's own opt-in; CI and checks read the
unfree-enabled `ciPackages`. The overlay-pattern fragment has the details.

### Key Directories

```text
packages/<owner>/
  packages/ai/<namespace>/<name>/package.nix  Native binary recipes and roles
  lib/                  Public default.nix plus private factories/helpers
  modules/              Consumer Home Manager and devenv configuration
  registry.nix          Update, documentation, and architecture metadata
  checks.nix, checks/   Owner checks and fixtures
  sources.json          Owner-local release pins (when needed)
  extracted/            Declared facts and measured raws (when needed)
  docs/, patches/, src/ Documentation and build support files
  fragments/, skills/  Published content (when applicable)
packages/ai-module/     Files and activation layers and the files engine
lib/                    Shared composition, AI fanout and factories, packaging helpers
lib/testing/            Shared test harnesses with discovered backend imports
checks/<concern>/       Native workspace checks and cross-owner integration
config/                 Workspace policy and shared option declarations/data
dev/                    Repo-only generation, tasks, scripts, skills, and guidance
flake.nix               Public assembly and repo outputs
devenv.nix              This repository's workspace shell
```

The owner layout merged in PR #1633 is the operator-accepted baseline as of
2026-09-12. Further regrouping or reducing directory nesting is future design
work, not an unfinished migration. Old restructure plans and private prototypes
are historical evidence, not instructions to resume.

See `docs/repository-layout.md` for the settled owner tree and the distinction
between package and workspace responsibilities.
