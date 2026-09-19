# GENERATED FILE — DO NOT EDIT BY HAND.
#
# Written by packages/strictdoc-grammar/extract/extract.py from strictdoc's own
# grammar definition (`SDocGrammarBuilder.create_grammar_grammar()`), reached
# through both the textx metamodel and the arpeggio parser tree. A drift check
# regenerates and diffs, so a stale surface is a red check.
#
# FAITHFUL means: the grammar's own production tree, rule by rule, with no
# opinion of ours in it. There are no types here and no `lib` to build them
# with — a value constrained by a regex is that regex, spelled the way upstream
# spells it, lookahead groups and Python-only escapes and all.
#
# THE ABSENCE OF A `types` BLOCK IS THE POINT. Deciding what a pattern MEANS —
# rewriting it into the POSIX dialect `builtins.match` speaks, lifting a
# lookahead out of it, reading an alternation as a vocabulary — is a
# transformation, and a layer that promises nothing was transformed cannot
# carry a record of transformations. ./normalized.nix computes the types from
# the records below, and names every rewrite it performs.
#
# Two things to know before reading:
#
# * `productions.<Rule>` is one entry per grammar rule reachable from the root
#   rule, as an ordered item tree: literals, patterns, references to other
#   rules, and the assignments that name a rule's attributes. Order is the
#   grammar's and is enforced by it.
# * An assignment carries BOTH spellings of its name — `attr` is upstream's
#   textx attribute, `option` is the key a `.sgra` file actually writes, read
#   off the literal immediately in front of it.
{
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
          option = "choices";
          value = {
            kind = "rule";
            name = "ChoiceOption";
          };
        }
        {
          attr = "options";
          kind = "assign";
          multiplicity = "zeroOrMore";
          option = "choices";
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
          option = "choices";
          value = {
            kind = "rule";
            name = "ChoiceOption";
          };
        }
        {
          attr = "options";
          kind = "assign";
          multiplicity = "zeroOrMore";
          option = "choices";
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
}
