{
  lib,
  pkgs,
  harness,
  ...
}: let
  rv = import ../../lib/runtime-values {inherit lib;};
  inherit (harness) mkTest;
  evaluate = type: definitions: (lib.evalModules {modules = [{options.value = lib.mkOption {inherit type;};}] ++ map (value: {config = {inherit value;};}) definitions;}).config.value;
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  secret = rv.withReferences {
    type = lib.types.str;
    secret = true;
  };
  sensitive = rv.withReferences {type = lib.types.str;};
  file = rv.file {path = "/run/example";};
  mcp = import ../../lib/mcp.nix {inherit lib;};
in {
  checks = {
    runtime-values-declaration-negative = mkTest "runtime-values-declaration-negative" (let
      declarations =
        (lib.evalModules {
          modules = [
            {
              options.token = lib.mkOption {type = lib.types.str;};
              options.env = lib.mkOption {type = lib.types.attrsOf lib.types.str;};
            }
          ];
        }).options;
    in
      builtins.length (rv.checkOptions {
        options = declarations;
        roots = [["token"] ["env"]];
      })
      == 2);
    runtime-values-schema-walker = mkTest "runtime-values-schema-walker" (
      let
        walked = rv.walk {
          value = {
            public = "value";
            nested.token = file;
          };
        };
      in
        walked.publicValue
        == {
          public = "value";
          nested.token = null;
        }
        && builtins.length walked.bindings == 1
        && (builtins.head walked.bindings).path == ["nested" "token"]
        && rv.schemaFor lib.types.bool == {kind = "bool";}
        && !succeeds (rv.schemaFor lib.types.package)
        && !succeeds (rv.fromSchema {schema.fields.bad = {};}).options.bad
    );
    runtime-values-refinement-negative = mkTest "runtime-values-refinement-negative" (
      let
        refined = lib.types.addCheck lib.types.str (value: value == "allowed");
        generated = rv.fromSchema {
          schema.fields.refined.type = refined;
        };
      in
        !succeeds (rv.schemaFor refined)
        && !succeeds (rv.schemaFor (lib.types.addCheck lib.types.bool (value: value)))
        && !succeeds (rv.schemaFor (lib.types.addCheck lib.types.int (value: value > 0)))
        && !succeeds (evaluate generated.options.refined.type [file])
        && succeeds (evaluate (rv.withReferences {
          type = refined;
          schema = {kind = "str";};
        }) [file])
    );
    runtime-values-declaration-hints = mkTest "runtime-values-declaration-hints" (let
      declarations =
        (rv.fromSchema {
          schema.fields.opaque = {
            type = lib.types.str;
            hints.keyring = true;
          };
        }).options;
      regressed = declarations // {opaque = declarations.opaque // {type = lib.types.str;};};
      evaluated = (lib.evalModules {modules = [{options = regressed;}];}).options;
    in
      rv.checkOptions {
        options = evaluated;
        roots = [["opaque"]];
      }
      == ["opaque"]);
    runtime-values-types = mkTest "runtime-values-types" (
      !succeeds (evaluate secret ["literal"])
      && succeeds (evaluate secret [file])
      && (evaluate secret [file])._runtime.secret
      && succeeds (evaluate sensitive ["literal"])
      && succeeds (evaluate sensitive [file])
      && !succeeds (evaluate secret [file (rv.helper {path = "/run/helper";})])
      && !succeeds (evaluate sensitive [(file // {ordinary = "sibling";})])
      && !succeeds (evaluate sensitive [
        (rv.file {
          path = "/x";
          decode = "json";
        })
      ])
    );
    runtime-values-decoration-types = mkTest "runtime-values-decoration-types" (
      let
        decorated = rv.file {
          path = "/run/example";
          prefix = "prefix-";
        };
        decoratedSuffix = rv.file {
          path = "/run/example";
          suffix = "-suffix";
        };
      in
        succeeds (evaluate (rv.withReferences {type = lib.types.str;}) [decorated])
        && !succeeds (evaluate (rv.withReferences {type = lib.types.bool;}) [decorated])
        && !succeeds (evaluate (rv.withReferences {type = lib.types.int;}) [decoratedSuffix])
        && !succeeds (evaluate (rv.withReferences {type = lib.types.enum ["allowed"];}) [decorated])
    );
    runtime-values-key-aware-map = mkTest "runtime-values-key-aware-map" (let
      type = rv.keyAwareMap {type = lib.types.str;};
    in
      !succeeds (evaluate type [{gitlab_token = "literal";}])
      && succeeds (evaluate type [
        {
          gitlab_token = file;
          host = "public";
        }
      ])
      && (evaluate type [{gitlab_token = file;}]).gitlab_token._runtime.secret);
    runtime-values-secret-map-audit-negative = mkTest "runtime-values-secret-map-audit-negative" (let
      declarations = type:
        (lib.evalModules {
          modules = [
            {
              options.credentials = lib.mkOption {
                inherit type;
                default = {};
              };
            }
          ];
        }).options;
      audit = type:
        rv.checkOptions {
          options = declarations type;
          roots = [["credentials"]];
        };
    in
      audit (rv.keyAwareMap {type = lib.types.str;})
      == ["credentials"]
      && audit (rv.keyAwareMap {
        type = lib.types.str;
        path = ["credentials"];
      })
      == ["credentials"]
      && audit (rv.keyAwareMap {
        type = lib.types.str;
        secretContainer = true;
      })
      == []
      && succeeds (evaluate (rv.keyAwareMap {type = lib.types.str;}) [{alice = "literal-secret";}]));
    runtime-values-classifier = mkTest "runtime-values-classifier" (
      rv.classify {path = ["host"];}
      == "sensitive"
      && rv.classify {
        path = ["anything"];
        hints.keyring = true;
      }
      == "secret"
      && rv.classify {
        path = ["anything"];
        secretContainer = true;
      }
      == "secret"
      && rv.classify {path = ["apiKeyHelper"];} == "sensitive"
      && rv.classify {path = ["signingKey"];} == "sensitive"
      && rv.classify {path = ["GITLAB_ACCESS_TOKEN"];} == "secret"
      && lib.all (name: rv.classify {path = [name];} == "secret") [
        "api_key"
        "authorization"
        "clientSecret"
        "credentials"
        "gitlab_token"
        "password"
        "privateKey"
        "secret"
        "token"
      ]
      && lib.all (name: rv.classify {path = [name];} == "sensitive") [
        "apiKeyHelper"
        "api_key_file"
        "api_key_path"
        "max_tokens"
        "password_path"
        "private_key_file"
        "token_dir"
        "token_env"
        "token_file"
        "token_limit"
        "token_path"
        "token_url"
        "token_var"
        "tokenEnvVar"
        "tokenizer"
      ]
      && rv.classify {
        path = ["token_file"];
        hints.secret = true;
      }
      == "secret"
      && rv.classify {
        path = ["token_url"];
        secretContainer = true;
      }
      == "secret"
    );
    runtime-values-argv = mkTest "runtime-values-argv" (
      !succeeds (rv.assignment {
        inherit pkgs;
        variable = "argument";
        value = evaluate secret [file];
        output = "argv";
      })
      && !succeeds (rv.assignment {
        inherit pkgs;
        variable = "TOKEN";
        value = file;
        output = "argv";
      })
      && succeeds (rv.assignment {
        inherit pkgs;
        variable = "HOST";
        value = file;
        output = "argv";
      })
    );
    runtime-values-mcp-envelope = mkTest "runtime-values-mcp-envelope" (
      let
        old = {file = "/run/example";};
        spec = {credentials.envVar = "TOKEN";};
        gitlabSpec = {apiUrl = (mcp.loadServer "gitlab-mcp").meta.credentialVars.apiUrl;};
      in
        !succeeds (mcp.credentialsEnvironment pkgs spec {credentials = old;})
        && !succeeds (mcp.credentialFilePaths spec {credentials = old;})
        && succeeds (mcp.credentialsEnvironment pkgs gitlabSpec {apiUrl = old;})
        && mcp.credentialFilePaths gitlabSpec {apiUrl = old;} == ["/run/example"]
    );
    runtime-values-lift = mkTest "runtime-values-lift" (let
      options = rv.liftOptions {
        options = {
          nested = lib.mkOption {
            type = lib.types.submodule {
              options.token = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
            };
          };
          env = lib.mkOption {type = lib.types.attrsOf lib.types.str;};
        };
      };
      evaluateOptions = config: (lib.evalModules {modules = [{inherit options config;}];}).config;
    in
      succeeds (evaluateOptions {
        nested.token = file;
        env.HOST = file;
      })
      && !succeeds (evaluateOptions {
        nested.token = "literal";
        env = {};
      }));
  };
}
