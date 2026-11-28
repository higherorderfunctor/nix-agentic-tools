{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
  fileLib = import ../lib/files/default.nix {inherit lib pkgs;};
  tree = ./fixtures/a;
  storeTree = "${tree}";
  linkedTree = ./fixtures;
  file = ./fixtures/a/b/c.md;
  text = {content.text = "hello";};
  evaluate = definitions: (lib.evalModules {modules = [../modules/common.nix {ai.files = definitions;}];}).config.ai.files;
  plan = backend: files:
    fileLib.normalize {
      inherit backend files;
      namespace = "fixture";
    };
  inspect = files:
    fileLib.validate {
      backend = "hm";
      inherit files;
      namespace = "fixture";
    };
  single = path: value: evaluate {"${path}" = value;};
  bad = path: value: issue: {inherit path value issue;};
  named = path: issue: ''files."${path}": ${issue}'';
  pathIssue = "target must be a normalized relative path without empty, . or .. segments";
  cases =
    map (path: bad path text pathIssue) ["" "/absolute" "a/./b" "a//b"]
    ++ [
      # Group read permission must not be mistaken for owner read permission.
      (bad "group-readable" (text
        // {
          method = "ro";
          mode = "0040";
        }) "ro mode must grant owner read permission")
      (bad "missing" {} "set one of content.text, content.source, content.value, content.run")
      (bad "recursive.txt" (text // {recursive = true;}) "recursive requires content.source to be a directory")
      (bad "recursive" {
        content.source = tree;
        format = "json";
        method = "rw";
        recursive = true;
      } "rw cannot be recursive")
      (bad "run" {content.run = "printf ok";} "content.run requires ro or rw method")
      (bad "mode" (text // {mode = "0600";}) "mode requires ro or rw method")
      (bad "both" (text
        // {
          executable = true;
          method = "ro";
          mode = "0600";
        }) "mode and executable cannot both be set")
      (bad "linked" {
        content.source = linkedTree;
        method = "ro";
        recursive = true;
      } ''recursive ro source contains a directory symlink at "linked/link"'')
      (bad "bad-value" {
        content.value.a = _: 1;
        format = "json";
      } "content.value must contain only null, booleans, numbers, strings, lists and string-keyed maps")
      (bad "null.toml" {
        content.value.a.b = null;
        format = "toml";
      } ''TOML cannot represent null at "/a/b"'')
    ];
  typeCase = backend: path: valid: invalid: {inherit backend invalid path valid;};
  contentSource = path: {content.source = path;};
  validSource = contentSource "${storeTree}/b/c.md";
  typeCases =
    [
      (typeCase "hm" "executable" (text // {executable = true;}) (text // {executable = "bogus";}))
      (typeCase "hm" "format" (text // {format = "raw";}) (text // {format = "bogus";}))
      (typeCase "hm" "source" validSource (contentSource "/etc/passwd"))
      (typeCase "hm" "source.escape" validSource (contentSource "${storeTree}/../../../etc/passwd"))
    ]
    ++ lib.concatMap (field: let
      other =
        if field == "hm"
        then "devenv"
        else "hm";
      methodFor = method: text // {inherit method;};
      baseMethod = {${other} = "ro";};
      methodWith = value: methodFor (baseMethod // {${field} = value;});
      valid = methodWith "symlink";
    in [
      (typeCase field "method.${field}.invalid" valid (methodWith "bogus"))
      (typeCase field "method.${field}.missing" valid (methodFor baseMethod))
    ]) ["devenv" "hm"];
  # Common fields use the shared merge once. For a method record, only the
  # selected method field is forced by normalize, so target that backend.
  typeRestrictions = checkRows "files schema restrictions" (builtins.listToAttrs (map (row:
    lib.nameValuePair "${row.backend}: refuses invalid ${row.path}" (rejectsChange (value: let
      normalized = plan row.backend (single row.path value);
    in
      builtins.deepSeq normalized (map (leaf: leaf.path) normalized)) {
      inherit (row) invalid valid;
      expected = [row.path];
    }))
  typeCases));
  # These are the semantic refusals returned by the actual planner validator.
  refuses = files: expected: inspect files == expected && !(builtins.tryEval (plan "hm" files)).success;
  semanticRestrictions = checkRows "files planner restrictions" (builtins.listToAttrs (map (row:
    lib.nameValuePair (named row.path row.issue) (refuses (single row.path row.value) (named row.path row.issue)))
  cases));
  # A derivation source must normalize without being built: this one cannot
  # build, so any import-from-derivation fails the whole check.
  neverBuilt = derivation {
    name = "files-never-built";
    inherit (pkgs.stdenv.hostPlatform) system;
    builder = "/bin/false";
  };
  derivationSource = plan "hm" (single "settings.json" {
    content.source = neverBuilt;
    method = "ro";
  });
  collisions = checkRows "files destination collisions" {
    "explicit destination may not overwrite an expanded leaf" = refuses (evaluate {
      tree = {
        content.source = tree;
        recursive = true;
      };
      "tree/b/c.md" = text;
    }) (named "tree/b/c.md" ''destination overlaps "tree/b/c.md"'');
    "file destination may not also be a parent directory" = refuses (evaluate {
      tree = text;
      "tree/child" = text;
    }) (named "tree/child" ''destination overlaps "tree"'');
  };
  merged = (lib.evalModules {modules = [../modules/common.nix {ai.files.value.content.value.a.x = 1;} {ai.files.value.content.value.a.y = 2;}];}).config.ai.files;
  tie = inspect (single "tie" {
    content = {
      source = file;
      text = "a";
    };
  });
  methods = single "method" {
    content.text = "x";
    method = {
      devenv = "ro";
      hm = "symlink";
    };
  };
  leaves = plan "hm" (single "tree" {
    content.source = tree;
    recursive = true;
  });
  stringLeaves = plan "hm" (single "tree" {
    content.source = storeTree;
    recursive = true;
  });
  normalizationRows = checkRows "files normalization" {
    "backend method follows the selected backend" = (builtins.head (plan "devenv" methods)).method == "ro" && (builtins.head (plan "hm" methods)).method == "symlink";
    "derivation source stays a store reference without building it" = builtins.deepSeq derivationSource (map (leaf: [leaf.path leaf.content.source]) derivationSource == [["settings.json" "${neverBuilt}"]]);
    "recursive path preserves its single leaf and source dependency" = map (leaf: leaf.path) leaves == ["tree/b/c.md"] && builtins.toJSON (builtins.head leaves).content.source == builtins.toJSON file && builtins.getContext (builtins.toJSON leaves) != {};
    "recursive store string preserves its single leaf and source dependency" = map (leaf: [leaf.path leaf.content.source]) stringLeaves == [["tree/b/c.md" "${storeTree}/b/c.md"]] && builtins.getContext (builtins.toJSON stringLeaves) != {};
    "same-priority content alternatives do not silently choose one" = tie == named "tie" "content alternatives tie at priority 100: source, text";
    "structured content preserves child leaves from both definitions" =
      merged.value.content.value.a
      == {
        x = 1;
        y = 2;
      };
  };
in {
  checks.ai-module-files-eval = assert typeRestrictions;
  assert semanticRestrictions;
  assert collisions;
  assert normalizationRows;
    pkgs.runCommandLocal "ai-module-files-eval" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      printf 'PASS: files schema, recursive normalization, priority, and ${toString (builtins.length cases + builtins.length typeCases)} refusals\n' > "$out"
    '';
}
