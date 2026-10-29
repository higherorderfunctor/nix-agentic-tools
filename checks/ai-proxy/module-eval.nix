# `ai.proxy` core contracts (lib/ai/proxy): selection validation and
# resolution, the field-wise copy-down, and the instance registry.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiBase claudeSettings evalDevenv evalDevenvModules evalHm evalHmModules mkTest;

  inherit (import ../../lib/extracted/render.nix {inherit lib;}) fill;
  redact = import ../../lib/redact {inherit lib;};
  # The key a selected CLIProxyAPI instance accepts: one reference on both
  # sides, in the instance's access list and in the selection.
  instanceKey = redact.file "/run/secrets/ai-proxy-key";
  instance = port: {
    inherit port;
    clientKeys.main = {
      key = instanceKey;
      routes = [{credential = "login";}];
    };
    credentials.login.oauth = {
      account = redact.file "/run/secrets/cpa-login-email";
      vendor = "claude";
    };
  };
  instances.cliproxyapi.instances = {
    alt = instance 8403;
    main = instance 8400;
    off = {
      enable = false;
      port = 8401;
    };
  };

  failedMessages = result: map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion) result.config.assertions);
  failsWith = fragments: result:
    builtins.any (message: lib.all (fragment: lib.hasInfix fragment message) fragments) (failedMessages result);

  # A runtime that consumes the pool, so the per-runtime override and the
  # resolved endpoint are exercised without any real integration.
  record = aiBase.app.mkRuntime {
    inherit pkgs;
    name = "testapp";
    surfaceSupport.proxy = {};
  };
  evalAppWith = modules: backend: config:
    (
      if backend == "hm"
      then evalHmModules
      else evalDevenvModules
    ) ([
        (aiBase.app.${backend + "Transform"} record)
        {inherit config;}
      ]
      ++ modules);
  evalApp = evalAppWith [];
  # A second proxy owner with a backend no runtime lowers and a clientless
  # instance.
  secondOwner = {
    imports = [
      (import ../../packages/ai-module/lib/runtime.nix {
        enabled = true;
        name = "relay";
      })
    ];
    ai = {
      internal.proxyInstances.second = {
        backend = "relay";
        url = "http://127.0.0.1:8500";
      };
      relay.claims.proxy-instance = ["second"];
    };
  };

  clientKey = name: redact.file "/run/secrets/cpa-${name}-key";
  apiKey = {
    apis = {
      anthropic.base-url = "https://api.z.ai/api/anthropic";
      responses.base-url = "https://api.z.ai/api/v1";
    };
    key = redact.file "/run/secrets/zai-key";
    models = ["glm-5.3" "glm-5.3-flash"];
  };
  oauth = name: {
    oauth = {
      vendor = "claude";
      account = redact.file "/run/secrets/cpa-${name}-account";
    };
  };
  credentials = {
    chat.apiKey = apiKey // {apis = {chat.base-url = "https://chat.example/v1";};};
    personal = oauth "personal";
    work = oauth "work";
    zai = {inherit apiKey;};
  };
  client = name: routes: {
    key = clientKey name;
    inherit routes;
  };
  route = credential: {inherit credential;};
  fixture = {
    claude = {
      enable = true;
      proxy = {
        instance = "clients";
        clientKey = "personal";
      };
    };
    cliproxyapi.instances.clients = {
      port = 8402;
      inherit credentials;
      clientKeys = {
        personal = client "personal" [
          (route "personal")
          {
            credential = "zai";
            api = "anthropic";
          }
        ];
        work = client "work" [(route "work")];
      };
    };
    codex = {
      enable = true;
      proxy = {
        instance = "clients";
        clientKey = "work";
      };
    };
  };
  evaluate = backend: ai: evalApp backend {ai = lib.recursiveUpdate fixture ai;};
  rendered = result: let
    inherit (result.config.ai.services.cliproxyapi-clients.files.config) content secrets;
  in
    builtins.fromJSON (fill secrets content);
  oauthRule = name: {
    provider = "claude";
    kind = "oauth";
    accounts = [credentials.${name}.oauth.account];
  };
  refused = backend: fragment: ai: lib.any (lib.hasInfix fragment) (failedMessages (evaluate backend ai));
  instanceChange = change: {cliproxyapi.instances.clients = change;};
