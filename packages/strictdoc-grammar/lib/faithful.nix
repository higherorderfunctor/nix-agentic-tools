# GENERATED FILE — DO NOT EDIT BY HAND.
#
# Written by packages/strictdoc-grammar/extract/extract.py from strictdoc's own
# grammar definition (`SDocGrammarBuilder.create_grammar_grammar()`), reached
# through both the textx metamodel and the arpeggio parser tree. A drift check
# regenerates and diffs, so a stale surface is a red check.
#
# FAITHFUL means: exactly what a `.sgra` file can express, with no opinion of
# ours in it. A value constrained by a regex is a string carrying that regex.
# Opinions belong one layer up, in ./normalized.nix.
#
# Three things to know before reading:
#
# * `types.<Rule>` is one entry per grammar rule reachable from the root rule.
#   Elements, fields and relations are LISTS, never attribute sets: the grammar
#   has all three as ordered lists and enforces the order, while Nix sorts
#   attribute-set keys and would silently reorder the emitted file.
# * A union (field kind, relation type) is `lib.types.attrTag`, not a record
#   with optional extras. It is a genuine discriminated union, and `addCheck`
#   silently never fires inside a submodule, so a post-validation guard would
#   not run.
# * Every pattern carries `source` (upstream's Python regex, verbatim and
#   authoritative) and `ere` (the same constraint in the POSIX dialect
#   `builtins.match` accepts), plus the named `rewrites` that got from one to
#   the other and any `deny` prefixes a lookahead became. The rewrites are
#   exact, never widening.
{lib}: let
  t = lib.types;
  inherit (lib) mkOption;
  patternType = p:
  # `p.ere` is p.source in the dialect `builtins.match` speaks; `p.deny`
  # carries the negative lookahead groups that dialect cannot spell, checked
  # as prefix rejections instead. `.*` is deliberate: Nix's `.` matches a
  # newline, so a denied prefix is caught wherever the rest of the string
  # goes.
    if p.deny == []
    then t.strMatching p.ere
    else
      t.addCheck (t.strMatching p.ere)
      (s: !(lib.any (d: builtins.match "(${d}).*" s != null) p.deny));
