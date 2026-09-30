{
  lib,
  pkgs,
  harness,
  ...
}: let
  rv = import ../../lib/runtime-values {inherit lib;};
  inherit (harness) mkTest;
  evaluate = type: definitions:
    (lib.evalModules {
      modules =
        [{options.value = lib.mkOption {inherit type;};}]
        ++ map (value: {config = {inherit value;};}) definitions;
    }).config.value;
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  file = rv.file {path = "/run/example";};
  otherFile = rv.file {path = "/run/other";};
  mcp = import ../../lib/mcp.nix {inherit lib;};
in {
  checks = {
    runtime-values-argv = mkTest "runtime-values-argv" (let
      secretReference = evaluate (rv.withReferences {
        type = lib.types.str;
        secret = true;
      }) [file];
    in
      !succeeds (rv.assignment {
        inherit pkgs;
        argv = true;
        value = secretReference;
        variable = "ARG";
      })
      && !succeeds (rv.assignment {
        inherit pkgs;
        argv = true;
        secret = true;
        value = "literal";
        variable = "ARG";
      })
      && !succeeds (rv.assignment {
        inherit pkgs;
        secret = true;
        value = "literal";
        variable = "ENV";
      })
      && !succeeds (rv.assignment {
        inherit pkgs;
        value._runtime = {
          secret = true;
          source = {
            file = "/run/example";
            helper = "/run/helper";
          };
        };
        variable = "ENV";
      })
      && succeeds (rv.assignment {
        inherit pkgs;
        argv = true;
        value = file;
        variable = "ARG";
      }));

    runtime-values-classifier = mkTest "runtime-values-classifier" (let
      cases = {
        apiKey = true;
        check_update = false;
        CI_JOB_TOKEN = true;
        client_key = false;
        configDir = false;
        extraSettings = false;
        GITLAB_HOST = false;
        GLAB_CONFIG_DIR = false;
        gitTokens = true;
        host = false;
        job_token = true;
        oauth2_refresh_token = true;
        refresh_token = true;
        token = true;
      };
    in
      lib.all (name: rv.classify {path = [name];} == cases.${name}) (builtins.attrNames cases));

    runtime-values-key-aware-map = mkTest "runtime-values-key-aware-map" (let
      plain = rv.keyAwareMap {
        type = lib.types.str;
        path = ["settings"];
      };
      classified = rv.keyAwareMap {
        type = lib.types.str;
        path = ["extraSettings"];
      };
      secret = rv.keyAwareMap {
        type = lib.types.str;
        path = ["gitTokens"];
        secretContainer = true;
      };
      nullableSecret = rv.keyAwareMap {
        type = lib.types.nullOr lib.types.str;
        path = ["gitTokens"];
        secretContainer = true;
      };
      defaultThenStrong = evaluate secret [
        {host = lib.mkDefault "discarded";}
        {host = file;}
      ];
      forced = evaluate secret [
        {host = "discarded";}
        {host = lib.mkForce otherFile;}
      ];
      removed = evaluate nullableSecret [
        {host = lib.mkDefault file;}
        {host = null;}
      ];
    in
      !succeeds (evaluate classified [{gitlab_token = "literal";}])
      && !succeeds (evaluate classified [{gitlab_token = "first";} {gitlab_token = "second";}])
      && (evaluate classified [{gitlab_token = file;}]).gitlab_token._runtime.secret
      && defaultThenStrong.host._runtime.source.file == "/run/example"
      && forced.host._runtime.source.file == "/run/other"
      && removed.host == null
      && evaluate plain [{host = "literal";}] == {host = "literal";}
      && !succeeds (evaluate (rv.keyAwareMap {
        type = lib.types.str;
        path = ["settings"];
        secretContainer = true;
      }) [{host = "literal";}]));

    runtime-values-mcp-envelope = mkTest "runtime-values-mcp-envelope" (!succeeds (mcp.credentialsEnvironment pkgs {credential.envVar = "TOKEN";} {credential = {file = "/run/example";};}));

    runtime-values-types = mkTest "runtime-values-types" (let
      cases = [
        {
          type = lib.types.str;
          literal = "value";
        }
        {
          type = lib.types.bool;
          literal = true;
        }
      ];
      accepts = entry: let
        type = rv.withReferences {inherit (entry) type;};
      in
        evaluate type [entry.literal]
        == entry.literal
        && rv.isReference (evaluate type [file]);
      secret = lib.types.nullOr (rv.withReferences {
        type = lib.types.str;
        secret = true;
      });
      unsupported = [
        (lib.types.attrsOf lib.types.str)
        (lib.types.enum ["value"])
        lib.types.int
        (lib.types.listOf lib.types.str)
        (lib.types.submodule {})
      ];
    in
      lib.all accepts cases
      && !succeeds (evaluate secret ["literal"])
      && !succeeds (evaluate secret ["first" "second"])
      && !succeeds (evaluate secret [{_runtime = null;}])
      && !succeeds (evaluate secret [
        {
          _runtime = {
            secret = true;
            source = {
              file = "/run/example";
              helper = "/run/helper";
            };
          };
        }
      ])
      && !succeeds (evaluate secret [
        {
          _runtime = {
            extra = true;
            secret = true;
            source.file = "/run/example";
          };
        }
      ])
      && evaluate secret [null] == null
      && (evaluate secret [file])._runtime.secret
      && lib.all (type: !succeeds (rv.withReferences {inherit type;})) unsupported);
  };
}
