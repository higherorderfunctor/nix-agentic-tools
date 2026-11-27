# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows claudeSettings evalDevenv evalHm mkTest mkWrapperGrepTest rejectsChange;
  root = {shell = pkgs.bash;};
  rootExe = lib.getExe pkgs.bash;
  overrideExe = lib.getExe pkgs.bashNonInteractive;
  explicitShell = "/explicit/zsh";

  claudeEnv = evaluate: ai: let
    settings = claudeSettings (evaluate {ai = lib.recursiveUpdate {claude.enable = true;} ai;});
  in
    settings.env or {};
  claudeShell = evaluate: ai: (claudeEnv evaluate ai).CLAUDE_CODE_SHELL or null;

  checkWrapper = bin: launcherPath: shellExport: name: ai: {
    expected ? null,
    absentNeedles ? [],
  }:
    mkWrapperGrepTest {
      inherit bin name;
      package =
        builtins.head
        (evalHm {
          ai = lib.recursiveUpdate (lib.setAttrByPath (launcherPath ++ ["enable"]) true) ai;
        }).config.home.packages;
      needles = lib.optional (expected != null) (shellExport expected);
      absentNeedles = absentNeedles ++ lib.optional (expected == null) "export SHELL=";
    };
  # Read the assignment in the shipped launcher, not merely the presence of a
  # variable name and the path somewhere in the file. Codex's makeWrapper
  # quotes the value; Kiro's generated export leaves these shell-safe paths bare.
  checkCodex = checkWrapper "codex" ["codex"] (value: "export SHELL='${value}'");
  checkKiro = checkWrapper "kiro-cli" ["kiro" "cli"] (value: "export SHELL=${value}");
in {
  checks = {
    # ── ai.shell — root default with per-runtime override ───────────
    #
    # This scalar uses null-as-inherit, unlike keyed pools where null is a
    # tombstone. The precedence cases below are the contract, not incidental
    # coverage. Four runtimes consume it; Copilot remains excluded. See dev/fragments/ai-module/shell-option.md.

    # Default null must touch nothing — the whole opt-in premise.
    module-ai-shell-default-null-is-inert = assert lib.assertMsg (!(claudeEnv evalHm {} ? CLAUDE_CODE_SHELL)) "Claude must not set CLAUDE_CODE_SHELL when ai.shell is unset";
      checkCodex "ai-shell-default-null-is-inert" {} {};

    # Claude reads its dedicated variable, NOT SHELL. An explicit native
    # setting still wins over the module's mkDefault.
    # `bashNonInteractive` is distinct from `bash` in this pinned nixpkgs
    # (`bash` IS `bashInteractive` here), so the override can fail the test.
    module-ai-shell-per-runtime-overrides-root = mkTest "ai-shell-per-runtime-overrides-root" (
      checkRows "Claude shell delivery" {
        "distinct runtime shell overrides the root shell" =
          overrideExe != rootExe && claudeShell evalHm (root // {claude.shell = pkgs.bashNonInteractive;}) == overrideExe;
        "explicit native CLAUDE_CODE_SHELL overrides the root shell" =
          claudeShell evalHm (root // {claude.native.settings.env.CLAUDE_CODE_SHELL = "/usr/bin/bash";}) == "/usr/bin/bash";
        "root shell reaches CLAUDE_CODE_SHELL on Home Manager" = claudeShell evalHm root == rootExe;
        "root shell reaches CLAUDE_CODE_SHELL on devenv" = claudeShell evalDevenv root == rootExe;
      }
    );

    # The always-present Codex launcher carries an explicitly selected shell.
    module-ai-shell-codex-hm-wrapper-carries-shell =
      checkCodex "ai-shell-codex-hm-wrapper-carries-shell" root {expected = rootExe;};

    # Kiro reads SHELL from its own process env; HM bakes exports into the
    # symlinkJoin wrapper, so the value must be visible in the launcher.
    module-ai-shell-kiro-hm-wrapper-carries-shell =
      checkKiro "ai-shell-kiro-hm-wrapper-carries-shell" root {expected = rootExe;};

    # PRECEDENCE, and it must be the SAME on every runtime. Module-contributed
    # values (the typed `ai.shell`, the sandbox-safe SSH default) merge UNDER
    # the consumer's `environmentVariables`, so an explicit entry wins.
    #
    # Codex briefly did the opposite — it applied the typed option last, on the
    # reasoning that the typed surface is more specific. Defensible alone, wrong
    # in aggregate: the identical two-key config then resolved differently
    # depending on which runtime the consumer named. These two tests exist to
    # keep the two runtimes agreeing, so change them together or not at all.
    module-ai-shell-explicit-env-beats-typed-codex = checkCodex "ai-shell-explicit-env-beats-typed-codex" (root // {codex.environmentVariables.SHELL = explicitShell;}) {
      absentNeedles = [rootExe];
      expected = explicitShell;
    };
    module-ai-shell-explicit-env-beats-typed-kiro = checkKiro "ai-shell-explicit-env-beats-typed-kiro" (root // {kiro.cli.environmentVariables.SHELL = explicitShell;}) {
      absentNeedles = [rootExe];
      expected = explicitShell;
    };

    # Positive control for a consumer setting a runtime shell without a root
    # shell: the supported option must reach Claude, not merely be declared.
    module-ai-shell-accepted-for-claude = mkTest "ai-shell-accepted-for-claude" (
      claudeShell evalHm {claude.shell = pkgs.bash;} == rootExe
    );

    # Copilot opts out: a per-runtime shell write must fail as an undeclared
    # option rather than evaluate cleanly and then be silently dropped.
    module-ai-shell-excluded-for-copilot = mkTest "ai-shell-excluded-for-copilot" (
      let
        valid = {ai.copilot.enable = true;};
        invalid = lib.recursiveUpdate valid {ai.copilot.shell = pkgs.bash;};
        enabled = config: (evalHm config).config.ai.copilot.enable;
        # tryEval hides the error. Holding the input fixed and disabling only
        # unmatched-option checking distinguishes rejection from another error.
        unchecked = evalHm (invalid // {_module.check = false;});
      in
        checkRows "Copilot shell exclusion" {
          "ai.copilot.shell is not declared, and the same write evaluates without unmatched-option checking" =
            !(unchecked.options.ai.copilot ? shell) && unchecked.config.ai.copilot.enable;
          "checked merge rejects the undeclared ai.copilot.shell write" = rejectsChange enabled {
            inherit invalid valid;
            expected = true;
          };
        }
    );
  };
}
