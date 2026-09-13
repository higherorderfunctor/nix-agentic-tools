# DESIGN PSEUDOCODE IN NIX SYNTAX: proposed p.* interfaces, not installed APIs.
# dsl.* grammar constructors use only the documented public constructor shape.
# Programs/backend are caller-supplied design artifacts, not implemented files.
# Parsing this function proves syntax only. Calling it requires future libraries.
{
  communityBackend,
  consumerPrograms,
  dsl,
  p,
}: let
  model = "example:model";
  grammarId = "example:grammar";
  policyId = "example:neutral";

  # Grammar and semantic attachment remain distinct inspectable artifacts.
  uid = dsl.field.required (dsl.field.str "UID");
  grammar = {
    id = grammarId;
    elements = [
      (dsl.el "BAR" {} {
        fields = [uid];
        relations = [
          (dsl.rel.child "Q" "Q_back")
          (dsl.rel.parent "P" "P_back")
        ];
      })
      (dsl.el "BAZ" {} {
        fields = [uid];
        relations = [
          (dsl.rel.child "Q" "Q_back")
          (dsl.rel.parent "R" "R_back")
        ];
      })
      (dsl.el "FOO" {} {
        fields = [
          (dsl.field.required (dsl.field.one "FLAG" ["false" "true"]))
          uid
        ];
        relations = [
          (dsl.rel.parent "H" "H_back")
          (dsl.rel.parent "R" "R_back")
        ];
      })
    ];
  };
  foo = p.elementRef grammarId "FOO";
  bar = p.elementRef grammarId "BAR";
  h = p.relationRef foo {
    nativeType = "Parent";
    role = "H";
  };
  r = p.relationRef foo {
    nativeType = "Parent";
    role = "R";
  };
  upper = p.relationRef bar {
    nativeType = "Parent";
    role = "P";
  };
  lower = p.relationRef bar {
    nativeType = "Child";
    role = "Q";
  };

  hierarchy = p.forest {
    id = "${policyId}/hierarchy";
    nodes = foo;
    parentDeclarations = [h];
    # Exports a view plus rule `${id}/forest`; zero parents is allowed.
  };
  closed = p.enumPredicate {
    field = p.fieldRef foo "FLAG";
    falseValues = ["false"];
    invalidValues = "input-error";
    trueValues = ["true"];
  };

  targetRule = p.targets {
    id = "${policyId}/reference-target";
    relation = r;
    types = [foo];
  };
  neutral = p.bundle {
    id = policyId;
    grammars = [grammarId];
    inputs = {
      protectedBaseline = p.input {
        schema = "example:modeled-record-baseline/v1";
        completeness = "required";
      };
    };
    requiresModelCapabilities = [
      "authored-parent-child-with-provenance/v1"
      "complete-native-dag-validation/v1"
    ];
    rules = [
      (p.targets {
        id = "${policyId}/hierarchy-target";
        relation = h;
        types = [foo];
      })
      (p.targets {
        id = "${policyId}/lower-target";
        relation = lower;
        types = [foo];
      })
      targetRule
      (p.targets {
        id = "${policyId}/upper-target";
        relation = upper;
        types = [foo];
      })
      (p.visible {
        id = "${policyId}/reference-visibility";
        inherit closed hierarchy;
        references = r;
        traversal = "same-tree-undirected";
        boundaries = "visit-closed-expand-only-from-inside";
      })
      (p.adaptation {
        id = "${policyId}/adaptation";
        inherit closed hierarchy lower upper;
        statements = bar;
        endpointCounts = {
          lower = 1;
          upper = 1;
        };
        traversal = "downward";
        boundaries = "visit-closed-expand-only-from-inside";
        # Exported child rule IDs: /lower-count, /upper-count, /path.
        # Parent/Child ownership is retained; this does not flatten BAR.
      })
      (p.preserveListed {
        id = "${policyId}/preserve-listed";
        baseline = p.inputRef "protectedBaseline";
        candidate = p.snapshotRef "candidate";
        identity = {
          modelNamespace = model;
          key = "UID";
        };
        projection = {
          existence = true;
          fieldsWhenPresent = ["FLAG"];
          nativeElementType = true;
          ownedRelations = {
            equality = "set";
            include = ["grammar" "model" "nativeType" "owner" "role" "target"];
          };
          # This explicit whitelist excludes incoming links/location/bookkeeping.
        };
        exceptions = [];
      })
    ];
    views = [hierarchy];
  };

  # Direct descriptor equivalent to targetRule. A library conformance test must
  # compare normalization, decisions and structured witnesses, not just labels.
  directTargetRule = {
    id = "${policyId}/reference-target";
    contract = {
      kind = "policy:relation-target-types/v1";
      arguments = {
        relation = {
          grammar = grammarId;
          nativeType = "Parent";
          ownerElement = "FOO";
          role = "R";
        };
        types = [
          {
            grammar = grammarId;
            element = "FOO";
          }
        ];
      };
    };
    requires = {candidate = {schema = "policy:model-snapshot/v1";};};
    # Logical ID is stable; compiler computes artifact digest and provenance.
  };

  # Consumer-owned native tailoring example: familiar vocabulary, same helper.
  tailoringGrammarId = "consumer:tailoring-grammar";
  requirement = p.elementRef tailoringGrammarId "REQUIREMENT";
  adaptation = p.elementRef tailoringGrammarId "ADAPTATION";
  tailoringHierarchy = p.forest {
    id = "consumer:tailoring/hierarchy";
    nodes = requirement;
    parentDeclarations = [
      (p.relationRef requirement {
        nativeType = "Parent";
        role = "hierarchy";
      })
    ];
  };
  source = p.relationRef adaptation {
    nativeType = "Parent";
    role = "source";
  };
  implementation = p.relationRef adaptation {
    nativeType = "Child";
    role = "implementation";
  };

  # A separately supplied adapter uses public registration, not core dispatch.
  runtime = p.runtime {
    backends = [
      (p.registerBackend {
        id = "community:policy-programs/v1";
        inherit (communityBackend) evaluate manifest plan;
        # Manifest declares versioned kinds/schemas/capabilities and diagnostics.
      })
    ];
    assignments = {
      "consumer:program/v1" = "community:policy-programs/v1";
      # Remaining effective kinds must be assigned by the chosen adapters.
      # This fragment alone intentionally is not a runnable full runtime.
    };
    providers = {
      main = p.executableProvider {
        argv = [consumerPrograms.gitBaseline "--ref" "refs/heads/main"];
        requestSchema = "policy:acquire-request/v1";
        responseSchema = "consumer:git-record-baseline/v1";
        limits = {
          maxOutputBytes = 16777216;
          timeoutSeconds = 20;
        };
      };
      actor = p.contextProvider {
        authority = "consumer:authenticated-transport";
        schema = "consumer:attested-principal/v1";
      };
      approvals = p.executableProvider {
        argv = [consumerPrograms.approvals];
        requestSchema = "policy:acquire-request/v1";
        responseSchema = "consumer:verified-approvals/v1";
        limits = {
          maxOutputBytes = 1048576;
          timeoutSeconds = 20;
        };
      };
    };
  };
