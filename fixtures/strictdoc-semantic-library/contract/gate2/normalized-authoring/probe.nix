{
  libPath,
  grammarDir ? ../../../../../packages/strictdoc-grammar/lib,
}: let
  lib = import libPath;
  grammar = (import grammarDir).ai.strictdocGrammar {inherit lib;};
  g = grammar.dsl;
  faithful = import (grammarDir + "/faithful.nix");
  force = x: builtins.deepSeq x x;
  accepts = x: (builtins.tryEval (force x)).success;
  field = g.field.required (g.field.mk "string" "FLAG" {humanTitle = "Display flag";});
  element =
    g.el "PROBE" {
      isComposite = true;
      prefix = "P-";
      viewStyle = "Table";
    } {
      fields = [field (g.field.one "STATUS" ["Draft" "Ready (reviewed)"])];
      relations = [(g.rel.parent "Refines" "Refined_By")];
    };
  checked = grammar.check.elements [element];
  rendered = grammar.render [element];
  booleanNames = builtins.filter (name: builtins.hasAttr name g.field) ["bool" "boolean"];
in {
  inherit checked element field rendered;
  source = {
    grammar = toString grammarDir;
    nixpkgsLib = toString libPath;
  };
  inventory = {
    barrel = builtins.attrNames grammar;
    dsl = builtins.attrNames g;
    field = builtins.attrNames g.field;
    relation = builtins.attrNames g.rel;
    normalized = builtins.attrNames grammar.normalized;
    fieldAlternatives = map (alternative: alternative.key) grammar.normalized.productions.GrammarElementField.alternatives;
    inherit booleanNames;
    functors = {
      barrel = grammar ? __functor;
      dsl = g ? __functor;
      field = g.field ? __functor;
      normalized = grammar.normalized ? __functor;
    };
  };
  controls = {
    requiredBoolAccepted = accepts (grammar.check.field (g.field.mk "string" "FLAG" {required = true;}));
    requiredStringRejected = !(accepts (grammar.check.field (g.field.mk "string" "FLAG" {required = "True";})));
    compositeBoolAccepted = accepts (grammar.check.element element);
    compositeStringRejected = !(accepts (grammar.check.element (element // {isComposite = "True";})));
    stringChoiceAccepted = accepts (grammar.check.field (g.field.one "FLAG" ["false" "true"]));
    booleanChoiceRejected = !(accepts (grammar.check.field (g.field.one "FLAG" [false true])));
    inventedBoolKindRejected = !(accepts (grammar.check.field (g.field.mk "bool" "FLAG" {})));
    inventedBooleanKindRejected = !(accepts (grammar.check.field (g.field.mk "boolean" "FLAG" {})));
    rawIdentity = g.field.raw field == field;
    rawDoesNotBypassValidation =
      !(accepts (grammar.check.field (g.field.raw {
        string = {
          title = "FLAG";
          required = "True";
        };
      })));
    extraFieldMetadataRejected = !(accepts (grammar.check.field (g.field.mk "string" "FLAG" {schemaMetadata = {valueType = "bool";};})));
    renderEqualsCheckThenEmit = rendered == grammar.emit.grammar checked;
    defaultOptional = (grammar.check.field (g.field.str "FLAG")).string.required == false;
    normalizedBooleanChoice = grammar.normalized.types.BooleanChoice.check true && !(grammar.normalized.types.BooleanChoice.check "True");
  };
  hypotheticalBoolConstructors = builtins.listToAttrs (map (name: {
      inherit name;
      value = g.field.${name} "FLAG";
    })
    booleanNames);
  metadata = {
    sourcePreserved = lib.all (name: grammar.normalized.meta.${name} == faithful.meta.${name}) (builtins.attrNames faithful.meta);
    productionsPreserved = grammar.normalized.productions == faithful.productions;
    faithful = faithful.meta;
    normalized = grammar.normalized.meta;
    booleanConverter = grammar.normalized.converters.registry.boolean or null;
    converterSections = builtins.attrNames grammar.normalized.converters;
    boolEncoded = map grammar.emit.encoders.bool [false true];
    humanTitleChecked = (builtins.head (builtins.head checked).fields).string.humanTitle;
  };
}
