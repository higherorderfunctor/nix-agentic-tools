# ai.extraSystemPrompt: one keyed text-source pool, four delivery mechanisms,
# one explicit exclusion. Every check reads the evaluated module (launcher
# `postBuild`, file entries, normalized pools), never a realized package, so
# none of them builds a runtime.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
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

  # Literal search without regex compilation; the context of a store path
  # does not matter to a substring test.
  contains = needle: hay:
    builtins.length (lib.splitString
      (builtins.unsafeDiscardStringContext needle)
      (builtins.unsafeDiscardStringContext hay))
    > 1;

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
          && !(contains "--append-system-prompt" (buildCommandOf "kimchi" evaluated))
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
        && contains
        "--append-system-prompt-file ${pkgs.writeText "claude-extra-system-prompt.md" joined}"
        (buildCommandOf "claude-code" evaluated))
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
        ai.extraSystemPrompt = entries;
      } (evaluated: (codexSettings evaluated).developer_instructions or null == "Native wins.")
    );

    # Kimchi: the launcher passes `--append-system-prompt` with a store file
    # (Pi reads a path that exists as the prompt's contents).
    module-ai-extra-system-prompt-kimchi-flag = mkTest "ai-extra-system-prompt-kimchi-flag" (
      onBoth {
        ai.kimchi.enable = true;
        ai.extraSystemPrompt = entries;
      } (evaluated:
        isWrapped "kimchi" evaluated
        && contains
        "--append-system-prompt ${pkgs.writeText "kimchi-extra-system-prompt.md" joined}"
        (buildCommandOf "kimchi" evaluated))
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
