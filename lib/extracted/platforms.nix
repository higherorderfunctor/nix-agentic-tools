# One committed file per owner (dev/fragments/extracted/facts-contract.md,
# "The committed file"). Builtins only: the regenerate script in ./default.nix
# imports this file alone, outside any flake.
let
  sentinel = "__platforms";
  isFork = node: builtins.isAttrs node && node ? ${sentinel};
  hasFork = node: isFork node || (builtins.isAttrs node && builtins.any (key: hasFork node.${key}) (builtins.attrNames node));
  optional = condition: value:
    if condition
    then [value]
    else [];
  keysOf = nodes: builtins.attrNames (builtins.foldl' (acc: node: acc // node) {} nodes);
  refuse = caller: path: node:
    if builtins.isList node
    then builtins.all (refuse caller "${path}[]") node
    else if !builtins.isAttrs node
    then true
    else if node ? ${sentinel}
    then throw "lib.extracted.platforms.${caller}: `${path}` holds the reserved key `${sentinel}` in measured data"
    else builtins.all (key: refuse caller "${path}.${key}" node.${key}) (builtins.attrNames node);

  # `values` holds the systems that carry this node. Agreement is stored once;
  # attribute sets every system carries are compared per key; anything else
  # forks whole, arrays included.
  fork = count: values: let
    present = builtins.attrValues values;
    first = builtins.head present;
    everywhere = builtins.length present == count;
  in
    if everywhere && builtins.all (value: value == first) present
    then first
    else if everywhere && builtins.all builtins.isAttrs present
    then
      builtins.listToAttrs (map (key: {
        name = key;
        value = fork count (builtins.mapAttrs (_: value: value.${key}) (removeLacking key values));
      }) (keysOf present))
    else {${sentinel} = values;};
  removeLacking = key: values: builtins.removeAttrs values (builtins.filter (system: !(values.${system} ? ${key})) (builtins.attrNames values));

  # `[]` when `system` lacks the node, else `[value]`.
  pick = system: path: node:
    if isFork node
    then
      if builtins.attrNames node != [sentinel]
      then throw "lib.extracted.platforms.project: `${path}` mixes `${sentinel}` with other keys"
      else if node.${sentinel} ? ${system}
      then assert refuse "project" path node.${sentinel}.${system}; [node.${sentinel}.${system}]
      else []
    else if builtins.isAttrs node
    then [
      (builtins.listToAttrs (builtins.concatMap (key:
        map (value: {
          name = key;
          inherit value;
        }) (pick system "${path}.${key}" node.${key}))
      (builtins.attrNames node)))
    ]
    else [node];

  # A system's view after the base system's fresh measurement: its forks keep
  # its own value, every unforked node takes the fresh one. A forked parent
  # the fresh raw removes or retypes keeps the system's whole committed value,
  # never a partial mix neither host measured. Both arguments are `[]` or
  # `[value]`.
  follow = system: path: committed: fresh: let
    node = builtins.head committed;
    at = attrs: key: optional (attrs ? ${key}) attrs.${key};
  in
    if committed == [] || !hasFork node
    then fresh
    else if fresh == [] || !builtins.isAttrs (builtins.head fresh) || isFork node
    then pick system path node
    else [
      (builtins.listToAttrs (builtins.concatMap (key:
        map (value: {
          name = key;
          inherit value;
        }) (follow system "${path}.${key}" (at node key) (at (builtins.head fresh) key)))
      (keysOf [node (builtins.head fresh)])))
    ];
in rec {
  # { "<system>" = raw; } -> the committed tree.
  merge = raws:
    assert builtins.all (system: refuse "merge" system raws.${system}) (builtins.attrNames raws);
      fork (builtins.length (builtins.attrNames raws)) raws;

  # The committed tree -> one system's raw.
  project = merged: system: let
    picked = pick system system merged;
  in
    if picked == []
    then throw "lib.extracted.platforms.project: the committed tree has no ${system} side"
    else builtins.head picked;

  # Replaces the sides of `fresh` (`{ "<system>" = raw; }`) in `merged`. When
  # the base system is fresh, every other system in `systems` keeps its forks
  # and follows the fresh raw elsewhere, so a base bump introduces no
  # divergence; that system's own extraction then validates its projection.
  # Any other fresh system leaves the rest at their exact projections, so its
  # new differences become forks.
  carry = {
    fresh,
    merged,
    systems,
  }: let
    base = "x86_64-linux";
    others = builtins.filter (system: !(fresh ? ${system})) systems;
    lead =
      if builtins.length (builtins.attrNames fresh) == 1
      then builtins.attrValues fresh
      else throw "lib.extracted.platforms.carry: ${toString others} must follow exactly one fresh system, not ${toString (builtins.attrNames fresh)}";
    side = system:
      if fresh ? ${base}
      then let
        followed = follow system system [merged] lead;
      in
        if followed == []
        then {}
        else builtins.head followed
      else project merged system;
  in
    merge (fresh
      // builtins.listToAttrs (map (system: {
          name = system;
          value = side system;
        })
        others));
}
