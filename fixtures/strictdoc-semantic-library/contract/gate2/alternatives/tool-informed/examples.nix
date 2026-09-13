# PROPOSED Gate 2 interface. This is a design artifact, not installed code.
# Only `grammar.dsl` constructors shown here exist today. `contracts`, `adapters`,
# all new options, artifacts, and executables require later implementation.
# Parse with nix-instantiate --parse; do not supply stubs to claim evaluation.
{
  grammar,
  contracts,
  adapters,
  artifacts,
  executables,
}: let
  g = grammar.dsl;
  c = contracts;
  uid = g.field.required (g.field.str "UID");
  foo = {
    grammar = "fixture";
    element = "FOO";
  };
  relation = ownerElement: nativeType: role: {
    grammar = "fixture";
    inherit ownerElement nativeType role;
  };
  h = relation "FOO" "Parent" "H";
  r = relation "FOO" "Parent" "R";
  p = relation "BAR" "Parent" "P";
  q = relation "BAR" "Child" "Q";

  # N1: grammar-adjacent helpers; emit unchanged native grammar plus a bundle.
  # `self` captures grammar and owner element, never a globally named role.
  model = c.grammar {
    id = "fixture";
    elements = [
      (c.element {
        native = g.el "FOO" {} {
          fields = [uid (g.field.required (g.field.one "FLAG" ["false" "true"]))];
          relations = [(g.rel.parent "H" "H_back") (g.rel.parent "R" "R_back")];
        };
        policies = self: [
          (c.targets {
            id = "fixture/H-target";
            select = self.parent "H";
            allowed = [foo];
          })
          (c.targets {
            id = "fixture/R-target";
            select = self.parent "R";
            allowed = [foo];
          })
        ];
      })
      (c.element {
        native = g.el "BAR" {} {
          fields = [uid];
          relations = [(g.rel.parent "P" "P_back") (g.rel.child "Q" "Q_back")];
        };
        policies = self: [
          (c.targets {
            id = "fixture/P-target";
            select = self.parent "P";
            allowed = [foo];
          })
          (c.targets {
            id = "fixture/Q-target";
            select = self.child "Q";
            allowed = [foo];
          })
        ];
      })
      (c.element {
        native = g.el "BAZ" {} {
          fields = [uid];
          relations = [(g.rel.parent "R" "R_back") (g.rel.child "Q" "Q_back")];
        };
        policies = _: [];
      })
    ];
  };
  forest = c.forest {
    id = "fixture/H";
    nodes = foo;
    parents = h;
    maximumParents = 1;
    roots = "multiple";
  };
  boundary = {
    field = {
      inherit (foo) grammar element;
      name = "FLAG";
    };
    values = {
      "false" = "open";
      "true" = "closed";
    };
    invalidValue = "input-error";
    closedEndpoint = "visitable";
    closedExpansion = "origin-in-subtree-including-self";
  };
  graphBundle = c.bundle {
    id = "fixture/graph";
    includes = [model.bundle forest.bundle];
    rules = [
      (c.nativeDAG {
        id = "fixture/native-DAG";
        roles = "all";
        directions = ["Parent" "Child"];
      })
      (c.visible {
        id = "fixture/R-visible";
        select = r;
        hierarchy = forest.view;
        inherit boundary;
        path = "same-tree-up-then-down";
      })
      (c.bridge {
        id = "fixture/bridge";
        records = {
          grammar = "fixture";
          element = "BAR";
        };
        upper = {
          select = p;
          count = {
            min = 1;
            max = 1;
          };
        };
        lower = {
          select = q;
          count = {
            min = 1;
            max = 1;
          };
        };
        hierarchy = forest.view;
        inherit boundary;
        path = "downward";
        connectivity = "retain-native-record";
      })
    ];
  };

  # N2: exact lower-layer counterpart of c.targets for R. Use as an alternative,
  # not an additional definition with the same rule ID.
  rawTarget = {
    id = "fixture/R-target";
    origin = {
      package = "consumer-fixture";
      label = "R target policy";
    };
    scope = {
      kind = "model";
      grammar = "fixture";
    };
    requires = ["model.authored-relations/v1" "model.resolved-endpoints/v1"];
    reads = ["candidate.nodes" "candidate.authoredRelations"];
    implementation = {
      backend = "graph-library";
      entry = "targets/v1";
      config = {
        select = r;
        allowed = [foo];
      };
    };
    diagnostic = "target-type/v1";
  };

  # N3: projection and state/change policies are independently composable.
  authoredProjection = {
    id = "fixture/authored-record/v1";
    key = ["grammar" "uid"];
    include = ["element" "fields.FLAG-if-present" "ownedNativeRelations"];
    relationKey = ["grammar" "ownerElement" "nativeType" "role" "target"];
    relationOrder = "set";
    exclude = ["incomingRelations" "documentPath" "reverseRole" "runtimeBookkeeping"];
  };
  preservation = c.preserve {
    id = "fixture/preservation";
    baseline = "protected-records";
    projection = authoredProjection;
    requireExistence = true;
    exceptions = [];
  };
  referencePolicy = c.bundle {
    id = "fixture/reference";
    includes = [graphBundle];
    rules = [preservation];
  };
  lifecyclePolicy = c.bundle {
    id = "consumer/lifecycle";
    rules = [
      {
        id = "consumer/main-llm";
        scope = {kind = "change";};
        requires = ["facts.main-model/v1" "facts.verified-principal/v1" "change.before/v1"];
        reads = ["before" "candidate" "facts.main" "facts.principal"];
        implementation = {
          backend = "consumer-python";
          entry = "main_policy:check";
          config = {
            principal = "principal";
            main = "main";
            projection = authoredProjection;
            llmChangeToMainRecord = "deny";
            supersession = "no-implicit-exception";
          };
        };
        diagnostic = "authored-change/v1";
      }
      {
        id = "consumer/human-review";
        scope = {
          kind = "document";
          select = {root = "consumer-documents";};
        };
        requires = ["change.before/v1" "facts.document-classification/v1" "facts.approval/v1" "facts.main-model/v1" "facts.verified-principal/v1"];
        reads = ["before" "candidate" "facts.classification" "facts.approval" "facts.main" "facts.principal" "policy"];
        implementation = {
          backend = "consumer-python";
          entry = "review_policy:check";
          config = {
            classification = "classification";
            protectedClasses = ["human-authored" "protected"];
            approvals = "approval";
            bindApprovalTo = ["before" "candidate" "policy" "main" "principal"];
            missingApproval = "needs-review";
          };
        };
        diagnostic = "approval-required/v1";
      }
    ];
  };

  # N4: all registrations have the same public descriptor contract.
  # Raw process runtime supplied independently; runner speaks the proposed ABI.
  consumerRuntime = {
    kind = "runtime";
    id = "consumer-process";
    protocol = "policy-runtime/v1";
    transport = {
      kind = "stdio";
      argv = [executables.consumerRunner];
    };
    artifact = artifacts.consumerRunnerIdentity;
    provides = ["runtime.execute/v1" "runtime.cancel-process/v1"];
    limits = {
      timeoutMs = 5000;
      outputBytes = 1048576;
    };
  };
  consumerBackend = {
    kind = "backend";
    id = "consumer-python";
    runtime = "consumer-process";
    artifact = artifacts.consumerPython;
    format = "python-callable/v1";
    entries = {
      "main_policy:check" = "rule-result/v1";
      "review_policy:check" = "rule-result/v1";
      "field_bridge:check" = "rule-result/v1";
      "budget:check" = "rule-result/v1";
    };
    provides = ["rules.evaluate-full/v1"];
    inputs = "evaluation/v1";
    invalidation = "whole-evaluation";
  };
  packagedGraphBackend = adapters.graphLibrary {
    id = "graph-library";
    runtime = "consumer-process";
    artifact = artifacts.graphLibrary;
    # Descriptor factory: no privileged registration path or implicit enablement.
    nativeValidator = "strictdoc-all-roles";
  };
  nativeValidator = adapters.strictdoc {
    id = "strictdoc-all-roles";
    runtime = "consumer-process";
    artifact = artifacts.strictdocAdapter;
    requiredCapabilities = ["native.complete-candidate/v1" "native.all-role-DAG/v1"];
  };
  fact = id: executable: schema: requires: {
    kind = "facts";
    inherit id schema requires;
    provides = ["facts.${schema}"];
    authority = {
      policyArtifact = artifacts.captureTrust;
      requestLabels = "untrusted";
    };
    runtime = "consumer-process";
    acquire = {
      argv = [executable];
      stdin = "capture-request/v1";
    };
    capture = "once-per-evaluation";
    result = "snapshot-result/v1";
    limits = {
      timeoutMs = 3000;
      outputBytes = 16777216;
    };
  };
  factRegistrations = [
    (fact "protected-records" executables.baseline "protected-records/v1" [])
    (fact "main" executables.mainSnapshot "main-model/v1" [])
    (fact "principal" executables.verifiedPrincipal "verified-principal/v1" [])
    (fact "classification" executables.classification "document-classification/v1" ["main"])
    (fact "approval" executables.approvals "approval/v1" ["main" "principal"])
  ];

  # N5: direct tool-native alternative to R visibility; same input binding and
  # witness obligations, but no promise to compile arbitrary Rego from helpers.
  directRego = {
    id = "fixture/R-visible";
    scope = {
      kind = "model";
      grammar = "fixture";
    };
    requires = ["view.forest/v1" "opa.graph-reachable/v1" "diagnostic.boundary-path/v1"];
    reads = ["candidate" "views.fixture/H" "policy"];
    implementation = {
      backend = "consumer-opa";
      entry = "data.consumer.visibility.result";
      config = {
        select = r;
        hierarchy = forest.view;
        inherit boundary;
      };
    };
    diagnostic = "boundary-path/v1";
  };
  opaRegistration = adapters.opa {
    id = "consumer-opa";
    runtime = "consumer-process";
    artifact = artifacts.consumerRego;
    mode = "cli";
    executable = executables.opa;
    strictBuiltinErrors = true;
    undefinedResult = "execution-error";
    requiredResult = "rule-result/v1";
    # A Bun/Wasm registration is an alternative requiring its own capabilities.
  };

  # N6: familiar native tailoring and a separate, explicitly different model.
  nativeTailoring = g.el "ADAPTATION" {} {
    fields = [uid (g.field.str "STATEMENT")];
    relations = [(g.rel.parent "Adapts" "AdaptedBy") (g.rel.child "AppliesTo" "AppliedBy")];
  };
  fieldTailoring = g.el "ADAPTATION_FIELDS" {} {
    fields = [
      uid
      (g.field.str "STATEMENT")
      (g.field.required (g.field.str "UPPER_UID"))
      (g.field.required (g.field.str "LOWER_UID"))
    ];
    relations = [];
  };
  fieldBridgeRule = {
    id = "consumer/field-tailoring";
    scope = {
      kind = "model";
      grammar = "field-tailoring";
    };
    requires = ["model.fields/v1" "view.forest/v1"];
    reads = ["candidate" "views.fixture/H"];
    implementation = {
      backend = "consumer-python";
      entry = "field_bridge:check";
      config = {
        element = "ADAPTATION_FIELDS";
        upperField = "UPPER_UID";
        lowerField = "LOWER_UID";
        endpointGrammar = "fixture";
        endpointElement = "FOO";
        hierarchy = forest.view;
        inherit boundary;
        path = "downward";
        virtualConnectivity = "check-union-DAG-without-authoring-links";
      };
    };
    diagnostic = "field-endpoint-path/v1";
  };

  # N7: composition actions are checked against the original effective bundle.
  regoVariant = c.compose {
    bundles = [referencePolicy];
    edits = [
      {
        action = "replace";
        id = "fixture/R-visible";
        expect = artifacts.originalVisibilityRuleIdentity;
        rule = directRego;
        reason = "Consumer chooses Rego";
      }
    ];
  };
  disableExample = {
    action = "disable";
    id = "consumer/human-review";
    expect = artifacts.originalReviewRuleIdentity;
    reason = "Different consumer review workflow";
  };
  duplicateConflict = [
    rawTarget
    (rawTarget
      // {
        implementation =
          rawTarget.implementation
          // {
            config = {
              select = r;
              allowed = [
                {
                  grammar = "fixture";
                  element = "BAZ";
                }
              ];
            };
          };
      })
  ]; # MUST be a composition error, regardless of list order.

  # N8: scheduling and publication live outside rule bundles.
  daemonBoundary = {
    kind = "daemon-transaction";
    staging = "private-candidate";
    membership = "explicit-participants";
    finalize = "coordinator-after-all-ready";
    concurrentBaseChange = "stale-candidate";
    repair = "complete-valid-result";
    publisher = "consumer-scribe-publisher";
    requiredCapabilities = ["publication.refusal-unchanged/v1" "publication.restore-or-block/v1" "runtime.checks-no-publication-writes/v1"];
  };
  gitBoundary = {
    kind = "git-commit";
    candidate = "captured-index-tree";
    before = "captured-HEAD-tree";
    mergeBefore = "consumer-must-select";
    requireUnchangedIndexBeforeCommit = true;
    repair = "complete-valid-result";
    onRefusal = "block-commit-retain-index-and-worktree";
  };
  daemonThenCommit = {
    transaction = daemonBoundary;
    commit = gitBoundary;
    receiptReuse = "identical-input-identities-only";
  };
