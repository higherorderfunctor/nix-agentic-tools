# Consumer facts the delivery records cannot state: absences outside the
# shared surfaces, native writers beside an unsupported surface, and the
# input options each row's warning probes.
{lib}: let
  optionPaths = import ../lib/ai/option-paths.nix {inherit lib;};
  absent = reason: {
    inherit reason;
    primitive = "notApplicable";
  };
  inputOptions = surface: ecosystem:
    if surface == "permissions"
    then
      if builtins.elem ecosystem ["kimchi" "kiro"]
      then [["ai" ecosystem "permissions"]]
      else if builtins.elem ecosystem ["claude" "codex"]
      then [["ai" ecosystem "native" "settings" "permissions"]]
      else []
    else if surface == "settings" && optionPaths.hasNativeSettings ecosystem
    then [(optionPaths.nativeSettings ecosystem)] ++ lib.optional (ecosystem == "kimchi") ["ai" "kimchi" "native" "harnessSettings"]
    # Every agents runtime has `agentsDir`; Codex and Kiro also take native
    # records, which alone can produce a file (a native-only agent). The
    # ai-warnings-delivery check holds this list to the records'
    # `agentNativeType`.
    else if surface == "agents"
    then
      [["ai" "agents"] (optionPaths.pool ecosystem "agents") (optionPaths.pool ecosystem "agentsDir")]
      ++ lib.optional (builtins.elem ecosystem ["codex" "kiro"]) ["ai" ecosystem "native" "agents"]
    else if ecosystem == "kiro" && surface == "hooks"
    then [["ai" "kiro" "hooks"] ["ai" "kiro" "hooksDir"] ["ai" "kiro" "hooksJson"]]
    else
      [["ai" surface]]
      ++ lib.optional (builtins.elem surface (builtins.attrNames (lib.filterAttrs (_: support: support.backends != []) optionPaths.records.${ecosystem}.surfaceSupport))) (optionPaths.pool ecosystem surface);
in {
  inherit absent inputOptions;
  # Absences on the policy-only permissions surface, which no runtime record
  # declares.
  hand = let
    copilot = absent "github.com Copilot reads no permissions file; a custom agent profile's `tools` list, which ai.copilot.github.agents writes, is the only tool restriction a repository file carries. See https://docs.github.com/en/copilot/reference/custom-agents-configuration.";
  in {
    "permissions/copilot/devenv" = copilot;
    "permissions/copilot/hm" = copilot;
    "permissions/kiro/devenv" = absent "Kiro reads permissions only from ~/.kiro/settings/ (global) or ~/.kiro/workspace-roots/<hash>/, never a project .kiro/, so a devenv-written permissions.yaml would never be read (packages/kiro-cli/lib/mkKiro.nix:1524-1528, the comment establishing those read paths above the permissions option). Agent-local permission records remain part of agents.";
  };
  # Shared surfaces a record does not consume while a native option still
  # writes the file (Kiro's native hooks and `cli.json`): the row delivers
  # and the root request warns as a child, so the native options stay quiet.
  nativeWriters = ["hooks/kiro/devenv" "hooks/kiro/hm" "settings/kiro/devenv" "settings/kiro/hm"];
  # Diagnostic-only children for inputs the primary row cannot consume.
  supplements = {
    "settings/claude/devenv" = [
      ((absent "unpinLaunchEffort is an explicit HM-only global ~/.claude.json operation; devenv does not mutate HOME.")
        // {
          inputOptions = [["ai" "claude" "unpinLaunchEffort"]];
          warnOnlyExplicit = true;
        })
    ];
  };
}
