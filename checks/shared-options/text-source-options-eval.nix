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
  hasState = value: enable: text: {inherit (value) enable text;} == {inherit enable text;};

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
  defaultProse = optionalType {defaultContent.text = "package prose";};
in {
  checks = {
    factory-text-source-options-content = mkTest "text-source-options-content" (
      let
        defaultSource = {source = lib.mkDefault source;};
      in
        checkRows "effective text source content" {
          "a null source cancels the default source without enabling" =
            hasState (readEntry {} [defaultSource {source = null;}]) false "";
          "a package source derives text without enabling" =
            hasState (readEntry {} [defaultSource]) false "packaged prose\n";
          "consumer text beats the default source and enables" =
            hasState (readEntry {} [defaultSource {text = "consumer prose";}]) true "consumer prose";
          "empty default-priority text does not enable even with enableOnMkDefault" =
            !(readEntry {enableOnMkDefault = true;} [{text = lib.mkDefault "";}]).enable;
          "explicit empty text beats the package source without enabling" =
            hasState (readEntry {defaultContent.source = source;} [{text = "";}]) false "";
          "explicit enable does not discard inline package defaults" =
            hasState (readValue defaultProse {enable = true;}) true "package prose";
          "forced source beats consumer text" =
            readText {} [
              {
                source = lib.mkForce source;
                text = "consumer prose";
              }
            ]
            == "packaged prose\n";
          "package prose alone does not enable" = hasState (readValue defaultProse {}) false "package prose";
          "required record cannot expose an enable switch" = !((requiredType {}).getSubOptions [] ? enable);
          "required record does not discard inline package defaults" =
            (readValue (requiredType {defaultContent.text = "required package prose";}) {}).text == "required package prose";
          # Without enableOnMkDefault, the same default-priority source stays
          # dormant (the package-source row above).
          "source at default priority is not ignored by enableOnMkDefault" =
            (readEntry {enableOnMkDefault = true;} [defaultSource]).enable;
          "text at default priority is not ignored by enableOnMkDefault" =
            (readEntry {enableOnMkDefault = true;} [{text = lib.mkDefault "default prose";}]).enable;
        }
    );

    factory-text-source-options-outer-defaults = mkTest "text-source-options-outer-defaults" (
      let
        # The repository gate must reject this declaration, and its scanner
        # must report exactly the offending option path.
        reportsOuterDefault = eval: path: let
          invalid = eval {text = "bad outer default";};
        in
          invalidTextSourceDefaults [] invalid.options
          == [path]
          && rejectsChange checkTextSourceDefaults {
            inherit invalid;
            expected = true;
            valid = eval {};
          };
        reportsDirect = type: reportsOuterDefault (default: evaluate type default []) ["value"];
        # A nonempty pool default is legal; the guard must still descend to the
        # text-source declaration inside each pooled record.
        nestedDefault = default:
          evaluate (lib.types.attrsOf (lib.types.submodule {
            options.prose = lib.mkOption {
              inherit default;
              type = defaultProse;
            };
          })) {example = {};} [];
      in
        checkRows "outer text source defaults" {
          "reports nonempty outer defaults even after extending the text-source submodule" =
            reportsDirect (aiTypes.extendSubmodule (optionalType {}) {options.extra = lib.mkOption {type = lib.types.bool;};});
          "reports the nested declaration, not the nonempty pool default" = reportsOuterDefault nestedDefault ["value" "prose"];
          "reports nonempty outer defaults even on a required declaration with no enable field" = reportsDirect (requiredType {});
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
          "required records require nonempty content" = rejectsChange (fields: (readValue (requiredType {}) fields).text) {
            expected = "required prose";
            invalid = {};
            valid.text = "required prose";
          };
          # Keep the original tie at mkDefault; restricting conflict detection
          # to ordinary consumer priority would let this pair through.
          "source and text at equal default priority conflict" = rejectsChange (readText {}) {
            expected = "packaged prose\n";
            invalid = [
              {
                source = lib.mkDefault source;
                text = lib.mkDefault "authored prose";
              }
            ];
            valid = [{source = lib.mkDefault source;}];
          };
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
        "devenv declarations do not put package prose in outer defaults" = checkTextSourceDefaults (evalDevenv {});
        "Home Manager declarations do not put package prose in outer defaults" = checkTextSourceDefaults (evalHm {});
      }
    );
  };
}
