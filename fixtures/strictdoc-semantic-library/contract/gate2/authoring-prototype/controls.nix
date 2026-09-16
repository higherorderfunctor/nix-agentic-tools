{
  libPath ? /nix/store/j2r11kxv91yl5xqppy3vy84klwxjbz1i-source/lib,
  grammarPath ? ../../../../../packages/strictdoc-grammar/lib,
}: let
  lib = import libPath;
  grammar = import (grammarPath + "/grammar.nix") {inherit lib;};
  dsl = import ./dsl.nix {inherit grammar lib;};
  s = dsl.schema;
  c = dsl.constraint;
  model = import ../recommended.nix {
    inherit grammar;
    inherit (dsl) schema constraint;
  };
  forms = import ../composition.nix {
    inherit model;
    inherit (dsl) constraint;
  };
  compose = import ./compose.nix {inherit lib;};
  effective = compose {
    inherit (forms) contributions;
    required = ["reference/constraint/nativeDag"];
  };
  digest = value: builtins.hashString "sha256" (builtins.toJSON value);
  rejects = value: !(builtins.tryEval (builtins.deepSeq value (builtins.toJSON value))).success;
  target = builtins.head forms.direct.rules;
  changed = target // {config = target.config // {allowed = [model.elements.BAZ.ref];};};
  countId = "reference/element/BAR/relation/Parent/P/cardinality";
  count = builtins.head (builtins.filter (r: r.id == countId) model.normalized.bundle.rules);
  disable = {
    action = "disable";
    id = countId;
    expect = digest count;
    reason = "control";
  };
  base = [
    {
      origin = "base";
      bundle = model.normalized.bundle;
    }
  ];
  tiny = relation: predicate:
    s.grammar "tiny" (_: {
      elements.X = _self: {
        fields = [(grammar.dsl.field.required (grammar.dsl.field.str "UID"))];
        relations.P.parent = {reverseRole = "P_back";} // relation;
        constraints.test = predicate;
      };
    });
  nativeId = "reference/constraint/nativeDag";
  native = builtins.head (builtins.filter (r: r.id == nativeId) model.normalized.bundle.rules);
  replaceNative = replacement:
    compose {
      contributions = base;
      required = [nativeId];
      edits = [
        {
          action = "replace";
          id = nativeId;
          expect = digest native;
          reason = "native meaning regression";
          rule = replacement;
        }
      ];
    };
  compound = c.on model.elements.FOO.relations.R.parent {
    compound = rel:
      c.anyOf [
        (c.allOf [(model.views.visibility.canSee rel.owner rel.target) (c.isNodeType rel.target model.elements.FOO)])
        (model.views.visibility.canSee rel.owner rel.target)
      ];
  };
  compoundRule = builtins.head compound.rules;
  forestRule = builtins.head (builtins.filter (r: r.id == "reference/view/H/valid") model.normalized.bundle.rules);
  forestView = builtins.head model.normalized.bundle.views;
  compoundBase = [
    {
      origin = "compound";
      bundle = {
        rules = compound.rules ++ [forestRule];
        views = [forestView];
      };
    }
  ];
  disableDefinition = definition: {
    action = "disable";
    inherit (definition) id;
    expect = digest definition;
    reason = "compound dependency regression";
  };
  controls = {
    compoundHierarchyInput =
      compoundRule.inputs."view:reference/view/H"
      == {
        from = "view:reference/view/H";
        schema = "sdoc-policy.forest/v1";
      };
    compoundValidDependency = compoundRule.after == ["reference/view/H/valid"];
    compoundWithoutViewRejected = rejects (compose {
      contributions = compoundBase;
      edits = [(disableDefinition forestView)];
    });
    compoundWithoutValidityRejected = rejects (compose {
      contributions = compoundBase;
      edits = [(disableDefinition forestRule)];
    });
    compoundWithoutBothRejected = rejects (compose {
      contributions = compoundBase;
      edits = map disableDefinition [forestRule forestView];
    });
    compoundWithDependenciesAccepted = !(rejects (compose {contributions = compoundBase;}));
    nativeConstantReplacementRejected = rejects (replaceNative ((builtins.head (c.on model.elements.FOO {noop = _: c.constant true;}).rules) // {id = nativeId;}));
    nativeNarrowedConfigRejected = rejects (replaceNative (native // {config = {select = model.elements.FOO.ref;};}));
    nativeBeforeInputRejected = rejects (replaceNative (native
      // {
        inputs.candidate = {
          from = "before";
          schema = "sdoc-policy.model/v1";
        };
      }));
    nativeMissingCapabilityRejected = rejects (replaceNative (native // {needs = ["model.resolved-parent-child/v1"];}));
    nativeWrongScopeRejected = rejects (replaceNative (native // {scope = "document";}));
    nativeEquivalentReplacementAccepted = !(rejects (replaceNative native));
    nativeAdditionalCapabilityAccepted = !(rejects (replaceNative (native // {needs = native.needs ++ ["additional-diagnostic/v1"];})));
    nativeInvalidOriginalRejected = rejects (compose {
      contributions = [
        {
          origin = "invalid-native-contract";
          bundle = {
            rules = [(native // {config = {role = "H";};})];
            views = [];
          };
        }
      ];
      required = [nativeId];
    });
    declarationConflictsRejected = rejects (compose {
      contributions =
        base
        ++ [
          {
            origin = "conflicting-schema-contribution";
            bundle = {
              rules = [];
              views = [];
              declarations = [((builtins.head model.normalized.bundle.declarations) // {native = {};})];
            };
          }
        ];
    });
    declarationDuplicatesRetained = let
      repeated = compose {contributions = base ++ base;};
      declarationId = (builtins.head model.normalized.bundle.declarations).id;
    in
      builtins.length (builtins.head (builtins.filter (p: p.id == declarationId) repeated.provenance)).origins == 2;
    adjacentExternalDirect = forms.external == forms.direct;
    adjacentMatchesDirect = builtins.elem target model.normalized.bundle.rules;
    finiteSerialization = builtins.stringLength (builtins.toJSON model.normalized) > 0;
    grammarRendering = lib.hasInfix "TYPE: SingleChoice(false, true)" model.rendered;
    orderedFields = map (f: (builtins.head (builtins.attrValues f)).title) (builtins.elemAt model.normalized.grammar 2).fields == ["UID" "FLAG"];
    contextualRoles = model.elements.FOO.relations.R.parent.ref != model.elements.BAZ.relations.R.parent.ref;
    booleanMetadata = (builtins.head model.normalized.semanticTypes.fields).semantic.decode.false == false;
    typedScriptDefault =
      (s.field.string "CREATOR" {
        default = s.default.script {
          argv = ["/configured/bin/git-identity-default"];
          timeoutMs = 1000;
        };
      }).default.script.timeoutMs
      == 1000;
    rejectsMalformedScriptDefault = rejects (s.field.boolean "FLAG" {
      default = s.default.script {
        argv = [];
        timeoutMs = 1000;
      };
    });
    booleanDefault = (builtins.head model.normalized.semanticTypes.fields).default.literal == false;
    stringDefault = (s.field.string "TEXT" {default = s.default.literal "false";}).default.literal == "false";
    rejectsStringBoolean = rejects (s.field.boolean "FLAG" {default = s.default.literal "false";});
    rejectsBooleanString = rejects (s.field.string "TEXT" {default = s.default.literal false;});
    rejectsUnknownSemanticOption = rejects (s.field.boolean "FLAG" {undocumented = true;});
    rejectsNativeSemanticKeys = rejects (grammar.check.field {
      singleChoice = {
        title = "FLAG";
        required = true;
        choices = ["false" "true"];
        semantic = {type = "boolean";};
      };
    });
    rejectsReversedVisibility = rejects (c.on model.elements.FOO.relations.R.parent {
      reversed = rel: model.views.visibility.canSee rel.target rel.owner;
    });
    rejectsReversedBridge = rejects (c.on model.elements.BAR {
      reversed = record: model.views.visibility.canDescend (c.only record.relations.Q.child).target (c.only record.relations.P.parent).target;
    });
    rejectsRawBoolean = rejects (c.on model.elements.FOO.relations.R.parent {bad = rel: rel.owner == rel.target;});
    rejectsNixBooleanCombinator = rejects (c.on model.elements.FOO.relations.R.parent {bad = _rel: true;});
    acceptsExplicitConstant = (builtins.head (c.on model.elements.FOO {constant = _record: c.constant true;}).rules).config.expression.op == "constant";
    acceptsPredicateCombinators =
      (builtins.head
        (c.on model.elements.FOO.relations.R.parent {
          either = rel: c.anyOf [(c.isNodeType rel.target model.elements.FOO) (c.isNodeType rel.target model.elements.BAZ)];
        }).rules).config.expression.op
      == "anyOf";
    rejectsElementAsNode = rejects (c.isNodeType model.elements.FOO model.elements.FOO);
    rejectsNodeAsElement = rejects (c.on model.elements.FOO.relations.R.parent {bad = rel: c.isNodeType rel.target rel.owner;});
    rejectsWrongFieldOwner = rejects (c.on model.elements.BAR {bad = record: c.fieldValue record model.elements.FOO.fields.FLAG;});
    rejectsNativeStringAsBoolean = rejects (c.on model.elements.FOO {bad = record: c.fieldValue record model.elements.FOO.fields.UID;});
    rejectsUncheckedSingleton = rejects (tiny {} (record: c.eq (c.only record.relations.P.parent).target record)).normalized;
    checkedSingleton = !(rejects (tiny {cardinality = c.exactly 1;} (record: c.eq (c.only record.relations.P.parent).target record)).normalized);
    deduplicatedOrigins = builtins.length (builtins.head (builtins.filter (p: p.id == target.id) effective.provenance)).origins == 3;
    contributionOrderIndependent = (compose {contributions = lib.reverseList forms.contributions;}).digest == effective.digest;
    dependencyCycleRejected = rejects (compose {
      contributions = [
        {
          origin = "cycle";
          bundle = {
            views = [];
            rules = [
              (target
                // {
                  id = "cycle-a";
                  after = ["cycle-b"];
                })
              (target
                // {
                  id = "cycle-b";
                  after = ["cycle-a"];
                })
            ];
          };
        }
      ];
    });
    conflictsDoNotOverride = rejects (compose {
      contributions = [
        {
          origin = "a";
          bundle = forms.direct;
        }
        {
          origin = "b";
          bundle = {
            rules = [changed];
            views = [];
          };
        }
      ];
    });
    disableDependencyRejected = rejects (compose {
      contributions = base;
      edits = [disable];
    });
    weakenedSingletonRejected = rejects (compose {
      contributions = base;
      edits = [
        {
          action = "replace";
          inherit (count) id;
          expect = digest count;
          reason = "control";
          rule = count // {config = count.config // {min = 0;};};
        }
      ];
    });
    staleEditRejected = rejects (compose {
      contributions = base;
      edits = [(disable // {expect = "stale";})];
    });
    competingEditsRejected = rejects (compose {
      contributions = base;
      edits = [disable disable];
    });
    unknownEditRejected = rejects (compose {
      contributions = base;
      edits = [(disable // {id = "unknown";})];
    });
    replacementAccepted =
      (compose {
        contributions = base;
        edits = [
          {
            action = "replace";
            inherit (target) id;
            expect = digest target;
            rule = changed;
            reason = "explicit consumer change";
          }
        ];
      }).digest
      != (compose {contributions = base;}).digest;
    optionalDisableAccepted =
      builtins.length
      (compose {
        contributions = base;
        edits = [
          {
            action = "disable";
            inherit (target) id;
            expect = digest target;
            reason = "explicit consumer choice";
          }
        ];
      }).definitions
      == builtins.length effective.definitions - 1;
    nativeDisableRejected = rejects (compose {
      contributions = base;
      required = ["reference/constraint/nativeDag"];
      edits = let
        native = builtins.head (builtins.filter (r: r.id == "reference/constraint/nativeDag") model.normalized.bundle.rules);
      in [
        {
          action = "disable";
          inherit (native) id;
          expect = digest native;
          reason = "control";
        }
      ];
    });
    tailoringWithoutHierarchy = let
      t = import ../native-tailoring.nix {
        inherit grammar;
        inherit (dsl) schema constraint;
      };
    in
      t.normalized.bundle.views == [] && builtins.stringLength t.rendered > 0;
    fieldAlternative = let
      a = import ../field-alternative.nix {
        inherit grammar;
        inherit (dsl) schema constraint;
      };
    in
      builtins.stringLength (builtins.toJSON a.model.normalized) > 0 && a.customRule.config.virtualConnectivity.createAuthoredRelations == false;
  };
in
  assert lib.all (v: v) (builtins.attrValues controls); {
    inherit controls;
    count = builtins.length (builtins.attrNames controls);
  }
