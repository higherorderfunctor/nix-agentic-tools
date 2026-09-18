# Field and rel only group constructor imports; all authoring calls are bare.
# No semantic prefix: checks read alongside the fields and relations they govern.
let
  dsl = import ./dsl.nix;
  inherit (dsl) el field rel model normalize check record all;
  inherit (field) required str boolean creationDefault;
  inherit (rel) parent child;
  inherit (dsl) parentOf childOf fieldOf isNodeType atMost exactly only;
  inherit (dsl) forest isForest visibility visible canDescend nativeDag;
  inherit (dsl) input projection preserve;

  uid = required (str "UID");
  flag = creationDefault false (required (boolean "FLAG"));

  # The element is the model; constraints are its Meta.
  foo = el "FOO" {} {
    fields = [uid flag];
    relations = [
      (parent "H" "H_back" (edge: isNodeType edge.target foo))
      (parent "R" "R_back" (edge: all [(isNodeType edge.target foo) (visible sight edge.origin edge.target)]))
    ];
    constraints = [
      (check "one-H-parent" (record (node: atMost 1 (node.parents "H"))))
    ];
  };

  # Both endpoints belong to this bridge record.
  bar = el "BAR" {} {
    fields = [uid];
    relations = [
      (parent "P" "P_back" (edge: isNodeType edge.target foo))
      (child "Q" "Q_back" (edge: isNodeType edge.target foo))
    ];
    constraints = [
      (check "one-P" (record (bridge: exactly 1 (bridge.parents "P"))))
      (check "one-Q" (record (bridge: exactly 1 (bridge.children "Q"))))
      (check "endpoint-path" (record (bridge:
        canDescend sight
        (only (bridge.parents "P")).target
        (only (bridge.children "Q")).target)))
    ];
  };

  # The same role spellings carry no FOO/BAR restrictions here.
  baz = el "BAZ" {} {
    fields = [uid];
    relations = [
      (parent "R" "R_back")
      (child "Q" "Q_back")
    ];
    constraints = [];
  };

  # Only FOO Parent H supplies ancestry; multiple roots are valid.
  h = forest "H" (parentOf foo "H");
  sight = visibility "H-visibility" h {
    closedWhenTrue = fieldOf foo flag;
    ascent = "unrestricted";
    visit = "always";
    expand = "open-or-origin-in-subtree-including-self";
  };

  # Declare the input; acquisition and capture belong to runtime.
  baseline = input "baseline" {
    kind = "external-snapshot";
    required = true;
    complete = true;
  };
  modeledRecord = projection "modeled-record" {
    key = "UID";
    existence = true;
    element = true;
    fields = [(fieldOf foo flag)];
    fieldPresence = true;
    ownedRelations = [
      (parentOf foo "H")
      (parentOf foo "R")
      (parentOf bar "P")
      (childOf bar "Q")
      (parentOf baz "R")
      (childOf baz "Q")
    ];
    relationProjection = ["nativeType" "role" "target"];
    relationOrder = "set";
  };

  # The all-role DAG is independent of the selected forest and visibility.
  rules = [
    (check "native-dag" nativeDag)
    (check "H-forest" (isForest h))
    (check "baseline-preserved" (preserve baseline modeledRecord))
  ];
in
  normalize (model "reference" {
    elements = [foo bar baz];
    views = [h sight];
    inputs = [baseline];
    projections = [modeledRecord];
    constraints = rules;
  })
