# ai.extraSystemPrompt: one keyed text-source pool, four delivery mechanisms,
# one explicit exclusion. Every check reads the evaluated module (launcher
# `buildCommand`, file entries, normalized pools), never a realized package, so
# none of them builds a runtime.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm hasLiteral mkTest;
  inherit (import ../../packages/chatgpt-codex/checks/helpers.nix {inherit lib pkgs harness;}) hmCodexSettings;

  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  # True when `check` holds for the same configuration on both backends.
  onBoth = config: check: lib.all (evaluate: check (evaluate config)) (builtins.attrValues backends);

  # Defined out of name order on purpose: delivery must sort by name.
  entries = {
    beta.text = "Second by name.";
    alpha.text = "First by name.";
  };
  joined = "First by name.\n\nSecond by name.";

  packagesOf = evaluated:
    if evaluated.config ? home
    then evaluated.config.home.packages
    else evaluated.config.packages;
  # The one installed package whose derivation name starts with `prefix`
  # (`claude-code`, `kimchi`), bare or wrapped.
  installed = prefix: evaluated: let
    matches = builtins.filter (drv: lib.hasPrefix prefix (drv.name or "")) (packagesOf evaluated);
  in
    if builtins.length matches == 1
    then builtins.head matches
    else throw "expected one installed ${prefix} package, found ${toString (builtins.length matches)}";
  # symlinkJoin folds `postBuild` into `buildCommand` and drops the attribute,
  # so the wrapProgram line is read from there.
  buildCommandOf = prefix: evaluated: (installed prefix evaluated).buildCommand or "";
  isWrapped = prefix: evaluated: lib.hasSuffix "-wrapped" (installed prefix evaluated).name;

  codexSettings = evaluated:
    if evaluated.config ? home
    then hmCodexSettings evaluated
    else evaluated.config.ai.codex.files.".codex/config.toml".content.value or {};

  # pi's append file, at the default harness directory on both backends.
  kimchiAppendFile = evaluated: evaluated.config.ai.kimchi.files.".config/kimchi/harness/APPEND_SYSTEM.md" or null;

  kiroAgent = name: evaluated:
    builtins.fromJSON evaluated.config.ai.kiro.files.".kiro/agents/${name}.json".content.text;

  kiroAgents = {
    native.agents.native-only = {
      description = "Native only";
      prompt.text = "Own prompt.";
    };
    native.agents.no-prompt.description = "No prompt";
  };
  normalizedAgent.reviewer = {
    description = "Reviews";
    instructions.text = "Review diffs.";
  };

  allRuntimes = extra:
    lib.recursiveUpdate {
      ai = {
        agents = normalizedAgent;
        claude.enable = true;
        codex.enable = true;
        kimchi.enable = true;
        kiro = kiroAgents // {enable = true;};
      };
    }
    extra;
