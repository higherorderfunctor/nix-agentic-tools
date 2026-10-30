# Consumer facts the delivery records cannot state: absences outside the
# shared surfaces, native writers beside an unsupported surface, and the
# input options each row's warning probes.
{lib}: let
  optionPaths = import ../lib/ai/option-paths.nix {inherit lib;};
  inherit (import ./ai-delivery-schema.nix {inherit lib;}) leafFields;
  absent = reason: {
    inherit reason;
    primitive = "notApplicable";
  };
  # A surface declared `backends = []` has no per-runtime pool option.
  declaresPool = surface: ecosystem: (optionPaths.records.${ecosystem}.surfaceSupport.${surface} or {backends = [];}).backends != [];
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
    # Every agents pool has `agentsDir`; Codex and Kiro also take native
    # records, which alone can produce a file (a native-only agent). The
    # ai-warnings-delivery check holds this list to the records'
    # `agentNativeType`.
    else if surface == "agents"
    then
      [["ai" "agents"]]
      ++ lib.optionals (declaresPool surface ecosystem) [(optionPaths.pool ecosystem "agents") (optionPaths.pool ecosystem "agentsDir")]
      ++ lib.optional (builtins.elem ecosystem ["codex" "kiro"]) ["ai" ecosystem "native" "agents"]
    else if ecosystem == "kiro" && surface == "hooks"
    then [["ai" "kiro" "hooks"] ["ai" "kiro" "hooksDir"] ["ai" "kiro" "hooksJson"]]
    else let
      paths =
        [["ai" surface]]
        ++ lib.optional (declaresPool surface ecosystem) (optionPaths.pool ecosystem surface);
    in
      # Plain option trees declare leaf inputs on the shared registration.
      if leafFields ? ${surface}
      then lib.concatMap (path: map (field: path ++ [field]) leafFields.${surface}) paths
      else paths;
in {
  inherit absent inputOptions;
  # Absences on the policy-only permissions surface, which no runtime record
  # declares.
  hand = let
    copilot = absent "github.com Copilot reads no permissions file; a custom agent profile's `tools` list is the only tool restriction a repository file carries, and this module writes no agent profile. See https://docs.github.com/en/copilot/reference/custom-agents-configuration.";
  in {
    "permissions/copilot/devenv" = copilot;
    "permissions/copilot/hm" = copilot;
    "permissions/kiro/devenv" = absent "Kiro reads permissions only from ~/.kiro/settings/ (global) or ~/.kiro/workspace-roots/<hash>/, never a project .kiro/, so a devenv-written permissions.yaml would never be read (packages/kiro-cli/lib/mkKiro.nix:1524-1528, the comment establishing those read paths above the permissions option). Agent-local permission records remain part of agents.";
  };
  # Shared surfaces a record does not consume while a native option still
  # writes the file (Kiro's native hooks and `cli.json`): the row delivers
  # and the root request warns as a child, so the native options stay quiet.
  nativeWriters = ["hooks/kiro/devenv" "hooks/kiro/hm" "settings/kiro/devenv" "settings/kiro/hm"];
}
