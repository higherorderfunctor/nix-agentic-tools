# Evaluation contracts for lib.mkTextSourceOptions.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
  textSourceOptions = import ../../lib/mkTextSourceOptions.nix {inherit lib;};
  source = builtins.toFile "text-source-options-source" "packaged prose\n";

  assertionsType = lib.types.listOf (lib.types.submodule {
    options = {
      assertion = lib.mkOption {type = lib.types.bool;};
      message = lib.mkOption {type = lib.types.str;};
    };
  });
  baseModule = {config, ...}: {
    options = {
      assertions = lib.mkOption {
        type = assertionsType;
        default = [];
      };
      entries = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          imports = [(textSourceOptions.submodule "entry prose")];
        });
        default = {};
      };
    };
    config.assertions = textSourceOptions.assertions ["entries"] config.entries;
  };
  evaluate = modules:
    lib.evalModules {
      modules = [baseModule] ++ modules;
    };

  packageSource = evaluate [
    {entries.example.source = lib.mkDefault source;}
  ];
  consumerText = evaluate [
    {entries.example.source = lib.mkDefault source;}
    {entries.example.text = "consumer prose";}
  ];
  sameDefaultPriority = evaluate [
    {
      entries.example = {
        source = lib.mkDefault source;
        text = lib.mkDefault "authored prose";
      };
    }
  ];
  samePriority = evaluate [
    {
      entries.example = {
        inherit source;
        text = "authored prose";
      };
    }
  ];
  unset = evaluate [
    {entries.example = {};}
  ];

  contract =
    if packageSource.config.entries.example.text != "packaged prose\n"
    then throw "mkTextSourceOptions: package source did not derive text"
    else if packageSource.config.assertions != []
    then throw "mkTextSourceOptions: package source reported a conflict"
    else if consumerText.config.entries.example.text != "consumer prose"
    then throw "mkTextSourceOptions: consumer text did not override package source"
    else if consumerText.config.assertions != []
    then throw "mkTextSourceOptions: consumer override reported a conflict"
    else if samePriority.config.entries.example._textSourceConflict == null
    then throw "mkTextSourceOptions: same-priority definitions did not report a conflict"
    else if builtins.length samePriority.config.assertions != 1
    then throw "mkTextSourceOptions: same-priority definitions did not lift exactly one assertion"
    else if (builtins.head samePriority.config.assertions).assertion
    then throw "mkTextSourceOptions: same-priority conflict lifted a passing assertion"
    else if sameDefaultPriority.config.entries.example._textSourceConflict == null
    then throw "mkTextSourceOptions: same-default-priority definitions did not report a conflict"
    else if builtins.length sameDefaultPriority.config.assertions != 1
    then throw "mkTextSourceOptions: same-default-priority definitions did not lift exactly one assertion"
    else if (builtins.head sameDefaultPriority.config.assertions).assertion
    then throw "mkTextSourceOptions: same-default-priority conflict lifted a passing assertion"
    else if unset.config.entries.example.text != ""
    then throw "mkTextSourceOptions: unset text did not retain its empty default"
    else if unset.config.entries.example._textSourceConflict != null
    then throw "mkTextSourceOptions: unset entry reported a conflict"
    else true;
in {
  checks.factory-text-source-options-eval = mkTest "text-source-options-eval" contract;
}
