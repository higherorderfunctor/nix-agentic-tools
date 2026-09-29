# cspell:ignore relift
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
in {
  checks = {
    # Round-4 regressions: declaration type merging and substituted submodules.
    runtime-values-declaration-merging = mkTest "runtime-values-declaration-merging" (let
      merged = left: right: value:
        (lib.evalModules {
          modules = [
            {options.value = lib.mkOption {type = left;};}
            {
              options.value = lib.mkOption {type = right;};
              config.value = value;
            }
          ];
        }).config.value;
      plain = rv.withReferences {type = lib.types.str;};
      extended =
        merged
        (rv.withReferences {type = lib.types.enum ["first"];})
        (rv.withReferences {type = lib.types.enum ["second"];});
      mapType = rv.keyAwareMap {type = lib.types.str;};
      mapOfSubmodules = rv.keyAwareMap {
        type = lib.types.submodule {options.host = lib.mkOption {type = lib.types.str;};};
        path = ["credentials"];
      };
      publicMap = rv.keyAwareMap {
        type = lib.types.submodule {options.host = lib.mkOption {type = lib.types.str;};};
        path = ["settings"];
      };
      secretMap = rv.keyAwareMap {
        type = lib.types.submodule {options.host = lib.mkOption {type = lib.types.str;};};
        path = ["settings"];
        secretContainer = true;
      };
      mixedMap = left: right: value: merged left right value;
      guardMixedMap = left: right: let
        reference = (mixedMap left right {alice.host = file;}).alice.host;
      in
        !succeeds (mixedMap left right {alice.host = "literal";})
        && reference._runtime.secret
        && !succeeds (rv.assignment {
          inherit pkgs;
          value = reference;
          variable = "ARG";
          output = "argv";
        });
      refined = (lib.types.addCheck lib.types.str (value: value == "allowed")) // {typeMerge = _: refined;};
      described = rv.withReferences {
        type = refined;
        schema = {
          kind = "enum";
          values = ["allowed"];
        };
      };
      mixed = value:
        merged plain (rv.withReferences {
          type = lib.types.str;
          secret = true;
        })
        value;
    in
      succeeds (merged plain plain "literal")
      && extended "first" == "first"
      && extended "second" == "second"
      && !succeeds (extended "third")
      && succeeds (merged mapType mapType {host = "literal";})
      && (merged mapOfSubmodules mapOfSubmodules {alice.host = file;}).alice.host._runtime.secret
      && !succeeds (merged mapOfSubmodules mapOfSubmodules {alice.host = "literal";})
      && guardMixedMap publicMap secretMap
      && guardMixedMap secretMap publicMap
      && (merged described described file)._runtime.validation.values == ["allowed"]
      && !succeeds (mixed "literal")
      && (mixed file)._runtime.secret);
    runtime-values-submodule-map-classification = mkTest "runtime-values-submodule-map-classification" (let
      declared = lib.types.submodule {options.host = lib.mkOption {type = lib.types.str;};};
      freeform = lib.types.submodule {freeformType = lib.types.attrsOf lib.types.str;};
      cases = [
        (rv.liftOptions {options.credentials = lib.mkOption {type = lib.types.attrsOf declared;};}).credentials.type
        (rv.liftOptions {options.credentials = lib.mkOption {type = lib.types.nullOr (lib.types.attrsOf declared);};}).credentials.type
        (rv.liftOptions {options.credentials = lib.mkOption {type = lib.types.attrsOf freeform;};}).credentials.type
        (rv.keyAwareMap {
          type = declared;
          path = ["credentials"];
        })
        (rv.keyAwareMap {
          type = freeform;
          path = ["credentials"];
        })
      ];
      verify = type: let
        value = input: evaluate type [{alice.host = input;}];
        reference = (value file).alice.host;
      in
        (type.substSubModules type.getSubModules).name
        == type.name
        && !succeeds (value "literal")
        && reference._runtime.secret
        && reference._runtime.classification == "secret"
        && !succeeds (rv.assignment {
          inherit pkgs;
          value = reference;
          path = ["credentials" "alice" "host"];
          variable = "ARG";
          output = "argv";
        });
      dynamicCases = [
        {
          type = (rv.liftOptions {options.value = lib.mkOption {type = lib.types.attrsOf declared;};}).value.type;
          field = "host";
        }
        {
          type = (rv.liftOptions {options.value = lib.mkOption {type = lib.types.attrsOf freeform;};}).value.type;
          field = "alice";
        }
        {
          type = (rv.liftOptions {options.value = lib.mkOption {type = lib.types.attrsOf (lib.types.nullOr declared);};}).value.type;
          field = "host";
          nullable = true;
        }
        {
          type = rv.keyAwareMap {type = declared;};
          field = "host";
        }
        {
          type = rv.keyAwareMap {type = freeform;};
          field = "alice";
        }
        {
          type = rv.keyAwareMap {type = lib.types.nullOr declared;};
          field = "host";
          nullable = true;
        }
      ];
      verifyDynamic = entry: let
        value = input: evaluate entry.type [{credentials = {${entry.field} = input;};}];
        reference = builtins.getAttr entry.field (value file).credentials;
        evaluatedType = (lib.evalModules {modules = [{options.value = lib.mkOption {inherit (entry) type;};}];}).options.value.type;
      in
        entry.type.name
        == "runtimeValueMap"
        && evaluatedType.name == "runtimeValueMap"
        && (entry.type.substSubModules entry.type.getSubModules).name == "runtimeValueMap"
        && !succeeds (value "literal")
        && reference._runtime.secret
        && reference._runtime.classification == "secret"
        && (! (entry.nullable or false) || succeeds (evaluate entry.type [{credentials = null;}]))
        && !succeeds (rv.assignment {
          inherit pkgs;
          value = reference;
          path = ["value" "credentials" entry.field];
          variable = "ARG";
          output = "argv";
        });
    in
      lib.all verify cases && lib.all verifyDynamic dynamicCases);
    runtime-values-monotonic-relift = mkTest "runtime-values-monotonic-relift" (let
      declarations = [
        {credentials.alice = lib.mkOption {type = sensitive;};}
        {credentials = lib.mkOption {type = rv.keyAwareMap {type = lib.types.str;};};}
      ];
      verify = options: let
        lifted = rv.liftOptions {inherit options;};
        value = input:
          (lib.evalModules {
            modules = [
              {
                options = lifted;
                config.credentials.alice = input;
              }
            ];
          }).config.credentials.alice;
        reference = value file;
      in
        !succeeds (value "literal")
        && reference._runtime.secret
        && reference._runtime.classification == "secret"
        && !succeeds (rv.assignment {
          inherit pkgs;
          value = reference;
          path = ["credentials" "alice"];
          variable = "ARG";
          output = "argv";
        });
      strong = [
        secret
        (rv.keyAwareMap {
          type = lib.types.str;
          hints.secret = true;
        })
        (rv.keyAwareMap {
          type = lib.types.str;
          path = ["credentials"];
        })
      ];
      noDowngrade = type: let
        lifted = (rv.liftOptions {options.public = lib.mkOption {inherit type;};}).public.type;
        isMap = type.name == "runtimeValueMap";
        input = v:
          if isMap
          then {alice = v;}
          else v;
        result = evaluate lifted [(input file)];
        reference =
          if isMap
          then result.alice
          else result;
      in
        !succeeds (evaluate lifted [(input "literal")]) && reference._runtime.secret;
    in
      lib.all verify declarations && lib.all noDowngrade strong);
    runtime-values-container-relift = mkTest "runtime-values-container-relift" (let
      cases = [
        {
          type = lib.types.listOf lib.types.str;
          value = v: [v];
        }
        {
          type = lib.types.submodule {options.alice = lib.mkOption {type = lib.types.str;};};
          value = v: {alice = v;};
        }
      ];
      verify = entry: let
        first = (rv.liftOptions {options.public = lib.mkOption {inherit (entry) type;};}).public.type;
        relift = type: (rv.liftOptions {options.credentials = lib.mkOption {inherit type;};}).credentials.type;
        result = evaluate (relift first) [(entry.value file)];
        refined = relift (lib.types.addCheck first (_: false));
        changedMerge = relift (first // {merge = _: _: entry.value "literal";});
      in
        !succeeds (evaluate (relift first) [(entry.value "literal")])
        && succeeds result
        && lib.all (binding: binding.reference.secret) (rv.walk {value = result;}).bindings
        && !succeeds (evaluate refined [(entry.value "literal")])
        && !succeeds (evaluate refined [(entry.value file)])
        && !succeeds (evaluate changedMerge [(entry.value file)]);
    in
      lib.all verify cases);
    runtime-values-opaque-literals = mkTest "runtime-values-opaque-literals" (let
      cases = [
        {
          type = lib.types.addCheck lib.types.str (value: value == "allowed");
          valid = "allowed";
          invalid = "forbidden";
        }
        {
          type = lib.types.ints.positive;
          valid = 1;
          invalid = 0;
        }
        {
          type = lib.types.strMatching "allowed";
          valid = "allowed";
          invalid = "forbidden";
        }
        {
          type = lib.types.addCheck (lib.types.listOf lib.types.str) (value: builtins.length value == 1);
          valid = ["allowed"];
          invalid = [];
        }
        {
          type = lib.types.addCheck (lib.types.attrsOf lib.types.str) (value: value ? allowed);
          valid.allowed = "yes";
          invalid = {};
        }
        {
          type = lib.types.addCheck (lib.types.nullOr lib.types.str) (value: value == null || value == "allowed");
          valid = "allowed";
          invalid = "forbidden";
        }
        {
          type = lib.types.addCheck (lib.types.submodule {options.allowed = lib.mkOption {type = lib.types.bool;};}) (value: value.allowed or false);
          valid.allowed = true;
          invalid.allowed = false;
        }
      ];
      verify = entry: let
        lifted = (rv.liftOptions {options.value = lib.mkOption {inherit (entry) type;};}).value.type;
      in
        succeeds (evaluate lifted [entry.valid]) && !succeeds (evaluate lifted [entry.invalid]);
    in
      lib.all verify cases);
    runtime-values-original-merge = mkTest "runtime-values-original-merge" (let
      scalar = lib.types.str // {merge = loc: defs: (lib.types.str.merge loc defs) + "-once";};
      map = rv.keyAwareMap {type = scalar;};
      transformed = (lib.types.addCheck lib.types.str (value: value == "allowed")) // {merge = _: _: "changed";};
      transformedMap = rv.keyAwareMap {type = transformed;};
      customList = lib.types.listOf lib.types.str // {merge = _: _: ["replacement"];};
      lifted = (rv.liftOptions {options.value = lib.mkOption {type = customList;};}).value.type;
    in
      evaluate (rv.withReferences {type = scalar;}) ["literal"]
      == "literal-once"
      && (evaluate map [{host = "literal";}]).host == "literal-once"
      && (evaluate transformedMap [{host = "allowed";}]).host == evaluate transformed ["allowed"]
      && evaluate lifted [["literal"]] == ["replacement"]);
    runtime-values-recursive-containers = mkTest "runtime-values-recursive-containers" (let
      cases = [
        {
          type = lib.types.listOf lib.types.str;
          value = [file];
        }
        {
          type = lib.types.attrsOf lib.types.str;
          value.host = file;
        }
        {
          type = lib.types.submodule {
            options.host = lib.mkOption {
              type = lib.types.str;
              default = "default";
            };
          };
          value.host = file;
        }
      ];
      verify = entry: let
        lifted = type: (rv.liftOptions {options.value = lib.mkOption {inherit type;};}).value.type;
      in
        succeeds (evaluate (lifted entry.type) [entry.value])
        && succeeds (evaluate (lifted (lib.types.nullOr entry.type)) [entry.value])
        && evaluate (lifted (lib.types.nullOr entry.type)) [null] == null
        && !succeeds (evaluate (lifted entry.type) [file]);
    in
      lib.all verify cases);
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
          schema = {
            kind = "enum";
            values = ["allowed"];
          };
        }) [file])
    );
    runtime-values-merge-customization-negative = mkTest "runtime-values-merge-customization-negative" (let
      customList = lib.types.listOf lib.types.str // {merge = _: _: ["replacement"];};
      customScalar = lib.types.str // {merge = _: _: "replacement";};
      lifted =
        (rv.liftOptions {
          options.value = lib.mkOption {type = customList;};
        }).value.type;
    in
      evaluate customList [["original"]]
      == ["replacement"]
      && evaluate lifted [["original"]] == ["replacement"]
      && !succeeds (evaluate (rv.withReferences {type = customList;}) [file])
      && !succeeds (evaluate (rv.withReferences {type = customScalar;}) [file]));
    runtime-values-refinement-layers = mkTest "runtime-values-refinement-layers" (let
      leaf = lib.types.addCheck lib.types.str (value: value == "allowed");
      submodule = lib.types.submodule {
        options.value = lib.mkOption {type = lib.types.str;};
      };
      cases = [
        {
          type = lib.types.str;
          valid = "allowed";
          invalid = "forbidden";
          reference = true;
        }
        {
          type = lib.types.bool;
          valid = true;
          invalid = false;
          reference = true;
        }
        {
          type = lib.types.int;
          valid = 1;
          invalid = 2;
          reference = true;
        }
        {
          type = lib.types.float;
          valid = 1.0;
          invalid = 2.0;
          reference = true;
        }
        {
          type = lib.types.enum ["allowed" "forbidden"];
          valid = "allowed";
          invalid = "forbidden";
          reference = true;
        }
        {
          type = lib.types.nullOr lib.types.str;
          valid = null;
          invalid = "forbidden";
          reference = true;
        }
        {
          type = lib.types.listOf lib.types.str;
          valid = ["allowed"];
          invalid = ["forbidden"];
          reference = false;
        }
        {
          type = lib.types.attrsOf lib.types.str;
          valid = {value = "allowed";};
          invalid = {value = "forbidden";};
          reference = false;
        }
        {
          type = submodule;
          valid = {value = "allowed";};
          invalid = {value = "forbidden";};
          reference = false;
        }
      ];
      rejectsRefinement = entry: let
        refined = lib.types.addCheck entry.type (_: false);
        plain = (rv.liftOptions {options.value = lib.mkOption {inherit (entry) type;};}).value.type;
        lifted =
          (rv.liftOptions {
            options.value = lib.mkOption {type = refined;};
          }).value.type;
      in
        succeeds (evaluate entry.type [entry.valid])
        && (
          if entry.reference
          then succeeds (evaluate plain [entry.valid]) && succeeds (evaluate plain [file])
          else succeeds (evaluate plain [entry.valid]) && !succeeds (evaluate plain [file])
        )
        && !refined.check entry.invalid
        && !succeeds (evaluate lifted [entry.invalid])
        && !succeeds (evaluate lifted [file])
        && !succeeds (evaluate (rv.withReferences {type = refined;}) [file]);
      innerTypes = [
        {
          type = lib.types.nullOr leaf;
          valid = null;
          invalid = "forbidden";
        }
        {
          type = lib.types.listOf leaf;
          valid = ["allowed"];
          invalid = ["forbidden"];
        }
        {
          type = lib.types.attrsOf leaf;
          valid = {value = "allowed";};
          invalid = {value = "forbidden";};
        }
        {
          type = lib.types.submodule {options.value = lib.mkOption {type = leaf;};};
          valid = {value = "allowed";};
          invalid = {value = "forbidden";};
        }
      ];
      rejectsInner = entry: let
        lifted = (rv.liftOptions {options.value = lib.mkOption {inherit (entry) type;};}).value.type;
      in
        succeeds (evaluate entry.type [entry.valid])
        && !succeeds (evaluate lifted [entry.invalid])
        && !succeeds (evaluate lifted [file])
        && !succeeds (evaluate (rv.withReferences {inherit (entry) type;}) [file]);
    in
      lib.all rejectsRefinement cases
      && lib.all rejectsInner innerTypes
      && succeeds (evaluate (rv.withReferences {type = lib.types.strMatching "allowed";}) [file])
      && !succeeds (evaluate (rv.withReferences {type = lib.types.ints.positive;}) [file])
      && !succeeds (evaluate (rv.withReferences {type = lib.types.either lib.types.str lib.types.int;}) [file])
      && !succeeds (evaluate (rv.withReferences {
        type = lib.types.enum ["allowed"];
        schema = {kind = "str";};
      }) [file])
      && !succeeds (evaluate (rv.withReferences {
        type = lib.types.bool;
        schema = {kind = "str";};
      }) [file])
      && !succeeds (evaluate (rv.withReferences {
        type = lib.types.submodule {options.value = lib.mkOption {type = leaf;};};
        schema = {kind = "str";};
      }) [file])
      && !succeeds (evaluate (rv.withReferences {
        type = lib.mkOptionType {
          name = "str";
          check = value: value == "allowed";
          merge = _: _: "replacement";
        };
      }) [file]));
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
      == []
      && audit (rv.keyAwareMap {
        type = lib.types.str;
        secretContainer = true;
      })
      == []
      && succeeds (evaluate (rv.keyAwareMap {type = lib.types.str;}) [{alice = "literal-secret";}]));
    runtime-values-secret-context-shapes = mkTest "runtime-values-secret-context-shapes" (let
      leaf = lib.mkOption {type = lib.types.str;};
      declarations = [
        {credentials.alice = leaf;}
        {credentials = lib.mkOption {type = lib.types.submodule {options.alice = leaf;};};}
        {credentials = lib.mkOption {type = lib.types.attrsOf lib.types.str;};}
        {credentials = lib.mkOption {type = lib.types.submodule {freeformType = lib.types.attrsOf lib.types.str;};};}
      ];
      evaluateTree = options: value:
        (lib.evalModules {
          modules = [
            {
              inherit options;
              config.credentials.alice = value;
            }
          ];
        }).config.credentials.alice;
      check = options: let
        evaluated = (lib.evalModules {modules = [{inherit options;}];}).options;
        lifted = rv.liftOptions {inherit options;};
      in
        !succeeds (evaluateTree lifted "literal")
        && succeeds (evaluateTree lifted file)
        && rv.checkOptions {
          options = evaluated;
          roots = [["credentials"]];
        }
        != [];
      namespace = builtins.head declarations;
      evaluatedNamespace = (lib.evalModules {modules = [{options = namespace;}];}).options;
      prefixed = rv.liftOptions {
        options.child = leaf;
        prefix = ["credentials" "alice"];
      };
      listDeclarations.credentials = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {options.alice = leaf;});
      };
      liftedList = rv.liftOptions {options = listDeclarations;};
      listValue = value:
        (lib.evalModules {
          modules = [
            {
              options = liftedList;
              config.credentials = [{alice = value;}];
            }
          ];
        }).config.credentials;
      prefixedValue = value:
        (lib.evalModules {
          modules = [
            {
              options = prefixed;
              config.child = value;
            }
          ];
        }).config.child;
    in
      lib.all check declarations
      && rv.checkOptions {
        options = evaluatedNamespace;
        roots = [["credentials" "alice"]];
      }
      == ["credentials.alice"]
      && !succeeds (prefixedValue "literal")
      && succeeds (prefixedValue file)
      && !succeeds (listValue "literal")
      && succeeds (listValue file)
      && rv.checkOptions {
        inherit (lib.evalModules {modules = [{options = listDeclarations;}];}) options;
        roots = [["credentials"]];
      }
      != []);
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
    runtime-values-classifier-boundary = mkTest "runtime-values-classifier-boundary" (let
      cases = {
        secret = [
          "access_tokens"
          "auth_tokens"
          "client_secret_file"
          "private_key_material"
          "secret_tokens"
          "token"
          "tokens"
        ];
        sensitive = [
          "apiKeyHelper"
          "api_key_file"
          "max_tokens"
          "token_env"
          "token_file"
          "token_limit"
          "token_path"
          "token_var"
          "tokenEnvVar"
          "tokenizer"
        ];
      };
      mapType = rv.keyAwareMap {type = lib.types.str;};
      verify = expected: name:
        rv.classify {path = [name];}
        == expected
        && succeeds (evaluate mapType [
          (builtins.listToAttrs [
            {
              inherit name;
              value = file;
            }
          ])
        ])
        && (succeeds (evaluate mapType [
          (builtins.listToAttrs [
            {
              inherit name;
              value = "literal";
            }
          ])
        ]))
        == (expected == "sensitive");
      credentialNeighbors = lib.concatMap (name: ["secret_${name}" "${name}_secret"]) cases.sensitive;
    in
      lib.all (verify "secret") cases.secret
      && lib.all (verify "secret") credentialNeighbors
      && lib.all (verify "sensitive") cases.sensitive
      && rv.classify {
        path = ["max_tokens"];
        hints.secret = true;
      }
      == "secret"
      && rv.classify {
        path = ["token_file"];
        secretContainer = true;
      }
      == "secret");
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
        value = evaluate secret [file];
        output = "argv";
      })
      && succeeds (rv.assignment {
        inherit pkgs;
        variable = "HOST";
        value = file;
        output = "argv";
      })
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
      namespace = rv.liftOptions {
        options.credentials.token = lib.mkOption {type = lib.types.str;};
      };
      evaluateNamespace = token:
        (lib.evalModules {
          modules = [
            {
              options = namespace;
              config.credentials = {inherit token;};
            }
          ];
        }).config.credentials.token;
    in
      succeeds (evaluateOptions {
        nested.token = file;
        env.HOST = file;
      })
      && !succeeds (evaluateOptions {
        nested.token = "literal";
        env = {};
      })
      && !succeeds (evaluateNamespace "literal")
      && succeeds (evaluateNamespace file));
  };
}
