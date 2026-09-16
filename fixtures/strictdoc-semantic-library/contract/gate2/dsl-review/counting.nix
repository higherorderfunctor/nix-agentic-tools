let
  dsl = import ./dsl.nix;
  inherit (dsl) el rel model normalize check record count lte atMost atLeast exactly;
  inherit (rel) parent;

  item = el "Item" {} {
    relations = [(parent "link" "link_back")];
    constraints = [
      (check "link-count" (record (node: lte (count (node.parents "link")) 1)))
      (check "at-most-one-link" (record (node: atMost 1 (node.parents "link"))))
      (check "at-least-one-link" (record (node: atLeast 1 (node.parents "link"))))
      (check "exactly-one-link" (record (node: exactly 1 (node.parents "link"))))
    ];
  };

  # Proof scaffolding: isolate each authored rule with the same check identity.
  lower = index:
    normalize (model "counting" {
      elements = [
        (item
          // {
            constraints = [(builtins.elemAt item.constraints index // {name = "link-count";})];
          })
      ];
    });
  lowest = lower 0;
  sugar = lower 1;
in {
  example = normalize (model "counting" {elements = [item];});
  inherit lowest sugar;
  atLeastExample = lower 2;
  exactlyExample = lower 3;
  sugarEqualsLowest = sugar == lowest;
}
