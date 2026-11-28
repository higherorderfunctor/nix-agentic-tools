# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows claudeSettings evalDevenv evalHm mkTest mkWrapperGrepTest rejectsChange;
  # Pin the executable within each fixture output independently of the
  # module's package-to-executable conversion.
  explicitShell = "/explicit/zsh";
  overrideExe = "${lib.getBin pkgs.bashNonInteractive}/bin/bash";
  root = {shell = pkgs.bash;};
  rootExe = "${lib.getBin root.shell}/bin/bash";

  claudeEnv = evaluate: ai: let
    settings = claudeSettings (evaluate {ai = lib.recursiveUpdate {claude.enable = true;} ai;});
  in
    settings.env or {};
  claudeShell = evaluate: ai: (claudeEnv evaluate ai).CLAUDE_CODE_SHELL or null;

  wrapperChecks = bin: launcherPath: shellExport: let
    check = name: ai: expected: absentNeedles:
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
  in {
    explicitEnv = name:
      check name (root // lib.setAttrByPath (launcherPath ++ ["environmentVariables" "SHELL"]) explicitShell) explicitShell [rootExe];
    inherited = name: check name root rootExe [];
    unset = name: check name {} null [];
  };
  # Read the assignment in the shipped launcher, not merely the presence of a
  # variable name and the path somewhere in the file. Codex's makeWrapper
  # quotes the value; Kiro's generated export leaves these shell-safe paths bare.
  codexWrapper = wrapperChecks "codex" ["codex"] (value: "export SHELL='${value}'");
  kiroWrapper = wrapperChecks "kiro-cli" ["kiro" "cli"] (value: "export SHELL=${value}");
in {
  checks = {
    # ── ai.shell — root default with per-runtime override ───────────
    #
    # This scalar uses null-as-inherit, unlike keyed pools where null is a
    # tombstone. The precedence cases below are the contract, not incidental
    # coverage. Four runtimes consume it; Copilot remains excluded. See dev/fragments/ai-module/shell-option.md.

    # An unset shell must not inject a Codex export that replaces its default.
    module-ai-shell-default-null-is-inert = codexWrapper.unset "ai-shell-default-null-is-inert";

    # Claude reads its dedicated variable, NOT SHELL. Read it from the
    # delivered settings, not the intermediate module option.
    module-ai-shell-per-runtime-overrides-root = mkTest "ai-shell-per-runtime-overrides-root" (
      checkRows "Claude shell delivery" {
        "Home Manager does not drop the root shell from CLAUDE_CODE_SHELL" = claudeShell evalHm root == rootExe;
        "devenv does not drop the root shell from CLAUDE_CODE_SHELL" = claudeShell evalDevenv root == rootExe;
        "native CLAUDE_CODE_SHELL is not overwritten by the typed default" =
          claudeShell evalHm (root // {claude.native.settings.env.CLAUDE_CODE_SHELL = explicitShell;}) == explicitShell;
        # `bash` is `bashInteractive` here; use `bashNonInteractive` so a
        # regression to the root package cannot satisfy the assertion.
        "runtime shell is not replaced by the root shell" =
          overrideExe != rootExe && claudeShell evalHm (root // {claude.shell = pkgs.bashNonInteractive;}) == overrideExe;
      }
    );

    # Codex could still install its always-present launcher but drop the
    # inherited shell from it.
    module-ai-shell-codex-hm-wrapper-carries-shell =
      codexWrapper.inherited "ai-shell-codex-hm-wrapper-carries-shell";

    # Kiro reads SHELL from its own process env; HM bakes exports into the
    # symlinkJoin wrapper. Omitting the export leaves Kiro on the parent shell.
    module-ai-shell-kiro-hm-wrapper-carries-shell =
      kiroWrapper.inherited "ai-shell-kiro-hm-wrapper-carries-shell";

    # PRECEDENCE, and it must be the SAME on every runtime. Module-contributed
    # values (the typed `ai.shell`, the sandbox-safe SSH default) merge UNDER
    # the consumer's `environmentVariables`, so an explicit entry wins.
    #
    # Codex briefly did the opposite — it applied the typed option last, on the
    # reasoning that the typed surface is more specific. Defensible alone, wrong
    # in aggregate: the identical two-key config then resolved differently
    # depending on which runtime the consumer named. These two tests exist to
    # keep the two runtimes agreeing, so change them together or not at all.
    module-ai-shell-explicit-env-beats-typed-codex = codexWrapper.explicitEnv "ai-shell-explicit-env-beats-typed-codex";
    module-ai-shell-explicit-env-beats-typed-kiro = kiroWrapper.explicitEnv "ai-shell-explicit-env-beats-typed-kiro";

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
