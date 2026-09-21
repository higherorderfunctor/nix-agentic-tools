# Evaluation contracts for lib.ai.types text sources.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
  aiTypes = import ../../lib/ai/types.nix {inherit lib;};
  source = builtins.toFile "text-source-options-source" "packaged prose\n";

  baseModule = entryType: {
    options = {
      entries = lib.mkOption {
        type = lib.types.attrsOf entryType;
        default = {};
      };
      required = lib.mkOption {
        type = aiTypes.textSource {description = "required prose";};
        default = {};
      };
    };
  };
  evaluateWith = entryType: modules:
    lib.evalModules {
      modules = [(baseModule entryType)] ++ modules;
    };
  evaluate = evaluateWith (aiTypes.optionalTextSource {description = "entry prose";});

  packageSource = evaluate [
    {entries.example.source = lib.mkDefault source;}
  ];
  packageSourceEnabledByDefault = evaluateWith (aiTypes.optionalTextSource {
    description = "entry prose";
    enableDefault = true;
  }) [{entries.example.source = lib.mkDefault source;}];
  samePriority = evaluate [
    {
      entries.example = {
        inherit source;
        text = "authored prose";
      };
    }
  ];
  consumerText = evaluate [
    {entries.example.source = lib.mkDefault source;}
    {entries.example.text = "consumer prose";}
  ];
  consumerTextDisabled = evaluate [
    {
      entries.example = {
        enable = false;
        text = "consumer prose";
      };
    }
  ];
  consumerSourceNull = evaluate [
    {entries.example.source = lib.mkDefault source;}
    {entries.example.source = null;}
  ];
  newConsumerText = evaluate [{entries.new.text = "new consumer prose";}];
  sameDefaultPriority = evaluate [
    {
      entries.example = {
        source = lib.mkDefault source;
        text = lib.mkDefault "authored prose";
      };
    }
  ];
  sameDefaultPriorityFailed = !(builtins.tryEval (builtins.deepSeq sameDefaultPriority.config.entries true)).success;
  samePriorityFailed = !(builtins.tryEval (builtins.deepSeq samePriority.config.entries true)).success;
  unset = evaluate [{entries.example = {};}];

  contract =
    if packageSource.config.entries.example.text != "packaged prose\n"
    then throw "lib.ai.types: package source did not derive text"
    else if packageSource.config.entries.example.enable
    then throw "lib.ai.types: package source changed enableDefault false"
    else if !packageSourceEnabledByDefault.config.entries.example.enable
    then throw "lib.ai.types: package source changed enableDefault true"
    else if consumerText.config.entries.example.text != "consumer prose"
    then throw "lib.ai.types: consumer text did not override package source"
    else if !consumerText.config.entries.example.enable
    then throw "lib.ai.types: consumer override did not auto-enable entry"
    else if consumerSourceNull.config.entries.example.text != ""
    then throw "lib.ai.types: explicit null source did not leave text empty"
    else if consumerSourceNull.config.entries.example.enable
    then throw "lib.ai.types: explicit null source auto-enabled entry"
    else if !samePriorityFailed
    then throw "lib.ai.types: same-priority definitions did not fail evaluation"
    else if !sameDefaultPriorityFailed
    then throw "lib.ai.types: same-default-priority definitions did not fail evaluation"
    else if !newConsumerText.config.entries.new.enable
    then throw "lib.ai.types: consumer text did not auto-enable a new entry"
    else if consumerTextDisabled.config.entries.example.enable
    then throw "lib.ai.types: explicit enable false did not override auto-enable"
    else if unset.config.entries.example.text != ""
    then throw "lib.ai.types: unset text did not retain its empty default"
    else if unset.config.entries.example.enable
    then throw "lib.ai.types: unset entry did not retain enableDefault false"
    else if builtins.hasAttr "enable" (unset.options.required.type.getSubOptions [])
    then throw "lib.ai.types: textSource unexpectedly declared enable"
    else true;
in {
  checks.factory-text-source-options-eval = mkTest "text-source-options-eval" contract;
}
