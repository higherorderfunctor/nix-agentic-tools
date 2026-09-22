# Evaluation contracts for lib.ai.types text sources.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
  agent = import ../../lib/ai/agent.nix {inherit lib;};
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

  bareStringInstructions = lib.evalModules {
    modules = [
      {
        options.agent = lib.mkOption {
          type = agent.semanticAgentType;
        };
        config.agent = {
          description = "Bare-string rejection probe";
          instructions = "untyped instructions";
        };
      }
    ];
  };
  bareStringInstructionsFailed = !(builtins.tryEval (builtins.deepSeq bareStringInstructions.config.agent true)).success;
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
  enabledEmpty = evaluate [{entries.example.enable = true;}];
  enabledEmptyFailed = !(builtins.tryEval (builtins.deepSeq enabledEmpty.config.entries.example true)).success;
  requiredEmpty = evaluate [];
  requiredEmptyFailed = !(builtins.tryEval (builtins.deepSeq requiredEmpty.config.required true)).success;
  emptyOverridesDefaultSource = evaluateWith (aiTypes.optionalTextSource {
    defaultContent.source = source;
    description = "entry prose";
    enableDefault = true;
  }) [{entries.example.text = "";}];
  emptyOverridesDefaultSourceFailed = !(builtins.tryEval (builtins.deepSeq emptyOverridesDefaultSource.config.entries.example true)).success;
  disabledEmptyOverridesDefaultSource = evaluateWith (aiTypes.optionalTextSource {
    defaultContent.source = source;
    description = "entry prose";
  }) [{entries.example.text = "";}];
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

  tests = {
    bare-string-instructions-rejected = bareStringInstructionsFailed;
    consumer-source-null-keeps-text-empty = consumerSourceNull.config.entries.example.text == "";
    consumer-source-null-remains-disabled = !consumerSourceNull.config.entries.example.enable;
    consumer-text-auto-enables-entry = consumerText.config.entries.example.enable;
    consumer-text-overrides-package-source = consumerText.config.entries.example.text == "consumer prose";
    default-content-enable-enables = defaultContentEnabled.config.value.enable;
    default-content-enable-preserves-prose = defaultContentEnabled.config.value.text == "package prose";
    default-content-source-overrides-prose = defaultContentSource.config.value.text == "packaged prose\n";
    default-content-unset-preserves-prose = defaultContentUnset.config.value.text == "package prose";
    default-content-unset-remains-disabled = !defaultContentUnset.config.value.enable;
    default-text-yields-to-source = defaultText.config.entries.example.text == "packaged prose\n";
    disabled-empty-default-source-keeps-text-empty = disabledEmptyOverridesDefaultSource.config.entries.example.text == "";
    disabled-empty-default-source-remains-disabled = !disabledEmptyOverridesDefaultSource.config.entries.example.enable;
    disabled-text-source-preserves-content = consumerTextDisabled.config.entries.example.text == "consumer prose";
    empty-override-of-default-source-rejected = emptyOverridesDefaultSourceFailed;
    enabled-empty-optional-source-rejected = enabledEmptyFailed;
    explicit-disable-overrides-auto-enable = !consumerTextDisabled.config.entries.example.enable;
    forced-source-overrides-text = forcedSource.config.entries.example.text == "packaged prose\n";
    new-consumer-text-auto-enables = newConsumerText.config.entries.new.enable;
    outer-default-direct-rejected = badDirectRejected;
    outer-default-extended-rejected = badExtendedRejected;
    outer-default-reimported-rejected = badReimportedRejected;
    outer-default-required-rejected = badRequiredRejected;
    package-source-derives-text = packageSource.config.entries.example.text == "packaged prose\n";
    package-source-does-not-change-enable-default-false = !packageSource.config.entries.example.enable;
    package-source-does-not-change-enable-default-true = packageSourceEnabledByDefault.config.entries.example.enable;
    real-declarations-accepted = realDeclarationsAccepted;
    required-default-content-installed = requiredDefaultContent.text == "required package prose";
    required-empty-source-rejected = requiredEmptyFailed;
    same-default-priority-rejected = sameDefaultPriorityFailed;
    same-priority-rejected = samePriorityFailed;
    text-source-has-no-enable-option = !(builtins.hasAttr "enable" (unset.options.required.type.getSubOptions []));
    unset-entry-remains-disabled = !unset.config.entries.example.enable;
    unset-text-remains-empty = unset.config.entries.example.text == "";
  };
in {
  checks = lib.mapAttrs' (name: condition:
    lib.nameValuePair "factory-text-source-options-${name}"
    (mkTest "text-source-options-${name}" condition))
  tests;
}