in {
  grammarAdjacent = p.attach {
    inherit grammar;
    bundles = [neutral];
  };

  # Same grammar, rule, and scope can be assembled without grammar attachment.
  separate = {
    grammars = [grammar];
    bundles = [neutral];
  };
  direct = {
    rule = directTargetRule;
    equivalentHelperRule = targetRule;
  };

  tailoring = {
    grammar = {
      id = tailoringGrammarId;
      elements = [
        (dsl.el "ADAPTATION" {} {
          fields = [uid];
          relations = [
            (dsl.rel.child "implementation" "implemented_by")
            (dsl.rel.parent "source" "adapted_by")
          ];
        })
        (dsl.el "REQUIREMENT" {} {
          fields = [
            (dsl.field.required (dsl.field.one "CLOSED" ["false" "true"]))
            uid
          ];
          relations = [(dsl.rel.parent "hierarchy" "contains")];
        })
      ];
    };
    bundle = p.bundle {
      id = "consumer:tailoring";
      grammars = [tailoringGrammarId];
      views = [tailoringHierarchy];
      rules = [
        (p.targets {
          id = "consumer:tailoring/source-target";
          relation = source;
          types = [requirement];
        })
        (p.targets {
          id = "consumer:tailoring/implementation-target";
          relation = implementation;
          types = [requirement];
        })
        (p.adaptation {
          id = "consumer:tailoring/endpoints";
          closed = p.enumPredicate {
            field = p.fieldRef requirement "CLOSED";
            falseValues = ["false"];
            invalidValues = "input-error";
            trueValues = ["true"];
          };
          hierarchy = tailoringHierarchy;
          lower = implementation;
          upper = source;
          statements = adaptation;
          endpointCounts = {
            lower = 1;
            upper = 1;
          };
          traversal = "downward";
          boundaries = "visit-closed-expand-only-from-inside";
        })
      ];
    };
    # Descriptive authored facts, not an SDoc serialization API.
    authoredExample = [
      {
        uid = "STD-1";
        element = "REQUIREMENT";
        fields.CLOSED = "false";
        relations = [];
      }
      {
        uid = "OTS-9";
        element = "REQUIREMENT";
        fields.CLOSED = "false";
        relations = [
          {
            nativeType = "Parent";
            role = "hierarchy";
            target = "STD-1";
          }
        ];
      }
      {
        uid = "A42";
        element = "ADAPTATION";
        statement = "Use the immutable OTS behavior to satisfy this standard requirement.";
        relations = [
          {
            nativeType = "Parent";
            role = "source";
            target = "STD-1";
          }
          {
            nativeType = "Child";
            role = "implementation";
            target = "OTS-9";
          }
        ];
      }
    ];
  };

  fieldAlternative = {
    grammarElement = dsl.el "ADAPTATION_FIELDS" {} {
      fields = [
        (dsl.field.required (dsl.field.str "IMPLEMENTATION_UID"))
        (dsl.field.required (dsl.field.str "SOURCE_UID"))
        uid
      ];
      relations = [];
    };
    rule = {
      id = "consumer:field-adaptation/path";
      contract = {
        kind = "consumer:program/v1";
        arguments = {
          argv = [consumerPrograms.fieldAdaptation];
          sourceField = "SOURCE_UID";
          targetField = "IMPLEMENTATION_UID";
          # Program contract: resolve typed identities, diagnose missing/invalid
          # endpoints, evaluate downward hierarchy and origin-sensitive closure.
        };
      };
      requires = {
        candidate = p.snapshotRef "candidate";
        hierarchy = p.viewRef tailoringHierarchy;
      };
      # Endpoint/path equivalence only: fields do not add native graph edges.
    };
  };

  repositoryPolicy = p.bundle {
    id = "consumer:repository-lifecycle";
    rules = [
      (p.programRule {
        id = "consumer:repository-lifecycle/edit-authority";
        exports = [
          "consumer:repository-lifecycle/approval"
          "consumer:repository-lifecycle/main-protection"
        ];
        kind = "consumer:program/v1";
        argv = [consumerPrograms.editAuthority];
        scope = "whole-change-and-documents";
        requires = {
          actor = p.inputRef "actor";
          approvals = p.inputRef "approvals";
          before = p.snapshotRef "before";
          candidate = p.snapshotRef "candidate";
          main = p.inputRef "main";
        };
        # Consumer program: LLM cannot revise main-listed projections;
        # protected document revisions need verified candidate-bound approval.
        # Programs choose document classification, projection and exceptions.
      })
    ];
  };

  override = p.compose {
    bundles = [neutral];
    edits = [
      (p.replace {
        target = "${policyId}/reference-visibility";
        expectedArtifact = "sha256:<digest-from-effective-manifest>";
        replacement = consumerPrograms.replacementVisibilityDescriptor;
      })
      # p.disable has the same explicit target/expectedArtifact guard.
    ];
  };

  # A backend-native module is a direct public escape hatch, not a universal DSL.
  backendNative = {
    id = "consumer:special-analysis/rule";
    contract = {
      kind = "community:native-module/v1";
      arguments.module = consumerPrograms.nativeModule;
    };
    requires = {candidate = p.snapshotRef "candidate";};
    # Requires explicit registration/assignment for this kind; otherwise error.
  };

  optionSketch.ai.strictdoc.policy = {
    bundles = [neutral];
    inherit runtime;
    boundaries = {
      daemon = {
        kind = "private-transaction";
        admission = "complete-validity";
        groupSealing = "explicit";
        publishPrecondition = "before-revision-matches";
        # Requires a qualified publication adapter; unsupported is an error.
      };
      gitCommit = {
        kind = "git-hook";
        before = "parent-commit";
        candidate = "staged-tree";
        admission = "complete-validity";
        # Refusal prevents this commit; earlier user edits remain inspectable.
      };
    };
  };
}
