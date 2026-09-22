# Evaluation contracts for lib.ai.types text sources.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
  inherit (harness) evalDevenv evalHm;
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

  defaultContentType = aiTypes.optionalTextSource {
    defaultContent.text = "package prose";
    description = "defaulted prose";
  };
  evaluateDefaultContent = modules:
    lib.evalModules {
      modules =
        [
          {
            options.value = lib.mkOption {
              type = defaultContentType;
              default = {};
            };
          }
        ]
        ++ modules;
    };
  defaultContentUnset = evaluateDefaultContent [];
  defaultContentEnabled = evaluateDefaultContent [{value.enable = true;}];
  defaultContentSource = evaluateDefaultContent [{value.source = source;}];
  requiredDefaultContent =
    (lib.evalModules {
      modules = [
        {
          options.value = lib.mkOption {
            type = aiTypes.textSource {
              defaultContent.text = "required package prose";
              description = "required defaulted prose";
            };
            default = {};
          };
        }
      ];
    }).config.value;

  forcedSource = evaluate [
    {
      entries.example = {
        source = lib.mkForce source;
        text = "consumer prose";
      };
    }
  ];
  defaultText = evaluate [
    {
      entries.example = {
        inherit source;
        text = lib.mkDefault "default prose";
      };
    }
  ];
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

  invalidTextSourceDefaults = path: declarations:
    lib.concatLists (lib.mapAttrsToList (name: declaration: let
      optionPath = path ++ [name];
    in
      if declaration._type or null == "option"
      then let
        subOptions = declaration.type.getSubOptions optionPath;
        isDirectTextSource =
          declaration.type.name
          == "submodule"
          && subOptions ? _textSourceType;
      in
        lib.optional (isDirectTextSource && (declaration.default or {}) != {}) optionPath
        ++ invalidTextSourceDefaults optionPath (builtins.removeAttrs subOptions ["_module"])
      else if builtins.isAttrs declaration
      then invalidTextSourceDefaults optionPath declaration
      else [])
    (builtins.removeAttrs declarations ["_module"]));
  checkTextSourceDefaults = evaluated: let
    invalid = invalidTextSourceDefaults [] evaluated.options;
  in
    if invalid == []
    then true
    else throw "text-source options must install package defaults with defaultContent, not a non-empty outer mkOption default: ${lib.concatMapStringsSep ", " lib.showOption invalid}";
  badDeclaration = type:
    lib.evalModules {
      modules = [
        {
          options.value = lib.mkOption {
            inherit type;
            default = {text = "bad outer default";};
          };
        }
      ];
    };
  badDirect = badDeclaration (aiTypes.optionalTextSource {
    defaultContent.text = "package prose";
    description = "bad direct declaration";
  });
  badRequired = badDeclaration (aiTypes.textSource {description = "bad required declaration";});
  badExtended = badDeclaration (aiTypes.extendSubmodule
    (aiTypes.optionalTextSource {description = "bad extended declaration";})
    {options.extra = lib.mkOption {type = lib.types.bool;};});
  badReimported = badDeclaration (lib.types.submodule {
    imports = (aiTypes.optionalTextSource {description = "bad reimported declaration";}).getSubModules;
  });
  badDirectRejected = !(builtins.tryEval (checkTextSourceDefaults badDirect)).success;
  badRequiredRejected = !(builtins.tryEval (checkTextSourceDefaults badRequired)).success;
  badExtendedRejected = !(builtins.tryEval (checkTextSourceDefaults badExtended)).success;
  badReimportedRejected = !(builtins.tryEval (checkTextSourceDefaults badReimported)).success;

  # This repository guard covers direct text-source submodule declarations
  # reachable through the aggregate Home Manager and devenv harness imports,
  # including submodules nested below container options. It deliberately does
  # not reject defaults on a wrapping type itself (such as attrsOf or nullOr),
  # because pool-level container defaults are valid. It also cannot inspect
  # downstream consumers or custom module sets that the harnesses do not import.
  realDeclarationsAccepted =
    checkTextSourceDefaults (evalHm {})
    && checkTextSourceDefaults (evalDevenv {});

  contract =
    if !badDirectRejected
    then throw "lib.ai.types: outer default guard accepted a direct text-source declaration"
    else if !badRequiredRejected
    then throw "lib.ai.types: outer default guard accepted a textSource declaration"
    else if !badExtendedRejected
    then throw "lib.ai.types: outer default guard accepted an extended text-source declaration"
    else if !badReimportedRejected
    then throw "lib.ai.types: outer default guard accepted a reimported text-source declaration"
    else if !realDeclarationsAccepted
    then throw "lib.ai.types: outer default guard rejected a repository declaration"
    else if defaultContentUnset.config.value.enable
    then throw "lib.ai.types: default content unexpectedly enabled an unset option"
    else if defaultContentUnset.config.value.text != "package prose"
    then throw "lib.ai.types: unset option lost its default content"
    else if !defaultContentEnabled.config.value.enable
    then throw "lib.ai.types: explicit enable did not enable default content"
    else if defaultContentEnabled.config.value.text != "package prose"
    then throw "lib.ai.types: explicit enable lost the default content"
    else if defaultContentSource.config.value.text != "packaged prose\n"
    then throw "lib.ai.types: consumer source did not override default content"
    else if requiredDefaultContent.text != "required package prose"
    then throw "lib.ai.types: textSource did not install default content"
    else if forcedSource.config.entries.example.text != "packaged prose\n"
    then throw "lib.ai.types: forced source did not override ordinary text"
    else if packageSource.config.entries.example.text != "packaged prose\n"
    then throw "lib.ai.types: package source did not derive text"
    else if packageSource.config.entries.example.enable
    then throw "lib.ai.types: package source changed enableDefault false"
    else if !packageSourceEnabledByDefault.config.entries.example.enable
    then throw "lib.ai.types: package source changed enableDefault true"
    else if consumerText.config.entries.example.text != "consumer prose"
    then throw "lib.ai.types: consumer text did not override package source"
    else if defaultText.config.entries.example.text != "packaged prose\n"
    then throw "lib.ai.types: ordinary source did not override default text"
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
