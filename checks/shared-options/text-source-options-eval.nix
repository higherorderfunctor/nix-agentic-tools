# Evaluation contracts for lib.ai.types text sources.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
  inherit (harness) checkRows evalDevenv evalHm rejectsChange;
  aiTypes = import ../../lib/ai/types.nix {inherit lib;};
  agent = import ../../lib/ai/agent.nix {inherit lib;};
  source = builtins.toFile "text-source-options-source" "packaged prose\n";

  evaluate = type: default: modules:
    lib.evalModules {modules = [{options.value = lib.mkOption {inherit type default;};}] ++ modules;};
  optionalType = args: aiTypes.optionalTextSource ({description = "entry prose";} // args);
  requiredType = args: aiTypes.textSource ({description = "required prose";} // args);

  # Exercise records inside the keyed pool as well as standalone declarations.
  evaluateEntries = args: definitions:
    (evaluate (lib.types.attrsOf (optionalType args)) {}
      (map (value: {inherit value;}) definitions)).config.value;
  readEntry = args: definitions:
    (evaluateEntries args (map (example: {inherit example;}) definitions)).example;
  readText = args: definitions: (readEntry args definitions).text;
  readValue = type: fields: (evaluate type {} [{value = fields;}]).config.value;
  state = value: {inherit (value) enable text;};

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
  rejectsOuterDefault = read:
    rejectsChange read {
      expected = true;
      invalid.text = "bad outer default";
      valid = {};
    };
  rejectsDirectDefault = type:
    rejectsOuterDefault (default: checkTextSourceDefaults (evaluate type default []));
  defaultProse = optionalType {defaultContent.text = "package prose";};
in {
  checks = {
    factory-text-source-options-content = mkTest "text-source-options-content" (
      checkRows "effective text source content" {
        "a new consumer key enables its inline prose" = (evaluateEntries {} [{new.text = "new consumer prose";}]).new.enable;
        "a null source suppresses the package source without enabling" =
          state (readEntry {} [{source = lib.mkDefault source;} {source = null;}])
          == {
            enable = false;
            text = "";
          };
        "a package source derives text without enabling" =
          state (readEntry {} [{source = lib.mkDefault source;}])
          == {
            enable = false;
            text = "packaged prose\n";
          };
        "a package source preserves a true enable default" =
          (readEntry {enableDefault = true;} [{source = lib.mkDefault source;}]).enable;
        "an explicit empty string suppresses the package source while disabled" =
          state (readEntry {defaultContent.source = source;} [{text = "";}])
          == {
            enable = false;
            text = "";
          };
        "consumer source replaces package prose" = (readValue defaultProse {inherit source;}).text == "packaged prose\n";
        "consumer text replaces package source and enables" =
          state (readEntry {} [{source = lib.mkDefault source;} {text = "consumer prose";}])
          == {
            enable = true;
            text = "consumer prose";
          };
        "empty text at default priority does not enable with enableOnMkDefault" =
          !(readEntry {enableOnMkDefault = true;} [{text = lib.mkDefault "";}]).enable;
        "explicit disable keeps consumer text" =
          state (readEntry {} [
            {
              enable = false;
              text = "consumer prose";
            }
          ])
          == {
            enable = false;
            text = "consumer prose";
          };
        "explicit enable preserves package prose" =
          state (readValue defaultProse {enable = true;})
          == {
            enable = true;
            text = "package prose";
          };
        "forced source beats consumer text" =
          readText {} [
            {
              source = lib.mkForce source;
              text = "consumer prose";
            }
          ]
          == "packaged prose\n";
        "package prose alone stays disabled" =
          state (readValue defaultProse {})
          == {
            enable = false;
            text = "package prose";
          };
        "plain source beats default text" =
          readText {} [
            {
              inherit source;
              text = lib.mkDefault "default prose";
            }
          ]
          == "packaged prose\n";
        "required record has no enable option" = !((requiredType {}).getSubOptions [] ? enable);
        "required record installs defaultContent" =
          (readValue (requiredType {defaultContent.text = "required package prose";}) {}).text == "required package prose";
        # Without enableOnMkDefault, the same default-priority source stays
        # dormant (the package-source row above).
        "source at default priority enables with enableOnMkDefault" =
          (readEntry {enableOnMkDefault = true;} [{source = lib.mkDefault source;}]).enable;
        "text at default priority enables with enableOnMkDefault" =
          (readEntry {enableOnMkDefault = true;} [{text = lib.mkDefault "default prose";}]).enable;
        "unset optional entry stays empty and disabled" =
          state (readEntry {} [{}])
          == {
            enable = false;
            text = "";
          };
      }
    );

    factory-text-source-options-outer-defaults = mkTest "text-source-options-outer-defaults" (
      let
        # A nonempty pool default is legal; the guard must still descend to the
        # text-source declaration inside each pooled record.
        checkNestedDefault = default:
          checkTextSourceDefaults (evaluate (lib.types.attrsOf (lib.types.submodule {
            options.prose = lib.mkOption {
              inherit default;
              type = defaultProse;
            };
          })) {example = {};} []);
      in
        checkRows "outer text source defaults" {
          "direct optional declaration cannot use a nonempty outer default" = rejectsDirectDefault defaultProse;
          "extended declaration cannot use a nonempty outer default" =
            rejectsDirectDefault (aiTypes.extendSubmodule (optionalType {}) {options.extra = lib.mkOption {type = lib.types.bool;};});
          "nested declaration cannot use a nonempty outer default even in a defaulted pool" = rejectsOuterDefault checkNestedDefault;
          "reimported declaration cannot use a nonempty outer default" =
            rejectsDirectDefault (lib.types.submodule {imports = (optionalType {}).getSubModules;});
          "required declaration cannot use a nonempty outer default" = rejectsDirectDefault (requiredType {});
        }
    );

    factory-text-source-options-restrictions = mkTest "text-source-options-restrictions" (
      let
        # Force only the field whose merge enforces the named restriction.
        # If bare strings become legal, return them instead of failing on .text.
        readInstructions = instructions: let
          observed =
            (readValue agent.semanticAgentType {
              inherit instructions;
              description = "Instruction shape probe";
            }).instructions;
        in
          if builtins.isAttrs observed
          then observed.text
          else observed;
        rejectsTie = wrap:
          rejectsChange (readText {}) {
            expected = "packaged prose\n";
            invalid = [
              {
                source = wrap source;
                text = wrap "authored prose";
              }
            ];
            valid = [{source = wrap source;}];
          };
      in
        checkRows "text source restrictions" {
          "agent instructions require a record, not a bare string" = rejectsChange readInstructions {
            expected = "typed instructions";
            invalid = "typed instructions";
            valid.text = "typed instructions";
          };
          "an enabled record rejects empty inline text that overrides its package source" =
            rejectsChange (readText {
              defaultContent.source = source;
              enableDefault = true;
            }) {
              expected = "consumer prose";
              invalid = [{text = "";}];
              valid = [{text = "consumer prose";}];
            };
          "enableOnMkDefault cannot be declared with defaultContent" = rejectsChange (enableOnMkDefault:
            (readValue (optionalType {
              inherit enableOnMkDefault;
              defaultContent.text = "package prose";
            }) {}).text) {
            expected = "package prose";
            invalid = true;
            valid = false;
          };
          "explicitly enabled records require nonempty content" = rejectsChange (readText {}) {
            expected = "consumer prose";
            invalid = [{enable = true;}];
            valid = [
              {
                enable = true;
                text = "consumer prose";
              }
            ];
          };
          "required records require nonempty content" = rejectsChange (fields: (readValue (requiredType {}) fields).text) {
            expected = "required prose";
            invalid = {};
            valid.text = "required prose";
          };
          "source and text at equal consumer priority conflict" = rejectsTie lib.id;
          "source and text at equal default priority conflict" = rejectsTie lib.mkDefault;
        }
    );

    # This repository guard covers direct text-source submodule declarations
    # reachable through the aggregate Home Manager and devenv harness imports,
    # including submodules nested below container options. It deliberately does
    # not reject defaults on a wrapping type itself (such as attrsOf or nullOr),
    # because pool-level container defaults are valid. It also cannot inspect
    # downstream consumers or custom module sets that the harnesses do not import.
    factory-text-source-options-real-declarations-accepted = mkTest "text-source-options-real-declarations-accepted" (
      checkRows "real text source declarations" {
        "devenv uses defaultContent for package prose" = checkTextSourceDefaults (evalDevenv {});
        "Home Manager uses defaultContent for package prose" = checkTextSourceDefaults (evalHm {});
      }
    );
  };
}
