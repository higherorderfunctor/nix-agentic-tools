{dsl}: let
  runtimeFields = [
    (dsl.field.required (dsl.field.str "AUTHORED_BY"))
    (dsl.field.str "PARENT_FP")
    (dsl.field.required (dsl.field.str "UID"))
  ];
  element = tag: fields: relations:
    dsl.el tag {} {
      fields = runtimeFields ++ fields;
      inherit relations;
    };
in [
  (element "BAR" [] [
    (dsl.rel.parent "P" "P_back")
    (dsl.rel.child "Q" "Q_back")
  ])
  (element "BAZ" [] [
    (dsl.rel.child "Q" "Q_back")
    (dsl.rel.parent "R" "R_back")
  ])
  (element "FOO" [
      (dsl.field.required (dsl.field.one "FLAG" ["false" "true"]))
    ] [
      (dsl.rel.parent "H" "H_back")
      (dsl.rel.parent "R" "R_back")
    ])
]
