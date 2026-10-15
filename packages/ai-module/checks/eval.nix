{
  lib,
  pkgs,
  ...
}: let
  files2 = import ../lib/files/default.nix {inherit lib pkgs;};
  tree = ./fixtures/a;
  storeTree = "${tree}";
  linkedTree = ./fixtures;
  file = ./fixtures/a/b/c.md;
  text = {content.text = "hello";};
  evaluate = definitions: (lib.evalModules {modules = [../modules/common.nix {ai.files2 = definitions;}];}).config.ai.files2;
  plan = backend: files:
    files2.normalize {
      inherit backend files;
      namespace = "fixture";
    };
  inspect = files:
    files2.validate {
      backend = "hm";
      inherit files;
      namespace = "fixture";
    };
  single = path: value: evaluate {"${path}" = value;};
  bad = path: value: issue: {inherit path value issue;};
  named = path: issue: ''files2."${path}": ${issue}'';
  pathIssue = "target must be a normalized relative path without empty, . or .. segments";
  cases =
    map (path: bad path text pathIssue) ["" "/absolute" "a//b" "a/./b" "a/../b"]
    ++ map (mode:
      bad "unreadable-${mode}" (text
        // {
          inherit mode;
          method = "ro";
        }) "ro mode must grant owner read permission") ["0000" "0040" "0200"]
    ++ [
      (bad "missing" {} "set one of content.text, content.source, content.value, content.run")
      (bad "value.raw" {content.value.a = 1;} "content.value requires json, toml or yaml format")
      (bad "rw.raw" (text // {method = "rw";}) "rw requires json, toml or yaml format")
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
        recursive = true;
      } ''recursive source contains a directory symlink at "linked/link"'')
      (bad "bad-value" {
        content.value.a = _: 1;
        format = "json";
      } "content.value must contain only null, booleans, numbers, strings, lists and string-keyed maps")
      (bad "null.toml" {
        content.value.a.b = null;
        format = "toml";
      } ''TOML cannot represent null at "/a/b"'')
    ];
  typeCases =
    map (field: {
      path = field;
      value = text // {"${field}" = "bogus";};
    }) ["executable" "format"]
    ++ lib.concatMap (field: let
      other =
        if field == "hm"
        then "devenv"
        else "hm";
    in [
      {
        path = "method.${field}.invalid";
        value =
          text
          // {
            method = {
              "${field}" = "bogus";
              "${other}" = "ro";
            };
          };
      }
      {
        path = "method.${field}.missing";
        value = text // {method = {"${other}" = "ro";};};
      }
    ]) ["devenv" "hm"]
    ++ [
      {
        path = "source";
        value = {content.source = "/etc/passwd";};
      }
      {
        path = "source.escape";
        value = {content.source = "${storeTree}/../../../etc/passwd";};
      }
    ];
  typeErrors = lib.concatMap (backend:
    map (row:
      lib.optional (builtins.tryEval (builtins.deepSeq (plan backend (single row.path row.value)) true)).success "${backend}:${row.path}")
    typeCases) ["devenv" "hm"];
  errors = map (row: let
    files = single row.path row.value;
    expected = named row.path row.issue;
  in
    lib.optional (inspect files != expected || (builtins.tryEval (plan "hm" files)).success) row.path)
  cases;
  # A derivation source must normalize without being built: this one cannot
  # build, so any import-from-derivation fails the whole check.
  neverBuilt = derivation {
    name = "files2-never-built";
    inherit (pkgs.stdenv.hostPlatform) system;
    builder = "/bin/false";
  };
  derivationSource = builtins.deepSeq (plan "hm" (single "settings.json" {
    content.source = neverBuilt;
    method = "ro";
  })) [];
  collisionFiles = [
    (evaluate {
      tree = {
        content.source = tree;
        recursive = true;
      };
      "tree/b/c.md" = text;
    })
    (evaluate {
      tree = text;
      "tree/child" = text;
    })
  ];
  collisionExpected = [
    (named "tree/b/c.md" ''destination overlaps "tree/b/c.md"'')
    (named "tree/child" ''destination overlaps "tree"'')
  ];
  collisionErrors = lib.imap0 (index: files: let
    result = inspect files;
  in
    lib.optional (result != builtins.elemAt collisionExpected index || (builtins.tryEval (plan "hm" files)).success) "collision")
  collisionFiles;
  priority = default: explicit: expected: let
    files = (lib.evalModules {modules = [../modules/common.nix {ai.files2.choice.content = lib.mkDefault default;} {ai.files2.choice.content = explicit;}];}).config.ai.files2;
  in
    builtins.elem expected (builtins.attrNames (builtins.head (plan "hm" files)).content);
  merged = (lib.evalModules {modules = [../modules/common.nix {ai.files2.value.content.value.a.x = 1;} {ai.files2.value.content.value.a.y = 2;}];}).config.ai.files2;
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
  failures =
    lib.concatLists (errors ++ collisionErrors ++ typeErrors)
    ++ derivationSource
    ++ lib.optional (!priority {text = "default";} {source = file;} "source") "default text priority"
    ++ lib.optional (!priority {source = file;} {text = "explicit";} "text") "default source priority"
    ++ lib.optional (merged.value.content.value.a
      != {
        x = 1;
        y = 2;
      }) "structured child merge"
    ++ lib.optional (tie != named "tie" "content alternatives tie at priority 100: source, text") "priority tie"
    ++ lib.optional ((builtins.head (plan "devenv" methods)).method != "ro" || (builtins.head (plan "hm" methods)).method != "symlink") "backend method"
    ++ lib.optional (map (leaf: leaf.path) leaves != ["tree/b/c.md"] || builtins.toJSON (builtins.head leaves).content.source != builtins.toJSON file || builtins.attrNames (builtins.getContext (builtins.toJSON leaves)) == []) "recursive path leaves"
    ++ lib.optional ((builtins.head stringLeaves).content.source != "${storeTree}/b/c.md" || builtins.attrNames (builtins.getContext (builtins.toJSON stringLeaves)) == []) "recursive string leaves"
    ++ lib.optional ((builtins.head (plan "hm" (single "directory" {content.source = tree;}))).path != "directory") "directory link"
    ++ lib.optional (plan "hm" (single "off" {enable = false;}) != []) "disabled";
in {
  checks.files2-eval = assert lib.assertMsg (failures == []) "files2 eval fixtures failed: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "files2-eval" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      printf 'PASS: files2 schema, recursive normalization, priority, and ${toString (builtins.length cases + builtins.length typeCases)} refusals\n' > "$out"
    '';
}