in {
  status = "PROPOSED: parse-only design artifact; no backend selected or installed";
  inherit model graphBundle referencePolicy lifecyclePolicy rawTarget authoredProjection;
  inherit consumerRuntime consumerBackend packagedGraphBackend nativeValidator factRegistrations;
  inherit directRego opaRegistration regoVariant disableExample duplicateConflict;
  inherit nativeTailoring fieldTailoring fieldBridgeRule;
  boundaries = {
    daemon = daemonBoundary;
    git = gitBoundary;
    both = daemonThenCommit;
  };

  # N9: proposed devenv integration. Current ai.strictdoc grammar options remain.
  # All values below are proposals; this attrset is not applied by this artifact.
  proposedModule = {
    ai = {
      strictdoc = {
        enable = true;
        scribeSource = "installed";
        grammars.fixture = {
          target = "requirements/fixture.sgra";
          inherit (model) elements;
        };
        contracts = referencePolicy;
      };
      policyRuntime = {
        registrations =
          [consumerRuntime consumerBackend packagedGraphBackend nativeValidator]
          ++ factRegistrations
          ++ [
            (adapters.scribePublisher {
              id = "consumer-scribe-publisher";
              artifact = artifacts.publisher;
            })
          ];
        unsupported = "configuration-error";
        evaluation = "full";
      };
      validation.boundaries = {
        review = daemonBoundary;
        commit = gitBoundary;
      };
    };
  };

  # N10: frozen facts and group messages, illustrative data rather than API calls.
  evaluation = {
    schema = "evaluation/v1";
    id = "eval-17";
    before = {
      id = "model-before-42";
      bytes = "retained-by-host";
    };
    candidate = {
      id = "model-candidate-43";
      bytes = "retained-by-host";
    };
    policy = {
      id = "effective-policy-9";
      registrations = "registrations-3";
    };
    facts = {
      "protected-records" = {
        id = "S1";
        complete = true;
        schema = "protected-records/v1";
        data = [
          {
            grammar = "fixture";
            uid = "I0";
            element = "FOO";
            fields = {FLAG = "false";};
            ownedNativeRelations = [];
          }
        ];
      };
    };
  };
  groupMessages = [
    {
      op = "begin";
      group = "adapt-17";
      base = "model-before-42";
      participants = ["agent-A" "agent-B"];
    }
    {
      op = "stage";
      group = "adapt-17";
      participant = "agent-A";
      expectedRevision = 0;
      patch = "create M and Parent P to F0";
    }
    {
      op = "stage";
      group = "adapt-17";
      participant = "agent-B";
      expectedRevision = 1;
      patch = "add M-owned Child Q to F2";
    }
    {
      op = "ready";
      group = "adapt-17";
      participant = "agent-A";
      revision = 2;
    }
    {
      op = "ready";
      group = "adapt-17";
      participant = "agent-B";
      revision = 2;
    }
    {
      op = "finalize";
      group = "adapt-17";
      expectedRevision = 2;
    }
  ];

  # N11: separate opt-in extension challenge. It adds no fields to model above.
  aggregateChallenge = {
    status = "Requires separate approval of X07 and its numeric model";
    rule = {
      id = "consumer/descendant-budget";
      scope = {
        kind = "model";
        grammar = "numeric-challenge";
      };
      requires = ["view.forest/v1" "facts.limit/v1"];
      reads = ["candidate" "views.numeric/H" "facts.limit"];
      implementation = {
        backend = "consumer-python";
        entry = "budget:check";
        config = {
          field = "COST";
          hierarchy = "numeric/H";
          limit = "limit";
          includeSelf = false;
        };
      };
      diagnostic = "aggregate-contributors/v1";
    };
  };
}
