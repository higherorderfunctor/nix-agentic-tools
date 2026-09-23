# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest mkWrapperGrepTest;
in {
  checks = {
    # ── ai.shell — root default with per-runtime override ───────────
    #
    # This scalar uses null-as-inherit, unlike keyed pools where null is a
    # tombstone. The precedence cases below are the contract, not incidental
    # coverage. Three
    # runtimes consume it through three different mechanisms; two are
    # excluded outright. See dev/fragments/ai-module/shell-option.md.

    # Default null must touch nothing — the whole opt-in premise.
    module-ai-shell-default-null-is-inert = mkTest "ai-shell-default-null-is-inert" (
      let
        hm = evalHm {
          ai.claude.enable = true;
          ai.codex.enable = true;
        };
        claudeSettings = hm.config.programs.claude-code.settings or {};
        # Unwrapped codex keeps the bare upstream store path.
        codexPkg = builtins.head hm.config.home.packages;
      in
        !((claudeSettings.env or {}) ? CLAUDE_CODE_SHELL)
        && !(lib.hasSuffix "-wrapped" (builtins.baseNameOf codexPkg))
    );

    # Root → Claude's dedicated variable (NOT SHELL — Claude ignores that).
    module-ai-shell-root-reaches-claude = mkTest "ai-shell-root-reaches-claude" (
      let
        result = evalHm {
          ai.shell = pkgs.bash;
          ai.claude.enable = true;
        };
        settings = result.config.programs.claude-code.settings or {};
      in
        (settings.env.CLAUDE_CODE_SHELL or null) == (lib.getExe pkgs.bash)
    );

    # Per-runtime beats root. `bashNonInteractive` is a genuinely distinct
    # derivation from `bash` in this pinned nixpkgs (`bash` IS
    # `bashInteractive` here), which is what makes this assertion able to
    # fail at all — two names for one store path would pass vacuously.
    module-ai-shell-per-runtime-overrides-root = mkTest "ai-shell-per-runtime-overrides-root" (
      let
        result = evalHm {
          ai.shell = pkgs.bash;
          ai.claude = {
            enable = true;
            shell = pkgs.bashNonInteractive;
          };
        };
        settings = result.config.programs.claude-code.settings or {};
      in
        (settings.env.CLAUDE_CODE_SHELL or null)
        == (lib.getExe pkgs.bashNonInteractive)
        && lib.getExe pkgs.bashNonInteractive != lib.getExe pkgs.bash
    );

    # Kiro reads SHELL from its own process env; HM bakes exports into the
    # symlinkJoin wrapper, so the value must be visible in the launcher.
    module-ai-shell-kiro-hm-wrapper-carries-shell = let
      result = evalHm {
        ai.shell = pkgs.bash;
        ai.kiro.enable = true;
      };
    in
      mkWrapperGrepTest {
        name = "ai-shell-kiro-hm-wrapper-carries-shell";
        package = builtins.head result.config.home.packages;
        bin = "kiro-cli";
        needles = ["SHELL" (lib.getExe pkgs.bash)];
      };

    # Codex had NO wrapper before this option; one is built on demand.
    module-ai-shell-codex-hm-wrapper-carries-shell = let
      result = evalHm {
        ai.shell = pkgs.bash;
        ai.codex.enable = true;
      };
    in
      mkWrapperGrepTest {
        name = "ai-shell-codex-hm-wrapper-carries-shell";
        package = builtins.head result.config.home.packages;
        bin = "codex";
        needles = ["SHELL" (lib.getExe pkgs.bash)];
      };

    # Devenv parity: same root option, same resolved value, both backends.
    module-ai-shell-hm-devenv-parity = mkTest "ai-shell-hm-devenv-parity" (
      let
        hm = evalHm {
          ai.shell = pkgs.bash;
          ai.claude.enable = true;
        };
        devenv = evalDevenv {
          ai.shell = pkgs.bash;
          ai.claude.enable = true;
        };
        hmValue =
          (hm.config.programs.claude-code.settings or {}).env.CLAUDE_CODE_SHELL or null;
        devenvFile = devenv.config.files.".claude/settings.json" or null;
        devenvValue =
          if devenvFile == null
          then null
          else devenvFile.json.env.CLAUDE_CODE_SHELL or null;
      in
        hmValue != null && hmValue == devenvValue
    );

    # Explicit consumer value still wins over the option (mkDefault).
    module-ai-shell-explicit-settings-wins = mkTest "ai-shell-explicit-settings-wins" (
      let
        result = evalHm {
          ai.shell = pkgs.bash;
          ai.claude = {
            enable = true;
            native.settings.env.CLAUDE_CODE_SHELL = "/usr/bin/bash";
          };
        };
        settings = result.config.programs.claude-code.settings or {};
      in
        (settings.env.CLAUDE_CODE_SHELL or null) == "/usr/bin/bash"
    );

    # PRECEDENCE, and it must be the SAME on every runtime. Module-contributed
    # values (the typed `ai.shell`, the sandbox-safe SSH default) merge UNDER
    # the consumer's `environmentVariables`, so an explicit entry wins.
    #
    # Codex briefly did the opposite — it applied the typed option last, on the
    # reasoning that the typed surface is more specific. Defensible alone, wrong
    # in aggregate: the identical two-key config then resolved differently
    # depending on which runtime the consumer named. These two tests exist to
    # keep the two runtimes agreeing, so change them together or not at all.
    module-ai-shell-explicit-env-beats-typed-codex = let
      result = evalHm {
        ai.shell = pkgs.bash;
        ai.codex = {
          enable = true;
          environmentVariables.SHELL = "/explicit/zsh";
        };
      };
    in
      mkWrapperGrepTest {
        name = "ai-shell-explicit-env-beats-typed-codex";
        package = builtins.head result.config.home.packages;
        bin = "codex";
        needles = ["/explicit/zsh"];
        absentNeedles = [(lib.getExe pkgs.bash)];
      };

    module-ai-shell-explicit-env-beats-typed-kiro = let
      result = evalHm {
        ai.shell = pkgs.bash;
        ai.kiro = {
          enable = true;
          environmentVariables.SHELL = "/explicit/zsh";
        };
      };
    in
      mkWrapperGrepTest {
        name = "ai-shell-explicit-env-beats-typed-kiro";
        package = builtins.head result.config.home.packages;
        bin = "kiro-cli";
        needles = ["/explicit/zsh"];
        absentNeedles = [(lib.getExe pkgs.bash)];
      };

    # POSITIVE CONTROL for the two exclusion tests below. They assert an
    # eval FAILURE, and a test that only ever asserts failure passes just as
    # happily when the harness is broken for an unrelated reason — at which
    # point it proves nothing while still reporting green. This runs the
    # identical tryEval shape against a runtime that DOES support the option
    # and requires success, so the pair can only both hold if `tryEval` is
    # actually discriminating on the option's existence. Do not delete one
    # without the other.
    module-ai-shell-accepted-for-claude = mkTest "ai-shell-accepted-for-claude" (
      let
        probe =
          builtins.tryEval
          (evalHm {
            ai.claude = {
              enable = true;
              shell = pkgs.bash;
            };
          })
      .config.home.packages;
      in
        probe.success
    );

    # Copilot and Kimchi opt OUT: the option must NOT exist for them, so a
    # consumer setting one gets an eval error instead of a value that
    # evaluates cleanly and is then silently dropped.
    module-ai-shell-excluded-for-copilot = mkTest "ai-shell-excluded-for-copilot" (
      let
        probe =
          builtins.tryEval
          (evalHm {
            ai.copilot = {
              enable = true;
              shell = pkgs.bash;
            };
          })
      .config.home.packages;
      in
        !probe.success
    );

    module-ai-shell-excluded-for-kimchi = mkTest "ai-shell-excluded-for-kimchi" (
      let
        probe =
          builtins.tryEval
          (evalHm {
            ai.kimchi = {
              enable = true;
              shell = pkgs.bash;
            };
          })
      .config.home.packages;
      in
        !probe.success
    );
  };
}
