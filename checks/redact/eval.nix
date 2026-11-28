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
  inherit (redact.types) environment;
  asFile = value: {_redact.asFile = value;};
  reader = lib.getExe (import ../../lib/redact/reader.nix {inherit pkgs;});
  assign = variable: value: export:
    redact.assign {
      inherit export pkgs value variable;
      option = "test.token";
    };
  # The real evaluator supplies both a path value and string context.
  # Keep the interpolated source-path regression, and separately test the
  # context restriction on text that would pass the lexical store-path check.
  rejectsFile = invalid:
    harness.rejectsChange redact.file {
      inherit invalid;
      expected = {_redact.file = "/run/secrets/token";};
      valid = "/run/secrets/token";
    };
  cases = {
    # References: positional constructors returning exactly the marker.
    "command takes a store program without context" =
      redact.command "${builtins.storeDir}/aaaa-tool/bin/tool"
      == {_redact.command = "${builtins.storeDir}/aaaa-tool/bin/tool";};
    "file refuses context on a path outside the store" =
      rejectsFile (builtins.appendContext "/run/secrets/token" (builtins.getContext "${./eval.nix}"));
    "file refuses an interpolated Nix source path" = rejectsFile "${./eval.nix}";
    "file refuses a Nix path rather than coercing it to a string" = rejectsFile ./eval.nix;

    # maybeRedacted: native values and references reach their own merge paths.
    "maybeRedacted attrsOf keeps a reference whole" = evaluate (maybe (lib.types.attrsOf lib.types.str)) command == command;
    "maybeRedacted attrsOf takes cleartext" = evaluate (maybe (lib.types.attrsOf lib.types.str)) {a = "b";} == {a = "b";};
    "maybeRedacted int takes an int" = evaluate (maybe lib.types.int) 1 == 1;
    "maybeRedacted str takes a concat" = evaluate (maybe lib.types.str) bearer == bearer;

    # environment: pin the merged names and values, including explicit null.
    "environment preserves each member including explicit null" = let
      definition = {
        API_TOKEN = file;
        AUTHORIZATION = bearer;
        EDITOR = "vim";
        GITLAB_HOST = command;
        REMOVED = null;
      };
    in
      evaluate environment definition == definition;

    # filePaths follows references even when the service delivers them by path.
    "filePaths unwraps tags and retains only files in order" =
      redact.filePaths (asFile (redact.concat [command (redact.file "/run/secrets/z") "literal" (redact.file "/run/secrets/a")]))
      == ["/run/secrets/z" "/run/secrets/a"];

    # assign: one function for every value. The reader's argv is the label,
    # kinds, paths and literal parts, and the path need not exist: nothing is
    # read at evaluation.
    "assign passes mixed parts in order to a single reader call" =
      assign "TOKEN" (redact.concat ["Bearer " (redact.file "/run/secrets/t") "/" command]) true
      == ''
        TOKEN="$(${reader} test.token literal 'Bearer ' file /run/secrets/t literal / command /run/current-system/sw/bin/read-token)" || exit 1
        export TOKEN'';
    "assign null neither sets nor removes an inherited variable" = assign "TOKEN" null true == "";
    "assign emits a read at launch even for an absent file" =
      assign "TOKEN" (redact.file "/nonexistent/token") false
      == ''TOKEN="$(${reader} test.token file /nonexistent/token)" || exit 1'';
  };
in {
  checks.redact-eval = harness.mkTest "redact-eval" (harness.checkRows "redact-eval" cases);
}
