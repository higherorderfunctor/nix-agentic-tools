# Accept and refuse cases for references, the three types and `assign`, read
# through the flake export consumers use. Messages are checked in messages.nix:
# tryEval cannot see them.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (self.lib) redact;
  evaluate = type: value:
    (lib.evalModules {
      modules = [
        {options.value = lib.mkOption {inherit type;};}
        {config.value = value;}
      ];
    }).config.value;
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  accepts = type: value: succeeds (evaluate type value);
  file = redact.file "/run/secrets/token";
  command = redact.command "/run/current-system/sw/bin/read-token";
  bearer = redact.concat ["Bearer " file];
  maybe = redact.types.maybeRedacted;
  reader = lib.getExe (import ../../lib/redact/reader.nix {inherit pkgs;});
  assign = variable: value: export:
    redact.assign {
      inherit export pkgs value variable;
      option = "test.token";
    };
  cases = {
    # References: positional constructors returning exactly the marker.
    "command marker" = command == {_redact.command = "/run/current-system/sw/bin/read-token";};
    "file marker" = file == {_redact.file = "/run/secrets/token";};
    "refuses a relative path" = !succeeds (redact.file "run/secrets/token");
    "refuses a relative command" = !succeeds (redact.command "read-token");
    "refuses a Nix path value" = !succeeds (redact.file ./eval.nix);
    "refuses a path with store context" = !succeeds (redact.file "${./eval.nix}");
    "refuses a command with store context" = !succeeds (redact.command (lib.getExe pkgs.hello));
    "refuses a store file without context" = !succeeds (redact.file "${builtins.storeDir}/aaaa-source/secret");
    "refuses a traversal into the store" = !succeeds (redact.file "/run/..${builtins.storeDir}/aaaa-source/secret");
    "refuses an empty segment" = !succeeds (redact.file "/${builtins.storeDir}/aaaa-source/secret");
    "command takes a store program without context" = succeeds (redact.command "${builtins.storeDir}/aaaa-tool/bin/tool");

    # Concat: strings and references, at least one reference, no nesting.
    "concat marker" = bearer == {_redact.concat = ["Bearer " file];};
    "refuses a concat without a reference" = !succeeds (redact.concat ["Bearer " "literal"]);
    "refuses a nested concat" = !succeeds (redact.concat ["a" bearer]);

    # redacted: sealed.
    "redacted takes a file" = evaluate redact.types.redacted file == file;
    "redacted takes a command" = accepts redact.types.redacted command;
    "redacted takes a concat" = evaluate redact.types.redacted bearer == bearer;
    "redacted refuses a literal" = !accepts redact.types.redacted "literal-secret";
    "redacted refuses a hand-built relative marker" = !accepts redact.types.redacted {_redact.file = "relative";};
    "redacted refuses a two-source marker" =
      !accepts redact.types.redacted {
        _redact = {
          command = "/b";
          file = "/a";
        };
      };
    "redacted refuses a hand-built literal concat" = !accepts redact.types.redacted {_redact.concat = ["literal"];};

    # maybeRedacted: any type, plus anything redacted accepts.
    "maybeRedacted str takes cleartext" = evaluate (maybe lib.types.str) "public-host" == "public-host";
    "maybeRedacted str takes a reference" = evaluate (maybe lib.types.str) file == file;
    "maybeRedacted str takes a concat" = accepts (maybe lib.types.str) bearer;
    "maybeRedacted str refuses an int" = !accepts (maybe lib.types.str) 1;
    "maybeRedacted str refuses a malformed marker" = !accepts (maybe lib.types.str) {_redact.file = "relative";};
    "maybeRedacted int takes an int" = evaluate (maybe lib.types.int) 1 == 1;
    "maybeRedacted int refuses a string" = !accepts (maybe lib.types.int) "literal";
    "maybeRedacted attrsOf keeps a reference whole" = evaluate (maybe (lib.types.attrsOf lib.types.str)) command == command;
    "maybeRedacted attrsOf takes cleartext" = evaluate (maybe (lib.types.attrsOf lib.types.str)) {a = "b";} == {a = "b";};

    # environment: secret-classified names are sealed.
    "environment" =
      evaluate redact.types.environment {
        API_TOKEN = file;
        AUTHORIZATION = bearer;
        EDITOR = "vim";
        GITLAB_HOST = command;
        REMOVED = null;
      }
      == {
        API_TOKEN = file;
        AUTHORIZATION = bearer;
        EDITOR = "vim";
        GITLAB_HOST = command;
        REMOVED = null;
      };
    "environment refuses a literal secret" = !accepts redact.types.environment {API_TOKEN = "literal-secret";};
    "environment refuses a dashed name" = !accepts redact.types.environment {"BAD-NAME" = "x";};
    "environment refuses a leading digit" = !accepts redact.types.environment {"1X" = "x";};
    "environment refuses an invalid name set to null" = !accepts redact.types.environment {"BAD-NAME" = null;};

    # assign: one function for every value. The reader's argv is the label,
    # kinds, paths and literal parts, and the path need not exist: nothing is
    # read at evaluation.
    "assign null" = assign "TOKEN" null true == "";
    "assign escapes a literal" = assign "TOKEN" "it's" true == "TOKEN='it'\\''s'\nexport TOKEN";
    "assign without export" = assign "TOKEN" "x" false == "TOKEN=x";
    "assign reads a reference" =
      assign "TOKEN" (redact.file "/nonexistent/token") false
      == ''TOKEN="$(${reader} test.token file /nonexistent/token)" || exit 1'';
    "assign joins a concat" =
      assign "TOKEN" (redact.concat ["Bearer " (redact.file "/run/secrets/t") "/" command]) true
      == ''
        TOKEN="$(${reader} test.token literal 'Bearer ' file /run/secrets/t literal / command /run/current-system/sw/bin/read-token)" || exit 1
        export TOKEN'';
    "assign refuses an invalid name" = !succeeds (assign "BAD-NAME" "x" true);
    "assign refuses an int" = !succeeds (assign "TOKEN" 1 true);
    "assign refuses a malformed marker" = !succeeds (assign "TOKEN" {_redact.file = "relative";} true);
  };
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) cases);
in {
  checks.redact-eval = harness.mkTest "redact-eval" (
    assert lib.assertMsg (failed == []) "redact-eval failed: ${builtins.toJSON failed}"; true
  );
}
