# PROPOSED signatures and options. Design data only; no fake implementations.
# Only grammar.dsl constructors exist in the supplied current public toolchain.
# All arguments below represent future libraries/artifacts provided by a caller.
# nix-instantiate --parse proves syntax, not evaluation or Scribe behavior.
{
  grammar,
  policy,
  shipped,
  consumerTrustRegistration,
  artifacts,
  executables,
}: let
  g = grammar.dsl;
  p = policy;
  modelId = "reference-model";
  grammarId = "reference";
  foo = {
    grammar = grammarId;
    element = "FOO";
  };
  bar = {
    grammar = grammarId;
    element = "BAR";
  };
  relation = ownerElement: nativeType: role: {
    grammar = grammarId;
    inherit ownerElement nativeType role;
  };
  h = relation "FOO" "Parent" "H";
  r = relation "FOO" "Parent" "R";
  upper = relation "BAR" "Parent" "P";
  lower = relation "BAR" "Child" "Q";
  uid = g.field.required (g.field.str "UID");
  candidate = {
    from = "candidate";
    schema = "sdoc-policy.model/v1";
  };
  before = {
    from = "before";
    schema = "sdoc-policy.model/v1";
  };
  factInput = id: schema: {
    from = "fact:${id}";
    inherit schema;
  };

  # N1: wrappers retain native grammar shape; helpers yield public descriptors.
  model = p.grammar {
    id = grammarId;
    elements = [
      (p.element {
        native = g.el "FOO" {} {
          fields = [uid (g.field.required (g.field.one "FLAG" ["false" "true"]))];
          relations = [(g.rel.parent "H" "H_back") (g.rel.parent "R" "R_back")];
        };
        policies = self: [
          (p.targets {
            id = "reference/H-target";
            select = self.parent "H";
            allowed = [foo];
          })
          (p.targets {
            id = "reference/R-target";
            select = self.parent "R";
            allowed = [foo];
          })
        ];
      })
      (p.element {
        native = g.el "BAR" {} {
          fields = [uid];
          relations = [(g.rel.parent "P" "P_back") (g.rel.child "Q" "Q_back")];
        };
        policies = self: [
          (p.targets {
            id = "reference/P-target";
            select = self.parent "P";
            allowed = [foo];
          })
          (p.targets {
            id = "reference/Q-target";
            select = self.child "Q";
            allowed = [foo];
          })
        ];
      })
      (g.el "BAZ" {} {
        fields = [uid];
        relations = [(g.rel.parent "R" "R_back") (g.rel.child "Q" "Q_back")];
      })
    ];
  };
  forest = p.forest {
    id = "reference/H";
    nodes = foo;
    select = [h];
  };
  hierarchy = {
    from = "view:${forest.view.id}";
    schema = forest.view.schema;
  };
  boundary = {
    field = {
      grammar = grammarId;
      element = "FOO";
      name = "FLAG";
    };
    open = ["false"];
    closed = ["true"];
  };
  nativeRule = {
    id = "reference/native-dag";
    scope = "model";
    contract = "sdoc-policy.native-dag/v1";
    config = {};
    inputs = {inherit candidate;};
    needs = ["model.resolved-parent-child/v1" "native.all-role-dag/v1"];
  };
  bridge = p.bridge {
    id = "reference/bridge";
    records = bar;
    inherit upper lower boundary;
    hierarchy = forest.view;
  };
  projection = {
    id = "reference/authored-record/v1";
    fieldsWhenPresent = [boundary.field];
    elementType = true;
    ownedRelations = "set";
  };
  reference = p.bundle {
    id = "reference/policy";
    includes = [model.bundle forest.bundle bridge];
    rules = [
      nativeRule
      (p.visible {
        id = "reference/R-visible";
        select = r;
        hierarchy = forest.view;
        inherit boundary;
      })
      (p.preserve {
        id = "reference/preserve";
        baseline = "protected";
        inherit projection;
      })
    ];
  };
  effective = p.compose {
    bundles = [reference];
    edits = [];
  };

  # N2: exact proposed p.targets lowering, alternative to the same helper ID.
  # Do not include both variants as different definitions. No backend is embedded.
  directTarget = {
    id = "reference/R-target";
    scope = "model";
    contract = "sdoc-policy.targets/v1";
    config = {
      select = r;
      allowed = [foo];
    };
    inputs = {inherit candidate;};
    needs = ["model.resolved-endpoints/v1"];
  };
  directForest = {
    id = "reference/H";
    contract = "sdoc-policy.forest-view/v1";
    config = {
      nodes = foo;
      select = [h];
    };
    inputs = {inherit candidate;};
    needs = ["model.resolved-parent-child/v1"];
    after = ["reference/H/valid"];
    schema = "sdoc-policy.forest/v1";
  }; # Requires the separate forest-valid rule exported by forest.bundle.

  runner = executable: {
    protocol = "sdoc-policy.runner/v1";
    argv = [executable];
    limits = {
      timeoutMs = 10000;
      outputBytes = 16777216;
    };
  };
  entry = name: contract: inputSchemas: configSchema: capabilities: {
    inherit name contract inputSchemas configSchema capabilities;
    resultSchema = "sdoc-policy.rule-result/v1";
    mode = "full";
  };
  # N3: same public registration descriptors for shipped and independent code.
  # These inputs are proposed raw registrations, not implicitly installed adapters.
  inherit (shipped) daemonRegistration gitRegistration graphRegistration modelRegistration nativeRegistration;
  independent = {
    kind = "implementation";
    id = "consumer/checks";
    artifact = artifacts.consumerChecks;
    runner = runner executables.consumerChecks;
    entries = [
      (entry "targets" "sdoc-policy.targets/v1"
        {candidate = "sdoc-policy.model/v1";}
        "sdoc-policy.targets-config/v1" ["model.resolved-endpoints/v1"])
      (entry "field-adaptation" "consumer.field-adaptation/v1"
        {
          candidate = "sdoc-policy.model/v1";
          hierarchy = "sdoc-policy.forest/v1";
        }
        "consumer.field-adaptation-config/v1" ["diagnostic.field-path/v1"])
      (entry "main-protection" "consumer.main-protection/v1"
        {
          candidate = "sdoc-policy.model/v1";
          before = "sdoc-policy.model/v1";
          main = "sdoc-policy.model/v1";
          principal = "consumer.principal/v1";
        }
        "consumer.main-protection-config/v1" ["facts.verified-principal/v1"])
      (entry "document-approval" "consumer.document-approval/v1"
        {
          candidate = "sdoc-policy.model/v1";
          before = "sdoc-policy.model/v1";
          main = "sdoc-policy.model/v1";
          principal = "consumer.principal/v1";
          classification = "consumer.classification/v1";
          approvals = "consumer.approvals/v1";
        }
        "consumer.document-approval-config/v1" ["facts.verified-approval/v1"])
    ];
  };
  source = id: executable: schema: dependencies: config: trust: {
    kind = "source";
    inherit id schema dependencies config trust;
    artifact = executable; # Host derives immutable artifact/config digests.
    runner = runner executable;
  };
  protectedSource =
    source "protected" executables.protectedBaseline
    "sdoc-policy.baseline/v1" [] {inherit modelId projection;}
    {
      verifier = "consumer/trust";
      purpose = "reference-baseline";
    };
  mainSource =
    source "main" executables.mainBaseline "sdoc-policy.model/v1" []
    {
      ref = "refs/heads/main";
      fetch = false;
      model = modelId;
      extractor = artifacts.baselineExtractor;
    }
    {
      verifier = "consumer/trust";
      purpose = "resolved-main-commit";
    };
  principalSource =
    source "principal" executables.verifiedPrincipal
    "consumer.principal/v1" [] {binding = "authenticated-boundary-context";}
    {
      verifier = "consumer/trust";
      purpose = "authenticated-principal";
    };
  classificationSource =
    source "classification" executables.classification
    "consumer.classification/v1" ["main"] {mainRevision = "captured-main";}
    {
      verifier = "consumer/trust";
      purpose = "document-classification";
    };
  approvalSource =
    source "approvals" executables.approvals
    "consumer.approvals/v1" ["main" "principal"]
    {bind = ["candidate" "before" "policy" "main" "principal" "action"];}
    {
      verifier = "consumer/trust";
      purpose = "verified-approval";
    };
  # An independent verifier is itself a publicly registered implementation.
  # Its schema/entry and trusted selection must be fixed before identity use.
  trustRegistration = consumerTrustRegistration;

  graphBindings = map (name: {
    contract = "sdoc-policy.${name}/v1";
    implementation = graphRegistration.id;
    entry = name;
  }) ["targets" "forest-valid" "forest-view" "visible" "count" "endpoint-path" "preserve"];
  bindings =
    graphBindings
    ++ [
      {
        contract = "sdoc-policy.native-dag/v1";
        implementation = nativeRegistration.id;
        entry = "native-dag";
      }
    ];
  # Public per-rule binding specifies the independent route; parity needs testing.
  independentTargetBinding = {
    rule = "reference/R-target";
    implementation = independent.id;
    entry = "targets";
  };

  # N4: illustrative consumer lifecycle, not included in the neutral policy.
  lifecycle = p.bundle {
    id = "consumer/lifecycle";
    rules = [
      {
        id = "consumer/main-protection";
        scope = "change";
        contract = "consumer.main-protection/v1";
        config = {
          inherit projection;
          llmMainRevision = "deny";
          supersession = "no-implicit-exception";
        };
        inputs = {
          inherit candidate before;
          main = factInput "main" "sdoc-policy.model/v1";
          principal = factInput "principal" "consumer.principal/v1";
        };
        needs = ["facts.verified-principal/v1"];
      }
      {
        id = "consumer/document-approval";
        scope = "document";
        contract = "consumer.document-approval/v1";
        config = {
          protectedClasses = ["human-authored" "protected"];
          missingApproval = "approval-required";
          inherit (artifacts) documentProjection;
          bind = ["candidate" "before" "main" "policy" "principal" "action"];
        };
        inputs = {
          inherit candidate before;
          main = factInput "main" "sdoc-policy.model/v1";
          principal = factInput "principal" "consumer.principal/v1";
          classification = factInput "classification" "consumer.classification/v1";
          approvals = factInput "approvals" "consumer.approvals/v1";
        };
        needs = ["facts.verified-approval/v1"];
      }
    ];
  };
  lifecycleBindings = [
    {
      contract = "consumer.main-protection/v1";
      implementation = independent.id;
      entry = "main-protection";
    }
    {
      contract = "consumer.document-approval/v1";
      implementation = independent.id;
      entry = "document-approval";
    }
  ];

  # N5: native Child tailoring. No reference-H path imposed on this vocabulary.
  requirement = {
    grammar = "tailoring";
    element = "REQUIREMENT";
  };
  adaptation = {
    grammar = "tailoring";
    element = "ADAPTATION";
  };
  adapts = {
    grammar = "tailoring";
    ownerElement = "ADAPTATION";
    nativeType = "Parent";
    role = "Adapts";
  };
  applies =
    adapts
    // {
      nativeType = "Child";
      role = "AppliesTo";
    };
  tailoring = p.grammar {
    id = "tailoring";
    elements = [
      (g.el "REQUIREMENT" {} {
        fields = [uid (g.field.str "STATEMENT")];
        relations = [];
      })
      (p.element {
        native = g.el "ADAPTATION" {} {
          fields = [uid (g.field.str "STATEMENT")];
          relations = [(g.rel.parent "Adapts" "AdaptedBy") (g.rel.child "AppliesTo" "AppliedBy")];
        };
        policies = self: [
          (p.targets {
            id = "tailoring/upper-target";
            select = self.parent "Adapts";
            allowed = [requirement];
          })
          (p.targets {
            id = "tailoring/lower-target";
            select = self.child "AppliesTo";
            allowed = [requirement];
          })
        ];
      })
    ];
  };
  tailoringEndpoints = p.bridge {
    id = "tailoring/endpoints";
    records = adaptation;
    upper = adapts;
    lower = applies;
  }; # Counts only. Compose a native-DAG rule for this model when activating it.

  # N6: separate field/custom-rule representation; explicit narrower equivalence.
  fieldElement = g.el "ADAPTATION_FIELDS" {} {
    fields = [
      uid
      (g.field.str "STATEMENT")
      (g.field.required (g.field.str "UPPER_UID"))
      (g.field.required (g.field.str "LOWER_UID"))
    ];
    relations = [];
  };
  fieldRule = {
    id = "consumer/field-adaptation";
    scope = "model";
    contract = "consumer.field-adaptation/v1";
    config = {
      records = {
        grammar = "field-tailoring";
        element = "ADAPTATION_FIELDS";
      };
      upperField = "UPPER_UID";
      lowerField = "LOWER_UID";
      endpointModel = modelId;
      allowed = [foo];
      inherit boundary;
      path = "downward";
      virtualConnectivity = "check-union-DAG";
    };
    inputs = {inherit candidate hierarchy;};
    needs = ["diagnostic.field-path/v1"];
  }; # Add this grammar to the same captured model; do not create native links.
  fieldBinding = {
    inherit (fieldRule) contract;
    implementation = independent.id;
    entry = "field-adaptation";
  };

  # N7: direct Rego owns its language and schema via the same registration.
  regoRule = {
    id = "reference/R-visible";
    scope = "model";
    contract = "consumer.rego-visibility/v1";
    config = {
      select = r;
      inherit boundary;
    };
    inputs = {inherit candidate hierarchy;};
    needs = ["diagnostic.boundary-path/v1" "opa.graph-reachable/v1"];
  };
  opaRegistration = {
    kind = "implementation";
    id = "consumer/opa";
    artifact = artifacts.visibilityRego;
    runner = runner executables.opaProtocolAdapter;
    entries = [
      (entry "data.consumer.visibility.result" regoRule.contract
        {
          candidate = "sdoc-policy.model/v1";
          hierarchy = "sdoc-policy.forest/v1";
        }
        "consumer.rego-visibility-config/v1"
        regoRule.needs)
    ];
  }; # Proposed adapter applies strict CLI errors and required output validation.
  regoBinding = {
    inherit (regoRule) contract;
    implementation = opaRegistration.id;
    entry = "data.consumer.visibility.result";
  };
  regoVariant = p.compose {
    bundles = [reference];
    edits = [
      {
        action = "replace";
        id = "reference/R-visible";
        expect = artifacts.originalVisibilityDefinitionDigest;
        rule = regoRule;
        reason = "Consumer chooses a direct Rego policy";
      }
    ];
  };
  disableExample = {
    action = "disable";
    id = "consumer/document-approval";
    expect = artifacts.originalApprovalDefinitionDigest;
    reason = "Consumer selects a different documented approval policy";
  };

  # N8: proposed boundary configurations, validated against registered adapters.
  daemonBoundary = {
    adapter = daemonRegistration.id;
    modelAdapter = modelRegistration.id;
    policyLoading = artifacts.trustedPolicyLoading;
    candidate = "sealed-private-group";
    admission = "complete-validity";
    group = {
      seal = "authorized-explicit";
      readiness = "consumer-selected";
    };
    requiredCapabilities = [
      "candidate.private-revisioned-staging/v1"
      "publication.refusal-unchanged/v1"
      "publication.restore-or-block/v1"
      "runtime.no-published-writes-during-evaluation/v1"
    ];
  };
  gitBoundary = {
    adapter = gitRegistration.id;
    modelAdapter = modelRegistration.id;
    policyLoading = artifacts.trustedPolicyLoading;
    candidate = "captured-index-tree";
    before = "HEAD";
    mergeBefore = "require-explicit-selection";
    admission = "complete-validity";
    requiredCapabilities = ["candidate.staged-tree/v1" "commit.bind-validated-tree/v1"];
  };
