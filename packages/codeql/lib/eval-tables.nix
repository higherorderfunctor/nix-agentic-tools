# Weak head normal form module-system facts. No derivation paths or structured values are forced.
{lib}: {
  modules,
  result,
  root ? null,
  source,
}: let
  attempt = fallback: value: let
    tried = builtins.tryEval value;
  in
    if tried.success
    then tried.value
    else fallback;
  relative = file: let
    text = toString file;
    prefix = toString root + "/";
  in
    if root != null && lib.hasPrefix prefix text
    then lib.removePrefix prefix text
    else text;
  position = pos: {
    file = relative (pos.file or "");
    line =
      if (pos.line or null) == null
      then -1
      else pos.line;
    column =
      if (pos.column or null) == null
      then -1
      else pos.column;
  };
  optionAt = options: path: lib.attrByPath path null options;
  collect = evaluated: moduleList: prefix: let
    specialArgs = evaluated.type.functor.payload.specialArgs or {};
  in
    (lib.modules.collectModules (specialArgs.modulesPath or "") moduleList ({
        inherit lib specialArgs;
        inherit (evaluated) options;
        config = evaluated.config // {inherit (evaluated) _module;};
        _class = evaluated.class or null;
        _prefix = prefix;
      }
      // specialArgs)).modules;
  # Configuration.type retains the exact modules and specialArgs, including
  # instance definitions, so recollection preserves losing leaf definitions.
  definitions = evaluated: moduleList: prefix: let
    emit = file: path: pos: priority: conditions: kind: let
      option = optionAt evaluated.options (lib.drop (lib.length prefix) path);
      active = lib.all (c: c == true) conditions;
      highest = attempt (-1) (option.highestPrio or (-1));
    in [
      ({
          inherit active kind path priority source;
          aliasForward = priority == 1500;
          conditionCount = lib.length conditions;
          moduleFile = relative file;
          wins = active && highest == priority;
        }
        // position pos)
    ];
    walk = file: path: pos: priority: conditions: value: let
      inspected = builtins.tryEval (builtins.typeOf value);
      kind =
        if inspected.success
        then inspected.value
        else "unknown";
      tag =
        if kind == "set"
        then attempt null (value._type or null)
        else null;
    in
      if !inspected.success
      then emit file path pos priority conditions kind
      else if tag != null
      then
        if tag == "if"
        then let
          condition = attempt false value.condition;
        in
          if condition == true
          then walk file path pos priority (conditions ++ [true]) value.content
          # Its content may throw even at weak head normal form. Do not inspect inactive content.
          else emit file path pos priority (conditions ++ [false]) "inactive"
        else if tag == "merge"
        then lib.concatMap (walk file path pos priority conditions) value.contents
        else if tag == "override"
        then walk file path pos value.priority conditions value.content
        else if tag == "order"
        then walk file path pos priority conditions value.content
        else emit file path pos priority conditions kind
      else if lib.isOption (optionAt evaluated.options (lib.drop (lib.length prefix) path))
      then emit file path pos priority conditions kind
      else if kind == "set"
      then
        lib.concatLists (lib.mapAttrsToList (name: child: let
          found = builtins.unsafeGetAttrPos name value;
        in
          walk file (path ++ [name]) (
            if found == null
            then pos
            else found
          )
          priority
          conditions
          child)
        value)
      else emit file path pos priority conditions kind;
  in
    lib.concatMap (module: walk module._file prefix {} 100 [] module.config) (collect evaluated moduleList prefix);
  graph = parent: nodes:
    lib.concatMap (node:
      [
        {
          inherit source;
          inherit (node) disabled;
          file = relative node.file;
          importedBy = parent;
          key = toString node.key;
        }
      ]
      ++ graph (relative node.file) node.imports)
    nodes;
  # getSubOptions includes declarations even when no instance is configured.
  # Stop recursive schema types at a repeated declaration signature; actual
  # finite instances still recurse through their own valueMeta configuration.
  options = instance: ancestors: tree:
    lib.concatMap (option: let
      path = option.loc;
      meta = attempt {} option.valueMeta;
      signature = builtins.toJSON [option.type.name (map toString option.declarations)];
      nested = configuration: let
        actualPrefix = lib.take (lib.length configuration.options._module.args.loc - 2) configuration.options._module.args.loc;
      in {
        options = options (lib.showOption actualPrefix) ancestors configuration.options;
        definitions = definitions configuration configuration.type.getSubModules actualPrefix;
      };
      configurations = metadata:
        if metadata ? configuration
        then [(nested metadata.configuration)]
        else if metadata ? attrs
        then lib.concatMap configurations (lib.attrValues metadata.attrs)
        else if metadata ? list
        then lib.concatMap configurations metadata.list
        else [];
      children = configurations meta;
      schema =
        if children != [] || lib.elem signature ancestors
        then []
        else options (lib.showOption path) (ancestors ++ [signature]) (attempt {} (option.type.getSubOptions path));
      defined = attempt false option.isDefined;
      scalar =
        if defined
        then
          attempt null (let
            inherit (option) value;
            kind = builtins.typeOf value;
          in
            if lib.elem kind ["bool" "int"]
            then {
              inherit kind;
              value = builtins.toJSON value;
            }
            else if kind == "string" && builtins.stringLength value <= 256 && !(lib.hasPrefix "/nix/store/" value)
            then {inherit kind value;}
            else null)
        else null;
    in
      [
        {
          option = {
            inherit instance path source;
            isDefined = defined;
            generated = lib.all (pos: (pos.line or null) == null) option.declarationPositions;
            hasApply = option ? apply;
            hasDefault = option ? default;
            highestPrio = attempt (-1) option.highestPrio;
            internal = option.internal or false;
            readOnly = option.readOnly or false;
            type = option.type.name;
            typeDescription = attempt "unknown" option.type.description;
            visible = builtins.toJSON (option.visible or true);
          };
          declarations = map (pos: {inherit path source;} // position pos) option.declarationPositions;
          value = lib.optional (scalar != null) (scalar // {inherit path source;});
          definitions = lib.concatMap (child: child.definitions) children;
        }
      ]
      ++ schema ++ lib.concatMap (child: child.options) children) (lib.collect lib.isOption tree);
  rows = options "" [] result.options;
  showPath = row: row // {path = lib.showOption row.path;};
in {
  definition = map showPath (definitions result modules [] ++ lib.concatMap (row: row.definitions) rows);
  module = graph "" result.graph;
  option = map (row: showPath row.option) rows;
  option_decl = map showPath (lib.concatMap (row: row.declarations) rows);
  value = map showPath (lib.concatMap (row: row.value) rows);
}