in {
  checks = {
    # No entry, or only a disabled one, changes nothing: no wrapper or flag,
    # no Codex key, Kiro prompts exactly as authored.
    module-ai-extra-system-prompt-empty-is-inert = mkTest "ai-extra-system-prompt-empty-is-inert" (
      let
        inert = evaluated:
          !(isWrapped "claude-code" evaluated)
          && kimchiAppendFile evaluated == null
          && !((codexSettings evaluated) ? developer_instructions)
          && (kiroAgent "native-only" evaluated).prompt == "Own prompt."
          && !((kiroAgent "no-prompt" evaluated) ? prompt)
          && (kiroAgent "reviewer" evaluated).prompt == "Review diffs.";
      in
        onBoth (allRuntimes {}) inert
        && onBoth (allRuntimes {
          ai.extraSystemPrompt.off = {
            enable = false;
            text = "Withheld.";
          };
        })
        inert
    );

    # Claude: the launcher passes `--append-system-prompt-file` with a store
    # file whose bytes are the entries joined in name order.
    module-ai-extra-system-prompt-claude-flag = mkTest "ai-extra-system-prompt-claude-flag" (
      onBoth {
        ai.claude.enable = true;
        ai.extraSystemPrompt = entries;
      } (evaluated:
        isWrapped "claude-code" evaluated
        && hasLiteral
        "--append-system-prompt-file ${pkgs.writeText "claude-extra-system-prompt.md" joined}"
        (buildCommandOf "claude-code" evaluated))
    );

    module-ai-extra-system-prompt-claude-no-package-warning = mkTest "ai-extra-system-prompt-claude-no-package-warning" (
      let
        config.ai.claude = {
          enable = true;
          package = null;
        };
        warns = evaluated:
          packagesOf evaluated
          == []
          && builtins.length evaluated.config.warnings == 1
          && hasLiteral "ai.claude.extraSystemPrompt" (builtins.head evaluated.config.warnings)
          && hasLiteral "ai.claude.package" (builtins.head evaluated.config.warnings);
      in
        onBoth (lib.recursiveUpdate config {
          ai.extraSystemPrompt.probe.source = /tmp/extra-system-prompt-missing;
        })
        warns
        && onBoth config (evaluated: evaluated.config.warnings == [])
        && onBoth (lib.recursiveUpdate config {
          ai.extraSystemPrompt.probe = {
            enable = false;
            source = /tmp/extra-system-prompt-missing;
          };
        }) (evaluated: evaluated.config.warnings == [])
    );

    # Codex: `developer_instructions` carries the joined text at mkDefault, so
    # a consumer's native value replaces it wholesale.
    module-ai-extra-system-prompt-codex-key = mkTest "ai-extra-system-prompt-codex-key" (
      onBoth {
        ai.codex.enable = true;
        ai.extraSystemPrompt = entries;
      } (evaluated: (codexSettings evaluated).developer_instructions or null == joined)
      && onBoth {
        ai.codex = {
          enable = true;
          native.settings.developer_instructions = "Native wins.";
        };
        ai.extraSystemPrompt.probe.source = /tmp/extra-system-prompt-missing;
      } (evaluated: (codexSettings evaluated).developer_instructions or null == "Native wins.")
    );

    # Kimchi: pi's own APPEND_SYSTEM.md carries the entries joined in name
    # order.
    module-ai-extra-system-prompt-kimchi-file = mkTest "ai-extra-system-prompt-kimchi-file" (
      onBoth {
        ai.kimchi.enable = true;
        ai.extraSystemPrompt = entries;
      } (evaluated: (kimchiAppendFile evaluated).content.text or null == joined)
      && onBoth {
        ai.kimchi = {
          enable = true;
          files.".config/kimchi/harness/APPEND_SYSTEM.md".format = "raw";
        };
        ai.extraSystemPrompt = entries;
      } (evaluated:
        (kimchiAppendFile evaluated).content.text
        == joined
        && (kimchiAppendFile evaluated).format == "raw")
    );

    # Kiro: every typed agent — lowered from `ai.agents`, native-only, or with
    # no prompt of its own — carries the text after its own prompt.
    module-ai-extra-system-prompt-kiro-agents = mkTest "ai-extra-system-prompt-kiro-agents" (
      onBoth (allRuntimes {ai.extraSystemPrompt = entries;}) (evaluated:
        (kiroAgent "native-only" evaluated).prompt
        == "Own prompt.\n\n${joined}"
        && (kiroAgent "no-prompt" evaluated).prompt == joined
        && (kiroAgent "reviewer" evaluated).prompt == "Review diffs.\n\n${joined}")
    );

    # Per-runtime layering: a runtime entry replaces the root entry at its key,
    # `enable = false` withdraws it, and a runtime-only key is added. The
    # second runtime is the positive control that still inherits the root.
    module-ai-extra-system-prompt-runtime-layering = mkTest "ai-extra-system-prompt-runtime-layering" (
      onBoth {
        ai = {
          extraSystemPrompt = entries;
          codex = {
            enable = true;
            extraSystemPrompt = {
              alpha.text = "Codex alpha.";
              beta.enable = false;
              gamma.text = "Codex only.";
            };
          };
          kiro = {
            enable = true;
            native.agents.probe.description = "Probe";
          };
        };
      } (evaluated:
        (codexSettings evaluated).developer_instructions
        or null
        == "Codex alpha.\n\nCodex only."
        && (kiroAgent "probe" evaluated).prompt == joined)
    );

    # Copilot is an explicit exclusion: no per-runtime option, and a root entry
    # leaves its installed package and its file set unchanged. Claude is the positive
    # control for the option-presence probe.
    module-ai-extra-system-prompt-copilot-excluded = mkTest "ai-extra-system-prompt-copilot-excluded" (
      onBoth {} (evaluated:
        !(evaluated.options.ai.copilot ? extraSystemPrompt)
        && evaluated.options.ai.claude ? extraSystemPrompt)
      && lib.all (evaluate: let
        base = evaluate {ai.copilot.enable = true;};
        withEntries = evaluate {
          ai.copilot.enable = true;
          ai.extraSystemPrompt = entries;
        };
        drvPaths = evaluated: map (drv: drv.drvPath) (packagesOf evaluated);
      in
        drvPaths base
        == drvPaths withEntries
        && builtins.attrNames base.config.ai.copilot.files == builtins.attrNames withEntries.config.ai.copilot.files) (builtins.attrValues backends)
    );
  };
}