in {
  checks = {
    module-ai-proxy-z-ai-credential = mkTest "ai-proxy-z-ai-credential" (let
      facts = import ../../lib/extracted/facts.nix {inherit lib;};
      vendor = facts.get (facts.load {dir = ../../packages/cliproxyapi/extracted;}).aggregate "zAi";
      problems = lib.concatMap (backend: let
        ai = instanceChange {
          credentials.zai = lib.mkForce {
            vendor = "z-ai";
            apiKey.key = apiKey.key;
          };
          clientKeys.work.routes = lib.mkForce [
            {
              credential = "zai";
              api = "chat";
            }
          ];
        };
        result = evaluate backend ai;
        settings = rendered result;
        shimOverride = overrides:
          evaluate backend (lib.recursiveUpdate ai (instanceChange {
            credentials.zai = lib.mkForce {
              vendor = "z-ai";
              apiKey = {inherit (apiKey) key;} // overrides;
            };
          }));
        customized = shimOverride {toolAliases.ToolSearch = "SearchProxy";};
        disabled = shimOverride {
          codexShellArgCleanup = false;
          toolAliases = {};
        };
        plain = rendered (evaluate backend {});
        overridden = evaluate backend (lib.recursiveUpdate ai (instanceChange {
          clientKeys.personal.routes = lib.mkForce [(route "personal")];
          credentials.zai = lib.mkForce {
            vendor = "z-ai";
            apiKey = {
              apis = {
                anthropic = null;
                chat.base-url = "https://chat.example/v4";
              };
              key = clientKey "override";
              models = ["custom-model"];
            };
          };
        }));
        block = family: lib.findFirst (entry: entry.name == "zai") null settings.api-keys.${family};
        checks = {
          "accepted" = failedMessages result == [];
          "both API blocks" = (block "claude").base-url == vendor.apis.anthropic.base-url && (block "openai-compatibility").base-url == vendor.apis.chat.base-url;
          "catalog defaults" = (block "claude").models == map (name: {inherit name;}) vendor.models && (block "openai-compatibility").models == (block "claude").models;
          "chat client route" =
            (lib.last settings.access.key-allowlist).credentials
            == [
              {
                base-urls = [vendor.apis.chat.base-url];
                kind = "apikey";
                provider = "openai-compatible-zai";
              }
            ];
          "custom alias overrides default" =
            failedMessages customized
            == []
            && (lib.findFirst (entry: entry.name == "zai") null (rendered customized).api-keys.claude).tool-aliases == {ToolSearch = "SearchProxy";};
          "empty map and false override defaults" =
            failedMessages disabled
            == []
            && lib.all (entry: !(entry ? tool-aliases)) (rendered disabled).api-keys.claude
            && lib.all (entry: !(entry ? codex-shell-arg-cleanup)) (rendered disabled).api-keys.openai-compatibility;
          "overrides" =
            failedMessages overridden
            == []
            && overridden.config.ai.cliproxyapi.instances.clients.credentials.zai.apiKey
            == {
              apis = {
                anthropic = null;
                chat.base-url = "https://chat.example/v4";
                responses = null;
              };
              codexShellArgCleanup = true;
              key = clientKey "override";
              models = ["custom-model"];
              priority = null;
              toolAliases.ToolSearch = "ToolSearch_";
            };
          "picker catalog retained" =
            result.config.ai.claude.normalized.proxy.credentials
            == [
              {
                name = "personal";
                models = [];
              }
              {
                name = "zai";
                inherit (vendor) models;
              }
            ];
          "plain shims omitted" =
            lib.all (entry: !(entry ? tool-aliases)) plain.api-keys.claude
            && lib.all (entry: !(entry ? codex-shell-arg-cleanup)) plain.api-keys.openai-compatibility;
          "shims rendered" = (block "claude").tool-aliases == {ToolSearch = "ToolSearch_";} && (block "openai-compatibility").codex-shell-arg-cleanup;
          "tier mapping retained as measured data" = builtins.attrNames vendor.claudeModels == ["haiku" "opus" "sonnet"] && lib.all (model: lib.elem model vendor.models) (builtins.attrValues vendor.claudeModels);
        };
      in
        map (name: "${backend}: ${name}") (builtins.attrNames (lib.filterAttrs (_: ok: !ok) checks))) ["hm" "devenv"];
    in
      if problems == []
      then true
      else throw (lib.concatStringsSep "\n" problems));
    module-ai-proxy-instance-clients = mkTest "ai-proxy-instance-clients" (let
      problems = lib.concatMap (backend: let
        result = evaluate backend {};
        settings = rendered result;
        rules = map (entry: entry.credentials) settings.access.key-allowlist;
        rows =
          map (model: {
            inherit model;
            description = "zai through CLIProxyAPI";
          })
          apiKey.models;
        byUrl = evaluate backend {
          claude.proxy = {
            instance = null;
            clientKey = null;
            key = clientKey "external";
            url = "http://127.0.0.1:8317";
          };
          codex.enable = false;
          cliproxyapi.instances.clients.clientKeys = lib.mkForce {};
        };
        claudeLauncher = lib.findFirst (package: package.name or "" == "claude-code-proxy") null (result.config.home.packages or result.config.packages);
        pickerFile = lib.findFirst lib.isList null (builtins.split "--settings ([^ ']+)" (claudeLauncher.buildCommand or ""));
        chatOnly = evaluate backend (instanceChange {clientKeys.work.routes = lib.mkForce [(route "chat")];});
        rejectsType = ai: !(builtins.tryEval (builtins.deepSeq (let instance = (evaluate backend ai).config.ai.cliproxyapi.instances.clients; in {inherit (instance) clientKeys credentials;}) true)).success;
        priorityBlocks = priority:
          lib.concatLists (builtins.attrValues
            (rendered (evaluate backend (instanceChange {
              credentials = lib.mapAttrs (_: _: {apiKey = {inherit priority;};}) (lib.filterAttrs (_: credential: credential ? apiKey) credentials);
            }))).api-keys);
        checks = {
          "API-key priority on every served API" = lib.all (priority: map (block: block.priority) (priorityBlocks priority) == [priority priority priority]) [(-1) 0 3];
          "unset API-key priority omitted" = lib.all (block: !(block ? priority)) (lib.concatLists (builtins.attrValues settings.api-keys));
          "null API-key priority omitted" = lib.all (block: !(block ? priority)) (priorityBlocks null);
          "OAuth rejects priority" = rejectsType (instanceChange {credentials.work.oauth.priority = -1;});
          "fixture accepted" = failedMessages result == [];
          "named keys" = settings.access.api-keys == map clientKey ["personal" "work"];
          "OAuth exact accounts, API exact URL, route order" =
            rules
            == [
              [
                (oauthRule "personal")
                {
                  base-urls = [apiKey.apis.anthropic.base-url];
                  kind = "apikey";
                  provider = "claude";
                }
              ]
              [(oauthRule "work")]
            ];
          "same vendor OAuth remains separate" = (lib.head (lib.head rules)).accounts != (lib.head (lib.last rules)).accounts;
          "API-key blocks" =
            settings.api-keys.claude
            == [
              {
                name = "zai";
                base-url = apiKey.apis.anthropic.base-url;
                keys = [{api-key = apiKey.key;}];
                models = map (name: {inherit name;}) apiKey.models;
              }
            ];
          "Responses cloaking disabled" =
            (lib.head settings.api-keys.codex).keys
            == [
              {
                api-key = apiKey.key;
                disable-codex-cloaking = true;
              }
            ];
          "key derived from client" = result.config.ai.claude.normalized.proxy.key == clientKey "personal" && result.config.ai.codex.normalized.proxy.key == clientKey "work";
          "models derive from client routes" =
            result.config.ai.claude.normalized.proxy.credentials
            == [
              {
                name = "personal";
                models = [];
              }
              {
                name = "zai";
                inherit (apiKey) models;
              }
            ];
          "Claude user picker" = backend != "hm" || (claudeSettings result).modelPicker.options == rows;
          "Claude project has no picker" = backend == "hm" || !((claudeSettings result) ? modelPicker);
          "Claude devenv picker follows routes" = backend == "hm" || (pickerFile != null && builtins.fromJSON (builtins.readFile (lib.head pickerFile)) == {modelPicker.options = rows;});
          "client key hand-written access refused" = refused backend "lists ai.cliproxyapi.instances.clients.clientKeys.personal.key by hand" (instanceChange {settings.access.api-keys = [(clientKey "personal")];});
          "client key hand-written rule refused" = refused backend "hand-written entry for ai.cliproxyapi.instances.clients.clientKeys.personal.key" (instanceChange {
            settings.access.key-allowlist = [
              {
                api-key = clientKey "personal";
                credentials = [(oauthRule "work")];
              }
            ];
          });
          "Codex has no credential profiles" = !(result.config.ai.codex.files ? ".codex/zai.config.toml");
          "chat-only choice for Codex" =
            (lib.last (rendered chatOnly).access.key-allowlist).credentials
            == [
              {
                kind = "apikey";
                provider = "openai-compatible-chat";
                base-urls = ["https://chat.example/v1"];
              }
            ];
          "external adds no keys or rules" = !((rendered byUrl) ? access) && byUrl.config.ai.claude.normalized.proxy.key == clientKey "external";
          "secret references stay out of config" = !(lib.hasInfix "_redact" result.config.ai.services.cliproxyapi-clients.files.config.content);
          "unknown credential" = refused backend "unknown upstream credential `missing`" (instanceChange {clientKeys.work.routes = lib.mkForce [(route "missing")];});
          "unknown client key" = refused backend "clientKey names `missing`" {claude.proxy.clientKey = "missing";};
          "instance needs client key" = refused backend "instance needs `clientKey`" {claude.proxy.clientKey = null;};
          "instance refuses direct key" = refused backend "Instance selections use `clientKey`" {claude.proxy.key = clientKey "direct";};
          "ambiguous API needs choice" = refused backend "needs api because it does not serve exactly one API" (instanceChange {clientKeys.work.routes = lib.mkForce [(route "zai")];});
          "unserved API" = refused backend "does not serve API `chat`" (instanceChange {
            clientKeys.work.routes = lib.mkForce [
              {
                credential = "zai";
                api = "chat";
              }
            ];
          });
          "OAuth rejects API" = refused backend "OAuth credential `work` does not select an API" (instanceChange {
            clientKeys.work.routes = lib.mkForce [
              {
                credential = "work";
                api = "anthropic";
              }
            ];
          });
          "neither credential kind" = refused backend "credentials.empty: declare exactly one" (instanceChange {credentials.empty = {};});
          "both credential kinds" = refused backend "credentials.personal: declare exactly one" (instanceChange {credentials.personal = {inherit apiKey;};});
          "alias duplicate targets" = refused backend "tool-aliases requires" (instanceChange {
            credentials.zai.apiKey.toolAliases = {
              A = "Z";
              B = "Z";
            };
          });
          "alias source collision" = refused backend "tool-aliases requires" (instanceChange {
            credentials.zai.apiKey.toolAliases = {
              A = "B";
              B = "C";
            };
          });
          "alias source too long" = refused backend "tool-aliases requires" (instanceChange {credentials.zai.apiKey.toolAliases.${lib.concatStrings (lib.replicate 65 "x")} = "A";});
          "alias target too long" = refused backend "tool-aliases requires" (instanceChange {credentials.zai.apiKey.toolAliases.A = lib.concatStrings (lib.replicate 65 "x");});
          "raw alias collision" = refused backend "tool-aliases requires" (instanceChange {
            settings.api-keys.claude = [
              {
                tool-aliases = {
                  A = "Z";
                  B = "Z";
                };
              }
            ];
          });
          "raw key alias collision" = refused backend "tool-aliases requires" (instanceChange {
            settings.api-keys.claude = [
              {
                keys = [
                  {
                    tool-aliases = {
                      A = "Z";
                      B = "Z";
                    };
                  }
                ];
              }
            ];
          });
          "shared URL" = refused backend "also the base URL of another" (instanceChange {credentials.duplicate.apiKey = apiKey;});
          "shared raw URL" = refused backend "also the base URL of another" (instanceChange {
            settings.api-keys.claude = [
              {
                base-url = apiKey.apis.anthropic.base-url;
                keys = [{api-key = clientKey "raw";}];
              }
            ];
          });
          "raw URL whitespace" = refused backend "starts or ends with a character other than printable ASCII" (instanceChange {
            settings.api-keys.claude = [
              {
                base-url = " https://raw.example";
                keys = [{api-key = clientKey "raw";}];
              }
            ];
          });
          "empty account restriction" = refused backend "accounts merged to an empty list" (instanceChange {
            settings.access.key-allowlist = [
              {
                api-key = clientKey "raw";
                credentials = [
                  {
                    accounts = [];
                    kind = "oauth";
                    provider = "claude";
                  }
                ];
              }
            ];
          });
          "null account restriction" = refused backend "accounts contains null" (instanceChange {
            settings.access.key-allowlist = [
              {
                api-key = clientKey "raw";
                credentials = [
                  {
                    accounts = [null];
                    kind = "oauth";
                    provider = "claude";
                  }
                ];
              }
            ];
          });
          "literal OAuth account" = rejectsType (instanceChange {credentials.personal.oauth.account = lib.mkForce "secret";});
          "required OAuth account" = rejectsType (instanceChange {credentials.personal = lib.mkForce {oauth.vendor = "claude";};});
          "OAuth account placeholder" = let
            file = result.config.ai.services.cliproxyapi-clients.files.config;
            variable = "CLIPROXYAPI_ACCESS_KEY_ALLOWLIST_0_CREDENTIALS_0_ACCOUNTS_0";
          in
            file.secrets.${variable}
            == credentials.personal.oauth.account
            && lib.hasInfix ("{$" + variable + "}") file.content
            && !(lib.hasInfix "/run/secrets/cpa-personal-account" file.content);
          "literal client key" = rejectsType (instanceChange {clientKeys.personal.key = lib.mkForce "secret";});
          "literal upstream credential" = rejectsType (instanceChange {credentials.zai.apiKey.key = lib.mkForce "secret";});
        };
      in
        lib.mapAttrsToList (name: _: "${backend}: ${name}") (lib.filterAttrs (_: holds: !holds) checks)) ["devenv" "hm"];
    in
      lib.assertMsg (problems == []) (lib.concatStringsSep "; " problems));

    # The authentication key requires a redact reference at both scopes;
    # cleartext and the retired credential branches cannot enter normalization.
    module-ai-proxy-redacted-key = mkTest "ai-proxy-redacted-key" (
      lib.all (backend: let
        rejected = config:
          !(builtins.tryEval (builtins.deepSeq (evalApp backend config).config.ai.testapp.normalized.proxy true)).success;
        invalid = ["literal-client-key" {file = "/run/secrets/key";} {_redact.file = "${builtins.storeDir}/key";}];
        url = "http://127.0.0.1:8317";
      in
        lib.all (key:
          rejected {ai.proxy = {inherit key url;};}
          && rejected {ai.testapp.proxy = {inherit key url;};})
        invalid)
      ["devenv" "hm"]
    );

    # A key without a url and a url without a key each fail with the option
    # path; a valid `url` form passes on both backends. A url carrying a path
    # fails, since every runtime appends its own.
    module-ai-proxy-root-selection-validation = mkTest "ai-proxy-root-selection-validation" (
      failsWith ["ai.proxy.url needs `key`"] (evalHm {ai.proxy.url = "http://127.0.0.1:8317";})
      && failsWith ["ai.proxy.key is set without `url`"] (evalHm {ai.proxy.key = redact.file "/run/secrets/ai-proxy-key";})
      && failsWith ["ai.proxy.url must be the proxy origin only"] (evalHm {
        ai.proxy = {
          key = redact.file "/run/secrets/ai-proxy-key";
          url = "http://127.0.0.1:8317/v1";
        };
      })
      && failedMessages (evalHm {
        ai.proxy = {
          key = redact.file "/run/secrets/ai-proxy-key";
          url = "http://[::1]:8317";
        };
      })
      == []
      && failedMessages (evalDevenv {
        ai.proxy = {
          key = redact.command "${pkgs.hello}/bin/hello";
          url = "http://localhost:8317";
        };
      })
      == []
      # An Instance selection requires a named client key and refuses a URL
      # alongside it, a missing Instance or a disabled Instance.
      && lib.all (evaluate: let
        select = proxy: evaluate {ai = instances // {inherit proxy;};};
      in
        failedMessages (select {
          instance = "main";
          clientKey = "main";
        })
        == []
        && failsWith ["ai.proxy.url and ai.proxy.instance both select a proxy"] (select {
          instance = "main";
          clientKey = "main";
          url = "http://127.0.0.1:8317";
        })
        && failsWith ["ai.proxy.instance names `missing`, which no proxy owner registers; registered instances: alt, main, off."] (select {
          instance = "missing";
          clientKey = "main";
        })
        && failsWith ["ai.proxy.instance names `ai.cliproxyapi.instances.off`, which is disabled."] (select {
          instance = "off";
          clientKey = "main";
        })) [evalDevenv evalHm]
    );

    # Root fields copy down at default priority: a runtime value wins field by
    # field, on both backends; a runtime selecting the other form drops the
    # root's fields of that form, in both directions; `instance = null` opts
    # a runtime out of an inherited selection without tripping on the client
    # key it leaves behind; a runtime's own invalid selection fails with its own option
    # path, even while the runtime is disabled. A url with a path set on the
    # normalized option directly is refused too.
    module-ai-proxy-runtime-override = mkTest "ai-proxy-runtime-override" (
      lib.all (backend: let
        # The endpoint alone; module-ai-proxy-instance-clients covers named credentials.
        resolved = config: let
          proxy = (evalApp backend config).config.ai.testapp.normalized.proxy;
        in
          if proxy == null
          then null
          else removeAttrs proxy ["backend" "credentials"];
        root = {
          key = redact.file "/run/secrets/ai-proxy-key";
          url = "http://127.0.0.1:8317";
        };
        work = {
          key = redact.concat ["Bearer " (redact.command "${pkgs.hello}/bin/hello")];
          url = "http://127.0.0.1:8318";
        };
        mainSelection = {
          instance = "main";
          clientKey = "main";
        };
        withInstances = ai: {ai = instances // ai;};
        keyOnly = {
          ai = {
            proxy = root;
            testapp.proxy.key = work.key;
          };
        };
        switchedToInstance = withInstances {
          proxy = root;
          testapp.proxy = mainSelection;
        };
        switchedToUrl = withInstances {
          proxy = mainSelection;
          testapp.proxy = work;
        };
        optedOut = withInstances {
          proxy = mainSelection;
          testapp.proxy.instance = null;
        };
      in
        resolved {}
        == null
        && resolved {ai.proxy = root;} == root
        && (evalApp backend {ai.proxy = root;}).config.ai.testapp.normalized.proxy.backend == "cliproxyapi"
        && resolved {
          ai = {
            proxy = root;
            testapp.proxy = work;
          };
        }
        == work
        && resolved {ai.testapp.proxy = work;} == work
        && resolved keyOnly == root // {inherit (work) key;}
        && failedMessages (evalApp backend keyOnly) == []
        # An instance resolves to its loopback origin at either scope; a
        # runtime instance replaces the root one.
        && resolved (withInstances {proxy = mainSelection;})
        == {
          key = instanceKey;
          url = "http://127.0.0.1:8400";
        }
        && resolved (withInstances {
          proxy = mainSelection;
          testapp.proxy.instance = "alt";
        })
        == {
          key = instanceKey;
          url = "http://127.0.0.1:8403";
        }
        # Switching forms clears nothing by hand: the root's url and key
        # drop for a runtime instance, its instance and clientKey for a
        # runtime url; a runtime setting both forms itself is still refused.
        && resolved switchedToInstance
        == {
          key = instanceKey;
          url = "http://127.0.0.1:8400";
        }
        && failedMessages (evalApp backend switchedToInstance) == []
        && resolved switchedToUrl == work
        && failedMessages (evalApp backend switchedToUrl) == []
        && failsWith ["ai.testapp.proxy.url and ai.testapp.proxy.instance both select a proxy"] (evalApp backend (withInstances {
          proxy = root;
          testapp.proxy = mainSelection // root;
        }))
        && resolved optedOut == null
        && failedMessages (evalApp backend optedOut) == []
        && failsWith ["ai.testapp.proxy.instance names `missing`, which no proxy owner registers"] (evalApp backend (withInstances {
          proxy = mainSelection;
          testapp.proxy.instance = "missing";
        }))
        && failsWith ["ai.testapp.proxy.key is set without `url`"] (evalApp backend {ai.testapp.proxy.key = work.key;})
        && failsWith ["ai.testapp.proxy.url needs `key`"] (evalApp backend {
          ai.testapp.proxy.url = "http://127.0.0.1:8318";
        })
        && !(builtins.tryEval (builtins.deepSeq (resolved {
            ai.testapp.normalized.proxy = lib.mkForce (root
              // {
                backend = "cliproxyapi";
                url = "http://127.0.0.1:8317/v1";
              });
          })
          true)).success)
      ["devenv" "hm"]
    );

    # Owners merge instances into one registry: a second owner's clientless
    # instance resolves with its own backend from `instance` alone and refuses
    # a clientKey, a runtime switching to it from a CLIProxyAPI root drops the
    # root's clientKey, a name two owners register fails through `ai.claims`, and
    # a runtime without a lowering for the selected backend fails evaluation.
    # Given a test-only Claude lowering, that backend gets only what its
    # lowering sets: no CLIProxyAPI settings and no launcher flags.
    module-ai-proxy-registry = mkTest "ai-proxy-registry" (
      lib.all (backend: let
        evaluate = evalAppWith [secondOwner] backend;
        second.instance = "second";
        withClientKey = evaluate {ai.proxy = second // {clientKey = "main";};};
        switched = evaluate {
          ai =
            instances
            // {
              proxy = {
                clientKey = "main";
                instance = "main";
              };
              testapp.proxy = second;
            };
        };
        resolvedProxy = (evaluate {ai.proxy = second;}).config.ai.testapp.normalized.proxy;
        claudeProxy = (import ../../packages/claude-code/lib/proxy.nix {inherit lib pkgs;}).withLowerings {
          relay = _backend: {url, ...}: {settings.env.HTTPS_PROXY = url;};
        };
        relaySettings =
          (lib.evalModules {
            modules = [
              {
                options.ai.claude.native.settings = lib.mkOption {
                  type = lib.types.anything;
                  default = {};
                };
              }
              {config = claudeProxy.config {inherit backend resolvedProxy;};}
            ];
          }).config.ai.claude.native.settings;
        claude =
          (evalAppWith [secondOwner] backend {
            ai = {
              claude.enable = true;
              proxy = second;
            };
          }).config;
      in
        resolvedProxy
        == {
          backend = "relay";
          url = "http://127.0.0.1:8500";
        }
        && failedMessages (evaluate {ai.proxy = second;}) == []
        && failsWith ["ai.proxy.clientKey is set, but `ai.relay.instances.second` declares no clients."] withClientKey
        && withClientKey.config.ai.testapp.normalized.proxy == null
        && switched.config.ai.testapp.normalized.proxy == resolvedProxy
        && failedMessages switched == []
        && relaySettings == {env.HTTPS_PROXY = "http://127.0.0.1:8500";}
        && claudeProxy.launcherFlags {inherit backend resolvedProxy;} == []
        && failsWith ["ai.claims.proxy-instance.main: claimed by cliproxyapi and relay"] (evaluate {ai = instances // {relay.claims.proxy-instance = ["main"];};})
        && !(builtins.tryEval (builtins.deepSeq claude.ai.claude.native.settings true)).success)
      ["devenv" "hm"]
    );
  };
}
