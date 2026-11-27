# Results from the flake export consumers use. Refusal messages are checked
# in messages.nix: tryEval cannot see them.
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
  file = redact.file "/run/secrets/token";
  command = redact.command "/run/current-system/sw/bin/read-token";
  bearer = redact.concat ["Bearer " file];
  maybe = redact.types.maybeRedacted;
  inherit (redact.types) environment orSecretFile redacted secretFile;
  asFile = value: {_redact.asFile = value;};
  reader = lib.getExe (import ../../lib/redact/reader.nix {inherit pkgs;});
  assign = variable: value: export:
    redact.assign {
      inherit export pkgs value variable;
      option = "test.token";
    };
  cases = {
    # References: positional constructors returning exactly the marker.
    "command marker" = command == {_redact.command = "/run/current-system/sw/bin/read-token";};
    "command takes a store program without context" =
      redact.command "${builtins.storeDir}/aaaa-tool/bin/tool"
      == {_redact.command = "${builtins.storeDir}/aaaa-tool/bin/tool";};
    "concat marker" = bearer == {_redact.concat = ["Bearer " file];};
    "file marker" = file == {_redact.file = "/run/secrets/token";};
    # Retain the source-path regression cases in the real evaluator. Compare
    # a runtime path with and without context to isolate the context restriction
    # from the store path prefix restriction.
    "file refuses a Nix path value" = harness.rejectsChange redact.file {
      expected = {_redact.file = "/run/secrets/token";};
      invalid = ./eval.nix;
      valid = "/run/secrets/token";
    };
    "file refuses a path with store context" = harness.rejectsChange redact.file {
      expected = {_redact.file = "/run/secrets/token";};
      invalid = "${./eval.nix}";
      valid = "/run/secrets/token";
    };
    "file refuses context on a path outside the store" = harness.rejectsChange redact.file {
      expected = {_redact.file = "/run/secrets/token";};
      invalid = builtins.appendContext "/run/secrets/token" (builtins.getContext "${./eval.nix}");
      valid = "/run/secrets/token";
    };

    # redacted keeps references whole.
    "redacted takes a command" = evaluate redacted command == command;
    "redacted takes a concat" = evaluate redacted bearer == bearer;
    "redacted takes a file" = evaluate redacted file == file;

    # maybeRedacted: native values and references reach their own merge paths.
    "maybeRedacted attrsOf keeps a reference whole" = evaluate (maybe (lib.types.attrsOf lib.types.str)) command == command;
    "maybeRedacted attrsOf takes cleartext" = evaluate (maybe (lib.types.attrsOf lib.types.str)) {a = "b";} == {a = "b";};
    "maybeRedacted int takes an int" = evaluate (maybe lib.types.int) 1 == 1;
    "maybeRedacted str takes a concat" = evaluate (maybe lib.types.str) bearer == bearer;
    "maybeRedacted str takes a reference" = evaluate (maybe lib.types.str) file == file;
    "maybeRedacted str takes cleartext" = evaluate (maybe lib.types.str) "public-host" == "public-host";

    # environment: pin the merged names and values, including explicit null.
    "environment" = let
      definition = {
        API_TOKEN = file;
        AUTHORIZATION = bearer;
        EDITOR = "vim";
        GITLAB_HOST = command;
        REMOVED = null;
      };
    in
      evaluate environment definition == definition;
    "environment takes a secretFile value" = evaluate environment {CPA_MANAGER_ADMIN_KEY_FILE = asFile file;} == {CPA_MANAGER_ADMIN_KEY_FILE = asFile file;};

    # secretFile tags a reference for path delivery and can forward a tag.
    "filePaths sees through the tag" = redact.filePaths (asFile bearer) == ["/run/secrets/token"];
    "orSecretFile keeps a tagged value" = evaluate (orSecretFile redacted) (asFile file) == asFile file;
    "orSecretFile keeps an untagged value" = evaluate (orSecretFile redacted) file == file;
    "secretFile keeps a tagged value" = evaluate secretFile (asFile file) == asFile file;
    "secretFile tags a reference" = evaluate secretFile file == asFile file;

    # assign: one function for every value. The reader's argv is the label,
    # kinds, paths and literal parts, and the path need not exist: nothing is
    # read at evaluation.
    "assign escapes a literal" = assign "TOKEN" "it's" true == "TOKEN='it'\\''s'\nexport TOKEN";
    "assign joins a concat" =
      assign "TOKEN" (redact.concat ["Bearer " (redact.file "/run/secrets/t") "/" command]) true
      == ''
        TOKEN="$(${reader} test.token literal 'Bearer ' file /run/secrets/t literal / command /run/current-system/sw/bin/read-token)" || exit 1
        export TOKEN'';
    "assign keeps a store command as a dependency" =
      builtins.hasAttr (builtins.unsafeDiscardStringContext pkgs.hello.drvPath) (builtins.getContext (assign "TOKEN" (redact.command (lib.getExe pkgs.hello)) false));
    "assign null" = assign "TOKEN" null true == "";
    "assign reads a reference" =
      assign "TOKEN" (redact.file "/nonexistent/token") false
      == ''TOKEN="$(${reader} test.token file /nonexistent/token)" || exit 1'';
    "assign without export" = assign "TOKEN" "x" false == "TOKEN=x";
  };
in {
  checks.redact-eval = harness.mkTest "redact-eval" (harness.checkRows "redact-eval" cases);
}
