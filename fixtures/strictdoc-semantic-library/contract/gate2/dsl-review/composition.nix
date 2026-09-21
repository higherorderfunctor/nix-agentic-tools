let
  dsl = import ./dsl.nix;
  inherit (dsl) el field rel model normalize check on contribute isNodeType const;
  inherit (field) required str;
  inherit (rel) parent;
  inherit (dsl) parentOf;

  uid = required (str "UID");
  targetType = check "target-type" (edge: isNodeType edge.target foo);
  foo = el "FOO" {} {
    fields = [uid];
    relations = [
      (parent "R" "R_back" (check "target-type" (edge: isNodeType edge.target foo)))
    ];
    constraints = [];
  };
  # The base form puts the same named check in the element's Meta list.
  baseFoo = el "FOO" {} {
    fields = [uid];
    relations = [
      (parent "R" "R_back")
    ];
    constraints = [(on (parentOf baseFoo "R") targetType)];
  };
  declaration = model "composition" {elements = [foo];};

  # Contribute to the relation that was already declared above.
  equivalent = normalize (declaration
    // {
      contributions = [
        (contribute "extra-target-check" (parentOf foo "R") [targetType])
      ];
    });
in {
  inherit equivalent;
  sameNormalized =
    normalize declaration
    == normalize (declaration // {elements = [baseFoo];});
  deduplicated = builtins.length equivalent.bundle.rules == 1;
  conflict = normalize (declaration
    // {
      contributions = [
        (contribute "incompatible-target-check" (parentOf foo "R") [
          (check "target-type" (const false))
        ])
      ];
    });
}