in {
  meta = {
    generated = true;
    grammarSha256 = "4adcdb056ac4a51fb5d058699614291a7692b730b60627573e202dffd118d211";
    metamodelRuleCount = 43;
    rootRule = "DocumentGrammarWrapper";
    ruleCount = 19;
    strictdocVersion = "0.28.3";
  };
  productions = {
    BooleanChoice = {
      alternatives = [];
      items = [
        {
          branches = [
            [
              {
                kind = "literal";
                text = "True";
              }
            ]
            [
              {
                kind = "literal";
                text = "False";
              }
            ]
          ];
          kind = "choice";
        }
      ];
      txType = "match";
    };
    ChoiceOption = {
      alternatives = [];
      items = [
        {
          kind = "regex";
          pattern = "([\"])[^,]+\\1|[^,()\"]+";
        }
      ];
      txType = "match";
    };
    ChoiceOptionXs = {
      alternatives = [];
      items = [
        {
          kind = "rule";
          name = "ChoiceOption";
        }
      ];
      txType = "match";
    };
    DocumentGrammar = {
      alternatives = [];
      items = [
        {
          kind = "literal";
          text = "[GRAMMAR]";
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          branches = [
            [
              {
                items = [
                  {
                    kind = "literal";
                    text = "ELEMENTS:";
                  }
                  {
                    kind = "regex";
                    pattern = "\\r?\\n";
                  }
                  {
                    attr = "elements";
                    kind = "assign";
                    multiplicity = "oneOrMore";
                    option = "elements";
                    value = {
                      kind = "rule";
                      name = "GrammarElement";
                    };
                  }
                ];
                kind = "optional";
              }
            ]
            [
              {
                items = [
                  {
                    kind = "literal";
                    text = "IMPORT_FROM_FILE: ";
                  }
                  {
                    attr = "import_from_file";
                    kind = "assign";
                    multiplicity = "one";
                    option = "importFromFile";
                    value = {
                      kind = "pattern";
                      pattern = ".+\$";
                    };
                  }
                  {
                    kind = "regex";
                    pattern = "\\r?\\n";
                  }
                ];
                kind = "optional";
              }
            ]
          ];
          kind = "choice";
        }
      ];
      txType = "common";
    };
    DocumentGrammarWrapper = {
      alternatives = [];
      items = [
        {
          attr = "grammar";
          kind = "assign";
          multiplicity = "one";
          option = "grammar";
          value = {
            kind = "rule";
            name = "DocumentGrammar";
          };
        }
      ];
      txType = "common";
    };
    FieldName = {
      alternatives = [];
      items = [
        {
          kind = "regex";
          pattern = "(?!^UID)(?!^RELATIONS)[A-Z]+[A-Za-z0-9_\\-]*";
        }
      ];
      txType = "match";
    };
    GrammarElement = {
      alternatives = [];
      items = [
        {
          kind = "literal";
          text = "- TAG: ";
        }
        {
          attr = "tag";
          kind = "assign";
          multiplicity = "one";
          option = "tag";
          value = {
            kind = "rule";
            name = "RequirementType";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          items = [
            {
              kind = "literal";
              text = "  PROPERTIES:";
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
            {
              items = [
                {
                  kind = "literal";
                  text = "    IS_COMPOSITE: ";
                }
                {
                  attr = "property_is_composite";
                  kind = "assign";
                  multiplicity = "one";
                  option = "isComposite";
                  value = {
                    kind = "pattern";
                    pattern = "(True|False)";
                  };
                }
                {
                  kind = "regex";
                  pattern = "\\r?\\n";
                }
              ];
              kind = "optional";
            }
            {
              items = [
                {
                  kind = "literal";
                  text = "    PREFIX: ";
                }
                {
                  attr = "property_prefix";
                  kind = "assign";
                  multiplicity = "one";
                  option = "prefix";
                  value = {
                    kind = "pattern";
                    pattern = ".*";
                  };
                }
                {
                  kind = "regex";
                  pattern = "\\r?\\n";
                }
              ];
              kind = "optional";
            }
            {
              items = [
                {
                  kind = "literal";
                  text = "    VIEW_STYLE: ";
                }
                {
                  attr = "property_view_style";
                  kind = "assign";
                  multiplicity = "one";
                  option = "viewStyle";
                  value = {
                    kind = "pattern";
                    pattern = "(Plain|Simple|Inline|Narrative|Table|Zebra)";
                  };
                }
                {
                  kind = "regex";
                  pattern = "\\r?\\n";
                }
              ];
              kind = "optional";
            }
          ];
          kind = "optional";
        }
        {
          kind = "literal";
          text = "  FIELDS:";
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          attr = "fields";
          kind = "assign";
          multiplicity = "oneOrMore";
          option = "fields";
          value = {
            kind = "rule";
            name = "GrammarElementField";
          };
        }
        {
          items = [
            {
              kind = "literal";
              text = "  RELATIONS:";
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
            {
              attr = "relations";
              kind = "assign";
              multiplicity = "oneOrMore";
              option = "relations";
              value = {
                kind = "rule";
                name = "GrammarElementRelation";
              };
            }
          ];
          kind = "optional";
        }
      ];
      txType = "common";
    };
    GrammarElementField = {
      alternatives = [
        {
          key = "string";
          rule = "GrammarElementFieldString";
        }
        {
          key = "singleChoice";
          rule = "GrammarElementFieldSingleChoice";
        }
        {
          key = "multipleChoice";
          rule = "GrammarElementFieldMultipleChoice";
        }
        {
          key = "tag";
          rule = "GrammarElementFieldTag";
        }
      ];
      items = [
        {
          branches = [
            [
              {
                kind = "rule";
                name = "GrammarElementFieldString";
              }
            ]
            [
              {
                kind = "rule";
                name = "GrammarElementFieldSingleChoice";
              }
            ]
            [
              {
                kind = "rule";
                name = "GrammarElementFieldMultipleChoice";
              }
            ]
            [
              {
                kind = "rule";
                name = "GrammarElementFieldTag";
              }
            ]
          ];
          kind = "choice";
        }
      ];
      txType = "abstract";
    };
    GrammarElementFieldMultipleChoice = {
      alternatives = [];
      items = [
        {
          kind = "literal";
          text = "  - TITLE: ";
        }
        {
          attr = "title";
          kind = "assign";
          multiplicity = "one";
          option = "title";
          value = {
            kind = "rule";
            name = "FieldName";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          items = [
            {
              kind = "literal";
              text = "    HUMAN_TITLE: ";
            }
            {
              attr = "human_title";
              kind = "assign";
              multiplicity = "one";
              option = "humanTitle";
              value = {
                kind = "rule";
                name = "SingleLineString";
              };
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
          ];
          kind = "optional";
        }
        {
          kind = "literal";
          text = "    TYPE: MultipleChoice";
        }
        {
          kind = "literal";
          text = "(";
        }
        {
          attr = "options";
          kind = "assign";
          multiplicity = "one";
          option = "options";
          value = {
            kind = "rule";
            name = "ChoiceOption";
          };
        }
        {
          attr = "options";
          kind = "assign";
          multiplicity = "zeroOrMore";
          option = "options";
          value = {
            kind = "rule";
            name = "ChoiceOptionXs";
          };
        }
        {
          kind = "literal";
          text = ")";
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          kind = "literal";
          text = "    REQUIRED: ";
        }
        {
          attr = "required";
          kind = "assign";
          multiplicity = "one";
          option = "required";
          value = {
            kind = "rule";
            name = "BooleanChoice";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
      ];
      txType = "common";
    };
    GrammarElementFieldSingleChoice = {
      alternatives = [];
      items = [
        {
          kind = "literal";
          text = "  - TITLE: ";
        }
        {
          attr = "title";
          kind = "assign";
          multiplicity = "one";
          option = "title";
          value = {
            kind = "rule";
            name = "FieldName";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          items = [
            {
              kind = "literal";
              text = "    HUMAN_TITLE: ";
            }
            {
              attr = "human_title";
              kind = "assign";
              multiplicity = "one";
              option = "humanTitle";
              value = {
                kind = "rule";
                name = "SingleLineString";
              };
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
          ];
          kind = "optional";
        }
        {
          kind = "literal";
          text = "    TYPE: SingleChoice";
        }
        {
          kind = "literal";
          text = "(";
        }
        {
          attr = "options";
          kind = "assign";
          multiplicity = "one";
          option = "options";
          value = {
            kind = "rule";
            name = "ChoiceOption";
          };
        }
        {
          attr = "options";
          kind = "assign";
          multiplicity = "zeroOrMore";
          option = "options";
          value = {
            kind = "rule";
            name = "ChoiceOptionXs";
          };
        }
        {
          kind = "literal";
          text = ")";
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          kind = "literal";
          text = "    REQUIRED: ";
        }
        {
          attr = "required";
          kind = "assign";
          multiplicity = "one";
          option = "required";
          value = {
            kind = "rule";
            name = "BooleanChoice";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
      ];
      txType = "common";
    };
    GrammarElementFieldString = {
      alternatives = [];
      items = [
        {
          kind = "literal";
          text = "  - TITLE: ";
        }
        {
          attr = "title";
          kind = "assign";
          multiplicity = "one";
          option = "title";
          value = {
            kind = "rule";
            name = "FieldName";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          items = [
            {
              kind = "literal";
              text = "    HUMAN_TITLE: ";
            }
            {
              attr = "human_title";
              kind = "assign";
              multiplicity = "one";
              option = "humanTitle";
              value = {
                kind = "rule";
                name = "SingleLineString";
              };
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
          ];
          kind = "optional";
        }
        {
          kind = "literal";
          text = "    TYPE: String";
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          kind = "literal";
          text = "    REQUIRED: ";
        }
        {
          attr = "required";
          kind = "assign";
          multiplicity = "one";
          option = "required";
          value = {
            kind = "rule";
            name = "BooleanChoice";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
      ];
      txType = "common";
    };
    GrammarElementFieldTag = {
      alternatives = [];
      items = [
        {
          kind = "literal";
          text = "  - TITLE: ";
        }
        {
          attr = "title";
          kind = "assign";
          multiplicity = "one";
          option = "title";
          value = {
            kind = "rule";
            name = "FieldName";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          items = [
            {
              kind = "literal";
              text = "    HUMAN_TITLE: ";
            }
            {
              attr = "human_title";
              kind = "assign";
              multiplicity = "one";
              option = "humanTitle";
              value = {
                kind = "rule";
                name = "SingleLineString";
              };
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
          ];
          kind = "optional";
        }
        {
          kind = "literal";
          text = "    TYPE: Tag";
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          kind = "literal";
          text = "    REQUIRED: ";
        }
        {
          attr = "required";
          kind = "assign";
          multiplicity = "one";
          option = "required";
          value = {
            kind = "rule";
            name = "BooleanChoice";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
      ];
      txType = "common";
    };
    GrammarElementRelation = {
      alternatives = [
        {
          key = "parent";
          rule = "GrammarElementRelationParent";
        }
        {
          key = "child";
          rule = "GrammarElementRelationChild";
        }
        {
          key = "file";
          rule = "GrammarElementRelationFile";
        }
      ];
      items = [
        {
          branches = [
            [
              {
                kind = "rule";
                name = "GrammarElementRelationParent";
              }
            ]
            [
              {
                kind = "rule";
                name = "GrammarElementRelationChild";
              }
            ]
            [
              {
                kind = "rule";
                name = "GrammarElementRelationFile";
              }
            ]
          ];
          kind = "choice";
        }
      ];
      txType = "abstract";
    };
    GrammarElementRelationChild = {
      alternatives = [];
      items = [
        {
          kind = "literal";
          text = "  - TYPE: ";
        }
        {
          attr = "relation_type";
          kind = "assign";
          multiplicity = "one";
          option = "type";
          value = {
            kind = "literal";
            text = "Child";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          items = [
            {
              kind = "literal";
              text = "    ROLE: ";
            }
            {
              attr = "relation_role";
              kind = "assign";
              multiplicity = "one";
              option = "role";
              value = {
                kind = "pattern";
                pattern = ".+";
              };
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
          ];
          kind = "optional";
        }
        {
          items = [
            {
              kind = "literal";
              text = "    REVERSE_ROLE: ";
            }
            {
              attr = "reverse_relation_role";
              kind = "assign";
              multiplicity = "one";
              option = "reverseRole";
              value = {
                kind = "pattern";
                pattern = ".+";
              };
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
          ];
          kind = "optional";
        }
      ];
      txType = "common";
    };
    GrammarElementRelationFile = {
      alternatives = [];
      items = [
        {
          kind = "literal";
          text = "  - TYPE: ";
        }
        {
          attr = "relation_type";
          kind = "assign";
          multiplicity = "one";
          option = "type";
          value = {
            kind = "literal";
            text = "File";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          items = [
            {
              kind = "literal";
              text = "    ROLE: ";
            }
            {
              attr = "relation_role";
              kind = "assign";
              multiplicity = "one";
              option = "role";
              value = {
                kind = "pattern";
                pattern = ".+";
              };
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
          ];
          kind = "optional";
        }
      ];
      txType = "common";
    };
    GrammarElementRelationParent = {
      alternatives = [];
      items = [
        {
          kind = "literal";
          text = "  - TYPE: ";
        }
        {
          attr = "relation_type";
          kind = "assign";
          multiplicity = "one";
          option = "type";
          value = {
            kind = "literal";
            text = "Parent";
          };
        }
        {
          kind = "regex";
          pattern = "\\r?\\n";
        }
        {
          items = [
            {
              kind = "literal";
              text = "    ROLE: ";
            }
            {
              attr = "relation_role";
              kind = "assign";
              multiplicity = "one";
              option = "role";
              value = {
                kind = "pattern";
                pattern = ".+";
              };
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
          ];
          kind = "optional";
        }
        {
          items = [
            {
              kind = "literal";
              text = "    REVERSE_ROLE: ";
            }
            {
              attr = "reverse_relation_role";
              kind = "assign";
              multiplicity = "one";
              option = "reverseRole";
              value = {
                kind = "pattern";
                pattern = ".+";
              };
            }
            {
              kind = "regex";
              pattern = "\\r?\\n";
            }
          ];
          kind = "optional";
        }
      ];
      txType = "common";
    };
    RequirementType = {
      alternatives = [];
      items = [
        {
          items = [
            {
              kind = "rule";
              name = "ReservedKeyword";
            }
          ];
          kind = "not";
        }
        {
          kind = "regex";
          pattern = "[A-Z]+(_[A-Z]+)*";
        }
      ];
      txType = "match";
    };
    ReservedKeyword = {
      alternatives = [];
      items = [
        {
          branches = [
            [
              {
                kind = "literal";
                text = "DOCUMENT";
              }
            ]
            [
              {
                kind = "literal";
                text = "GRAMMAR";
              }
            ]
          ];
          kind = "choice";
        }
      ];
      txType = "match";
    };
    SingleLineString = {
      alternatives = [];
      items = [
        {
          kind = "regex";
          pattern = "(?!>>>\r?\n)\\S[^\\r\\n]*";
        }
      ];
      txType = "match";
    };
  };
  types = rec {
    BooleanChoice = patternType {
      deny = [];
      ere = "(True|False)";
      literals = [
        "True"
        "False"
      ];
      rewrites = [
        "ordered-choice-to-alternation"
      ];
      source = "True|False";
    };
    ChoiceOption = patternType {
      deny = [];
      ere = "([\"])[^,]+\"|[^,()\"]+";
      rewrites = [
        "backreference-to-literal"
      ];
      source = "([\"])[^,]+\\1|[^,()\"]+";
    };
    ChoiceOptionXs = ChoiceOption;
    DocumentGrammar = t.submodule {
      options = {
        elements = mkOption {
          default = null;
          description = "`ELEMENTS` of `DocumentGrammar`. Optional; a list. Upstream textx attribute `elements`.";
          type = t.nullOr (t.nonEmptyListOf GrammarElement);
        };
        importFromFile = mkOption {
          default = null;
          description = "`IMPORT_FROM_FILE` of `DocumentGrammar`. Optional; a single value. Upstream textx attribute `import_from_file`.";
          type = t.nullOr (patternType {
            deny = [];
            ere = ".+\$";
            rewrites = [];
            source = ".+\$";
          });
        };
      };
    };
    DocumentGrammarWrapper = t.submodule {
      options = {
        grammar = mkOption {
          description = "an unlabelled production of `DocumentGrammarWrapper`. Mandatory; a single value. Upstream textx attribute `grammar`.";
          type = DocumentGrammar;
        };
      };
    };
    FieldName = patternType {
      deny = [
        "UID"
        "RELATIONS"
      ];
      ere = "[A-Z]+[A-Za-z0-9_-]*";
      rewrites = [
        "bracket-escaped-hyphen"
        "hoist-negative-lookahead"
        "strip-start-anchor"
      ];
      source = "(?!^UID)(?!^RELATIONS)[A-Z]+[A-Za-z0-9_\\-]*";
    };
    GrammarElement = t.submodule {
      options = {
        fields = mkOption {
          description = "`FIELDS` of `GrammarElement`. Mandatory; a list. Upstream textx attribute `fields`.";
          type = t.nonEmptyListOf GrammarElementField;
        };
        isComposite = mkOption {
          default = null;
          description = "`IS_COMPOSITE` of `GrammarElement`. Optional; a single value. Upstream textx attribute `property_is_composite`.";
          type = t.nullOr (patternType {
            deny = [];
            ere = "(True|False)";
            rewrites = [];
            source = "(True|False)";
          });
        };
        prefix = mkOption {
          default = null;
          description = "`PREFIX` of `GrammarElement`. Optional; a single value. Upstream textx attribute `property_prefix`.";
          type = t.nullOr (patternType {
            deny = [];
            ere = ".*";
            rewrites = [];
            source = ".*";
          });
        };
        relations = mkOption {
          default = null;
          description = "`RELATIONS` of `GrammarElement`. Optional; a list. Upstream textx attribute `relations`.";
          type = t.nullOr (t.nonEmptyListOf GrammarElementRelation);
        };
        tag = mkOption {
          description = "`TAG` of `GrammarElement`. Mandatory; a single value. Upstream textx attribute `tag`.";
          type = RequirementType;
        };
        viewStyle = mkOption {
          default = null;
          description = "`VIEW_STYLE` of `GrammarElement`. Optional; a single value. Upstream textx attribute `property_view_style`.";
          type = t.nullOr (patternType {
            deny = [];
            ere = "(Plain|Simple|Inline|Narrative|Table|Zebra)";
            rewrites = [];
            source = "(Plain|Simple|Inline|Narrative|Table|Zebra)";
          });
        };
      };
    };
    GrammarElementField = t.attrTag {
      multipleChoice = mkOption {
        description = "`GrammarElementFieldMultipleChoice` — one alternative of the `GrammarElementField` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
        type = GrammarElementFieldMultipleChoice;
      };
      singleChoice = mkOption {
        description = "`GrammarElementFieldSingleChoice` — one alternative of the `GrammarElementField` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
        type = GrammarElementFieldSingleChoice;
      };
      string = mkOption {
        description = "`GrammarElementFieldString` — one alternative of the `GrammarElementField` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
        type = GrammarElementFieldString;
      };
      tag = mkOption {
        description = "`GrammarElementFieldTag` — one alternative of the `GrammarElementField` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
        type = GrammarElementFieldTag;
      };
    };
    GrammarElementFieldMultipleChoice = t.submodule {
      options = {
        humanTitle = mkOption {
          default = null;
          description = "`HUMAN_TITLE` of `GrammarElementFieldMultipleChoice`. Optional; a single value. Upstream textx attribute `human_title`.";
          type = t.nullOr SingleLineString;
        };
        options = mkOption {
          description = "an unlabelled production of `GrammarElementFieldMultipleChoice`. Mandatory; a list. Upstream textx attribute `options`.";
          type = t.nonEmptyListOf ChoiceOption;
        };
        required = mkOption {
          description = "`REQUIRED` of `GrammarElementFieldMultipleChoice`. Mandatory; a single value. Upstream textx attribute `required`.";
          type = BooleanChoice;
        };
        title = mkOption {
          description = "`TITLE` of `GrammarElementFieldMultipleChoice`. Mandatory; a single value. Upstream textx attribute `title`.";
          type = FieldName;
        };
      };
    };
    GrammarElementFieldSingleChoice = t.submodule {
      options = {
        humanTitle = mkOption {
          default = null;
          description = "`HUMAN_TITLE` of `GrammarElementFieldSingleChoice`. Optional; a single value. Upstream textx attribute `human_title`.";
          type = t.nullOr SingleLineString;
        };
        options = mkOption {
          description = "an unlabelled production of `GrammarElementFieldSingleChoice`. Mandatory; a list. Upstream textx attribute `options`.";
          type = t.nonEmptyListOf ChoiceOption;
        };
        required = mkOption {
          description = "`REQUIRED` of `GrammarElementFieldSingleChoice`. Mandatory; a single value. Upstream textx attribute `required`.";
          type = BooleanChoice;
        };
        title = mkOption {
          description = "`TITLE` of `GrammarElementFieldSingleChoice`. Mandatory; a single value. Upstream textx attribute `title`.";
          type = FieldName;
        };
      };
    };
    GrammarElementFieldString = t.submodule {
      options = {
        humanTitle = mkOption {
          default = null;
          description = "`HUMAN_TITLE` of `GrammarElementFieldString`. Optional; a single value. Upstream textx attribute `human_title`.";
          type = t.nullOr SingleLineString;
        };
        required = mkOption {
          description = "`REQUIRED` of `GrammarElementFieldString`. Mandatory; a single value. Upstream textx attribute `required`.";
          type = BooleanChoice;
        };
        title = mkOption {
          description = "`TITLE` of `GrammarElementFieldString`. Mandatory; a single value. Upstream textx attribute `title`.";
          type = FieldName;
        };
      };
    };
    GrammarElementFieldTag = t.submodule {
      options = {
        humanTitle = mkOption {
          default = null;
          description = "`HUMAN_TITLE` of `GrammarElementFieldTag`. Optional; a single value. Upstream textx attribute `human_title`.";
          type = t.nullOr SingleLineString;
        };
        required = mkOption {
          description = "`REQUIRED` of `GrammarElementFieldTag`. Mandatory; a single value. Upstream textx attribute `required`.";
          type = BooleanChoice;
        };
        title = mkOption {
          description = "`TITLE` of `GrammarElementFieldTag`. Mandatory; a single value. Upstream textx attribute `title`.";
          type = FieldName;
        };
      };
    };
    GrammarElementRelation = t.attrTag {
      child = mkOption {
        description = "`GrammarElementRelationChild` — one alternative of the `GrammarElementRelation` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
        type = GrammarElementRelationChild;
      };
      file = mkOption {
        description = "`GrammarElementRelationFile` — one alternative of the `GrammarElementRelation` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
        type = GrammarElementRelationFile;
      };
      parent = mkOption {
        description = "`GrammarElementRelationParent` — one alternative of the `GrammarElementRelation` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
        type = GrammarElementRelationParent;
      };
    };
    GrammarElementRelationChild = t.submodule {
      options = {
        reverseRole = mkOption {
          default = null;
          description = "`REVERSE_ROLE` of `GrammarElementRelationChild`. Optional; a single value. Upstream textx attribute `reverse_relation_role`.";
          type = t.nullOr (patternType {
            deny = [];
            ere = ".+";
            rewrites = [];
            source = ".+";
          });
        };
        role = mkOption {
          default = null;
          description = "`ROLE` of `GrammarElementRelationChild`. Optional; a single value. Upstream textx attribute `relation_role`.";
          type = t.nullOr (patternType {
            deny = [];
            ere = ".+";
            rewrites = [];
            source = ".+";
          });
        };
        type = mkOption {
          default = "Child";
          description = "`TYPE` of `GrammarElementRelationChild`. Mandatory; a single value. Upstream textx attribute `relation_type`.";
          type = patternType {
            deny = [];
            ere = "Child";
            literals = [
              "Child"
            ];
            rewrites = [
              "literal-to-pattern"
            ];
            source = "Child";
          };
        };
      };
    };
    GrammarElementRelationFile = t.submodule {
      options = {
        role = mkOption {
          default = null;
          description = "`ROLE` of `GrammarElementRelationFile`. Optional; a single value. Upstream textx attribute `relation_role`.";
          type = t.nullOr (patternType {
            deny = [];
            ere = ".+";
            rewrites = [];
            source = ".+";
          });
        };
        type = mkOption {
          default = "File";
          description = "`TYPE` of `GrammarElementRelationFile`. Mandatory; a single value. Upstream textx attribute `relation_type`.";
          type = patternType {
            deny = [];
            ere = "File";
            literals = [
              "File"
            ];
            rewrites = [
              "literal-to-pattern"
            ];
            source = "File";
          };
        };
      };
    };
    GrammarElementRelationParent = t.submodule {
      options = {
        reverseRole = mkOption {
          default = null;
          description = "`REVERSE_ROLE` of `GrammarElementRelationParent`. Optional; a single value. Upstream textx attribute `reverse_relation_role`.";
          type = t.nullOr (patternType {
            deny = [];
            ere = ".+";
            rewrites = [];
            source = ".+";
          });
        };
        role = mkOption {
          default = null;
          description = "`ROLE` of `GrammarElementRelationParent`. Optional; a single value. Upstream textx attribute `relation_role`.";
          type = t.nullOr (patternType {
            deny = [];
            ere = ".+";
            rewrites = [];
            source = ".+";
          });
        };
        type = mkOption {
          default = "Parent";
          description = "`TYPE` of `GrammarElementRelationParent`. Mandatory; a single value. Upstream textx attribute `relation_type`.";
          type = patternType {
            deny = [];
            ere = "Parent";
            literals = [
              "Parent"
            ];
            rewrites = [
              "literal-to-pattern"
            ];
            source = "Parent";
          };
        };
      };
    };
    RequirementType = patternType {
      deny = [
        "DOCUMENT"
        "GRAMMAR"
      ];
      denyRule = "ReservedKeyword";
      ere = "[A-Z]+(_[A-Z]+)*";
      rewrites = [
        "negative-lookahead-rule"
      ];
      source = "[A-Z]+(_[A-Z]+)*";
    };
    ReservedKeyword = patternType {
      deny = [];
      ere = "(DOCUMENT|GRAMMAR)";
      literals = [
        "DOCUMENT"
        "GRAMMAR"
      ];
      rewrites = [
        "ordered-choice-to-alternation"
      ];
      source = "DOCUMENT|GRAMMAR";
    };
    SingleLineString = patternType {
      deny = [
        ">>>\r?\n"
      ];
      ere = "[^[:space:]][^\r\n]*";
      rewrites = [
        "control-escape-to-literal"
        "hoist-negative-lookahead"
        "shorthand-class-to-posix"
      ];
      source = "(?!>>>\r?\n)\\S[^\\r\\n]*";
    };
  };
}