in {
  status = "PROPOSED ONLY; not a deployable module or implemented adapter set";
  inherit model reference effective directTarget directForest projection;
  inherit independent independentTargetBinding protectedSource;
  inherit tailoring tailoringEndpoints fieldElement fieldRule fieldBinding;
  inherit regoRule opaRegistration regoBinding regoVariant disableExample;
  proposedModule = {
    ai = {
      strictdoc = {
        enable = true;
        scribeSource = "installed";
        grammars.reference = {
          target = "requirements/reference.sgra";
          inherit (model) elements;
        };
        policy = {
          model = modelId;
          inherit effective;
          nativeRule = nativeRule.id;
        };
      };
      policyRuntime = {
        mode = "full";
        registrations = [
          graphRegistration
          nativeRegistration
          modelRegistration
          daemonRegistration
          gitRegistration
          independent
          protectedSource
          trustRegistration
        ];
        inherit bindings;
      };
      validation.boundaries = {
        daemon = daemonBoundary;
        commit = gitBoundary;
      };
    };
  };
  # Optional compositions must explicitly install all dependencies/registrations.
  withIndependentTarget = {
    extraRegistrations = [];
    extraBindings = [independentTargetBinding];
  };
  withLifecycle = {
    effective = p.compose {
      bundles = [reference lifecycle];
      edits = [];
    };
    extraRegistrations = [mainSource principalSource classificationSource approvalSource];
    extraBindings = lifecycleBindings;
  };
  withRego = {
    effective = regoVariant;
    extraRegistrations = [opaRegistration];
    extraBindings = [regoBinding];
  };
  both = {
    transaction = daemonBoundary;
    commit = gitBoundary;
    receiptReuse = "matching-required-inputs-only";
  };
  # N9: illustrative messages, not executed RPC operations.
  transaction = [
    {
      operation = "begin";
      payload = {
        baseRevision = "before-42";
        participants = ["agent-A" "agent-B"];
        sealAuthority = "coordinator";
      };
    }
    {
      operation = "stage";
      payload = {
        group = "group-17";
        expectedRevision = 0;
        contributor = "agent-A";
        patch = "create M and M-owned Parent P to F0";
      };
    }
    {
      operation = "stage";
      payload = {
        group = "group-17";
        expectedRevision = 1;
        contributor = "agent-B";
        patch = "add M-owned Child Q to F2";
      };
    }
    {
      operation = "seal";
      payload = {
        group = "group-17";
        expectedRevision = 2;
        authority = "coordinator";
      };
    }
  ];
}
