# `ai.settings.inference` core contracts (lib/ai/inference): selection validation and
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
  instanceKey = redact.file "/run/secrets/ai-inference-key";
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
    surfaceSupport.settings.fields = ["inference"];
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
      internal.inferenceInstances.second = {
        backend = "relay";
        url = "http://127.0.0.1:8500";
      };
      relay.claims.inference-instance = ["second"];
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
      settings.inference = {
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
      settings.inference = {
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
    module-ai-inference-z-ai-credential = mkTest "ai-inference-z-ai-credential" (let
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
                chat = {
                  base-url = "https://chat.example/v4";
                  models = null;
                };
                responses = null;
              };
              codexShellArgCleanup = true;
              key = clientKey "override";
              models = ["custom-model"];
              priority = null;
              toolAliases.ToolSearch = "ToolSearch_";
            };
          "picker catalog retained" =
            result.config.ai.claude.normalized.settings.inference.credentials
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
    module-ai-inference-opencode-go-credential = mkTest "ai-inference-opencode-go-credential" (let
      facts = import ../../lib/extracted/facts.nix {inherit lib;};
      catalog = (facts.get (facts.load {dir = ../../packages/cliproxyapi/extracted;}).aggregate "opencodeGo").models;
      vendor = (import ../../packages/cliproxyapi/lib/providers.nix {inherit lib;}).vendors.opencode-go;
      urls = {
        anthropic = "https://opencode.ai/inference/go/anthropic";
        chat = "https://opencode.ai/inference/go/openai/v1";
        responses = "https://opencode.ai/inference/go/openai/v1";
      };
      problems = lib.concatMap (backend: let
        go = apiKey:
          evaluate backend (instanceChange {
            credentials.go = {
              vendor = "opencode-go";
              apiKey = {key = clientKey "opencode-go";} // apiKey;
            };
            clientKeys = {
              personal.routes = lib.mkForce [
                {
                  api = "anthropic";
                  credential = "go";
                }
              ];
              work.routes = lib.mkForce [
                {
                  api = "chat";
                  credential = "go";
                }
              ];
            };
          });
        result = go {};
        blocksOf = evaluated: family: lib.filter (entry: entry.name == "go") (rendered evaluated).api-keys.${family};
        modelsIn = evaluated: family: lib.concatMap (block: map (model: model.name) block.models) (blocksOf evaluated family);
        block = family: lib.head (blocksOf result family);
        overridden = go {
          apis = {
            chat = {
              base-url = "https://go.example/v1";
              models = ["kimi-k3"];
            };
            responses = null;
          };
        };
        refusedModel = model: failsWith ["credentials.go: vendor `opencode-go` refuses models `${model}`" "Claude OAuth, z.ai and Codex OAuth credentials serve them"];
        allPlaced = lib.concatMap (modelsIn result) ["claude" "codex" "openai-compatibility"];
        # CPA trims model names, so a padded Claude id is refused at the type.
        rejectsPadded = model:
          !(builtins.tryEval (builtins.deepSeq
            (go {
              apis.anthropic = {
                base-url = urls.anthropic;
                models = [model];
              };
            }).config.ai.cliproxyapi.instances.clients.credentials
            true)).success;
        checks = {
          "accepted" = failedMessages result == [];
          "per-API base URLs" = (block "claude").base-url == urls.anthropic && (block "openai-compatibility").base-url == urls.chat && (block "codex").base-url == urls.responses;
          "native placement" =
            lib.all (model: lib.elem model (modelsIn result "claude")) ["minimax-m3" "qwen3.8-max"]
            && lib.all (model: lib.elem model (modelsIn result "openai-compatibility")) ["deepseek-v4-pro" "kimi-k3"]
            && lib.all (model: lib.elem model (modelsIn result "codex")) ["grok-4.7" "muse-spark-1.3-contributor"]
            && !(lib.elem "kimi-k3" (modelsIn result "claude" ++ modelsIn result "codex"));
          "generate-content on chat" = catalog.gemini-4-argon.api ? generate-content && lib.elem "gemini-4-argon" (modelsIn result "openai-compatibility");
          "every other catalog model placed once" = lib.sort lib.lessThan allPlaced == builtins.filter (id: !(vendor.refuses id)) (builtins.attrNames catalog);
          "defaults leave refused families out" =
            lib.all (id: catalog ? ${id} && vendor.refuses id && !(lib.elem id allPlaced)) ["claude-haiku-5-5" "glm-5.3" "gpt-6-luna"]
            && !(lib.any (id: lib.any (prefix: lib.hasPrefix prefix id) ["claude-" "glm-" "gpt-"]) allPlaced);
          "Claude added to an API refused" = refusedModel "claude-haiku-5-5" (go {
            apis.anthropic = {
              base-url = urls.anthropic;
              models = ["claude-haiku-5-5" "qwen3.8-max"];
            };
          });
          "Claude through credential models refused" = refusedModel "claude-haiku-5-5" (go {
            apis.responses = {
              base-url = urls.responses;
              models = null;
            };
            models = ["claude-haiku-5-5"];
          });
          "GLM added to an API refused" = refusedModel "glm-5.3" (go {
            apis.chat = {
              base-url = urls.chat;
              models = ["glm-5.3" "kimi-k3"];
            };
          });
          "GPT added to an API refused" = refusedModel "gpt-6-luna" (go {
            apis.responses = {
              base-url = urls.responses;
              models = ["gpt-6-luna" "grok-4.7"];
            };
          });
          "Claude id with leading space refused" = rejectsPadded " claude-haiku-5-5";
          "Claude id with no-break space refused" = rejectsPadded "claude-haiku-5-5 ";
          "interior Unicode model name accepted" = let
            unicode = go {
              apis.chat = {
                base-url = urls.chat;
                models = ["qwen-中文-v1"];
              };
            };
          in
            failedMessages unicode == [] && modelsIn unicode "openai-compatibility" == ["qwen-中文-v1"];
          "z.ai shims off" = !((block "claude") ? tool-aliases) && !((block "openai-compatibility") ? codex-shell-arg-cleanup);
          "picker lists the routed API's models" =
            result.config.ai.claude.normalized.settings.inference.credentials
            == [
              {
                name = "go";
                inherit (vendor.apis.anthropic) models;
              }
            ];
          "API override" = failedMessages overridden == [] && (lib.head (blocksOf overridden "openai-compatibility")).base-url == "https://go.example/v1" && modelsIn overridden "openai-compatibility" == ["kimi-k3"];
          "API removed" = blocksOf overridden "codex" == [] && (lib.head (blocksOf overridden "claude")).base-url == urls.anthropic;
        };
      in
        map (name: "${backend}: ${name}") (builtins.attrNames (lib.filterAttrs (_: ok: !ok) checks))) ["devenv" "hm"];
    in
      if problems == []
      then true
      else throw (lib.concatStringsSep "\n" problems));
    module-ai-inference-instance-clients = mkTest "ai-inference-instance-clients" (let
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
          claude.settings.inference = {
            instance = null;
            clientKey = null;
            key = clientKey "external";
            url = "http://127.0.0.1:8317";
          };
          codex.enable = false;
          cliproxyapi.instances.clients.clientKeys = lib.mkForce {};
        };
        claudeLauncher = lib.findFirst (package: package.name or "" == "claude-code-inference") null (result.config.home.packages or result.config.packages);
        pickerFile = lib.findFirst lib.isList null (builtins.split "--settings ([^ ']+)" (claudeLauncher.buildCommand or ""));
        chatOnly = evaluate backend (instanceChange {clientKeys.work.routes = lib.mkForce [(route "chat")];});
        rejectsType = ai: !(builtins.tryEval (builtins.deepSeq (let instance = (evaluate backend ai).config.ai.cliproxyapi.instances.clients; in {inherit (instance) clientKeys credentials;}) true)).success;
        # One credential whose APIs serve different models; the
        # personal client routes to its chat API.
        split = apiKeyChange:
          evaluate backend (instanceChange {
            credentials.split.apiKey =
              lib.recursiveUpdate {
                apis = {
                  anthropic = {
                    base-url = "https://split.example/anthropic";
                    models = ["split-anthropic"];
                  };
                  chat = {
                    base-url = "https://split.example/v1";
                    models = ["split-chat"];
                  };
                };
                key = clientKey "split";
              }
              apiKeyChange;
            clientKeys.personal.routes = lib.mkForce [
              {
                api = "chat";
                credential = "split";
              }
            ];
          });
        splitResult = split {};
        splitBlock = family: lib.findFirst (entry: entry.name == "split") null (rendered splitResult).api-keys.${family};
        fallback = split {
          apis.chat.models = null;
          models = ["split-shared"];
        };
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
          "key derived from client" = result.config.ai.claude.normalized.settings.inference.key == clientKey "personal" && result.config.ai.codex.normalized.settings.inference.key == clientKey "work";
          "models derive from client routes" =
            result.config.ai.claude.normalized.settings.inference.credentials
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
          "per-API models accepted" = failedMessages splitResult == [];
          "per-API models replace credential models" = (splitBlock "claude").models == [{name = "split-anthropic";}] && (splitBlock "openai-compatibility").models == [{name = "split-chat";}];
          "API without models falls back to credential models" =
            failedMessages fallback
            == []
            && (lib.findFirst (entry: entry.name == "split") null (rendered fallback).api-keys.openai-compatibility).models
            == [{name = "split-shared";}]
            && (lib.findFirst (entry: entry.name == "split") null (rendered fallback).api-keys.claude).models == [{name = "split-anthropic";}];
          "API without models refused" = refused backend "credentials.split.apiKey serves API `chat` without models" (instanceChange {
            credentials.split.apiKey = {
              apis = {
                anthropic = {
                  base-url = "https://split.example/anthropic";
                  models = ["split-anthropic"];
                };
                chat.base-url = "https://split.example/v1";
              };
              key = clientKey "split";
            };
          });
          "API with emptied models refused" = failsWith ["credentials.split.apiKey serves API `chat` without models"] (split {apis.chat.models = [(lib.mkIf false "split-chat")];});
          "picker lists the routed API's models" =
            splitResult.config.ai.claude.normalized.settings.inference.credentials
            == [
              {
                name = "split";
                models = ["split-chat"];
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
          "external adds no keys or rules" = !((rendered byUrl) ? access) && byUrl.config.ai.claude.normalized.settings.inference.key == clientKey "external";
          "secret references stay out of config" = !(lib.hasInfix "_redact" result.config.ai.services.cliproxyapi-clients.files.config.content);
          "unknown credential" = refused backend "unknown upstream credential `missing`" (instanceChange {clientKeys.work.routes = lib.mkForce [(route "missing")];});
          "unknown client key" = refused backend "clientKey names `missing`" {claude.settings.inference.clientKey = "missing";};
          "instance needs client key" = refused backend "instance needs `clientKey`" {claude.settings.inference.clientKey = null;};
          "instance refuses direct key" = refused backend "Instance selections use `clientKey`" {claude.settings.inference.key = clientKey "direct";};
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
    module-ai-inference-redacted-key = mkTest "ai-inference-redacted-key" (
      lib.all (backend: let
        rejected = config:
          !(builtins.tryEval (builtins.deepSeq (evalApp backend config).config.ai.testapp.normalized.settings.inference true)).success;
        invalid = ["literal-client-key" {file = "/run/secrets/key";} {_redact.file = "${builtins.storeDir}/key";}];
        url = "http://127.0.0.1:8317";
      in
        lib.all (key:
          rejected {ai.settings.inference = {inherit key url;};}
          && rejected {ai.testapp.settings.inference = {inherit key url;};})
        invalid)
      ["devenv" "hm"]
    );

    # A key without a url and a url without a key each fail with the option
    # path; a valid `url` form passes on both backends. A url carrying a path
    # fails, since every runtime appends its own.
    module-ai-inference-root-selection-validation = mkTest "ai-inference-root-selection-validation" (
      failsWith ["ai.settings.inference.url needs `key`"] (evalHm {ai.settings.inference.url = "http://127.0.0.1:8317";})
      && failsWith ["ai.settings.inference.key is set without `url`"] (evalHm {ai.settings.inference.key = redact.file "/run/secrets/ai-inference-key";})
      && failsWith ["ai.settings.inference.url must be the proxy origin only"] (evalHm {
        ai.settings.inference = {
          key = redact.file "/run/secrets/ai-inference-key";
          url = "http://127.0.0.1:8317/v1";
        };
      })
      && failedMessages (evalHm {
        ai.settings.inference = {
          key = redact.file "/run/secrets/ai-inference-key";
          url = "http://[::1]:8317";
        };
      })
      == []
      && failedMessages (evalDevenv {
        ai.settings.inference = {
          key = redact.command "${pkgs.hello}/bin/hello";
          url = "http://localhost:8317";
        };
      })
      == []
      # An Instance selection requires a named client key and refuses a URL
      # alongside it, a missing Instance or a disabled Instance.
      && lib.all (evaluate: let
        select = inference: evaluate {ai = instances // {settings.inference = inference;};};
      in
        failedMessages (select {
          instance = "main";
          clientKey = "main";
        })
        == []
        && failsWith ["ai.settings.inference.url and ai.settings.inference.instance both select a proxy"] (select {
          instance = "main";
          clientKey = "main";
          url = "http://127.0.0.1:8317";
        })
        && failsWith ["ai.settings.inference.instance names `missing`, which no proxy owner registers; registered instances: alt, main, off."] (select {
          instance = "missing";
          clientKey = "main";
        })
        && failsWith ["ai.settings.inference.instance names `ai.cliproxyapi.instances.off`, which is disabled."] (select {
          instance = "off";
          clientKey = "main";
        })) [evalDevenv evalHm]
    );

    # Root fields copy down at default priority: a runtime value wins field by
    # field, on both backends; a runtime selecting the other form drops the
    # root's fields of that form, in both directions; `instance = null` opts
    # a runtime out of an inherited selection without tripping on the client
    # key it leaves behind; an unset root field adds no definition, so a
    # profile's default-priority runtime selection meets no conflict; a
    # runtime's own invalid selection fails with its own option
    # path, even while the runtime is disabled. A url with a path set on the
    # normalized option directly is refused too.
    module-ai-inference-runtime-override = mkTest "ai-inference-runtime-override" (
      lib.all (backend: let
        # The endpoint alone; module-ai-inference-instance-clients covers named credentials.
        resolved = config: let
          inference = (evalApp backend config).config.ai.testapp.normalized.settings.inference;
        in
          if inference == null
          then null
          else removeAttrs inference ["backend" "credentials"];
        root = {
          key = redact.file "/run/secrets/ai-inference-key";
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
            settings.inference = root;
            testapp.settings.inference.key = work.key;
          };
        };
        switchedToInstance = withInstances {
          settings.inference = root;
          testapp.settings.inference = mainSelection;
        };
        switchedToUrl = withInstances {
          settings.inference = mainSelection;
          testapp.settings.inference = work;
        };
        optedOut = withInstances {
          settings.inference = mainSelection;
          testapp.settings.inference.instance = null;
        };
        # A profile module's default-priority runtime selection, with no root
        # selection whose unset fields could conflict with it.
        profileDefault =
          evalAppWith [
            {ai.testapp.settings.inference = lib.mapAttrs (_: lib.mkDefault) mainSelection;}
          ]
          backend
          {ai = instances;};
      in
        resolved {}
        == null
        && resolved {ai.settings.inference = root;} == root
        && (evalApp backend {ai.settings.inference = root;}).config.ai.testapp.normalized.settings.inference.backend == "cliproxyapi"
        && resolved {
          ai = {
            settings.inference = root;
            testapp.settings.inference = work;
          };
        }
        == work
        && resolved {ai.testapp.settings.inference = work;} == work
        && resolved keyOnly == root // {inherit (work) key;}
        && failedMessages (evalApp backend keyOnly) == []
        # An instance resolves to its loopback origin at either scope; a
        # runtime instance replaces the root one.
        && resolved (withInstances {settings.inference = mainSelection;})
        == {
          key = instanceKey;
          url = "http://127.0.0.1:8400";
        }
        && resolved (withInstances {
          settings.inference = mainSelection;
          testapp.settings.inference.instance = "alt";
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
        && failsWith ["ai.testapp.settings.inference.url and ai.testapp.settings.inference.instance both select a proxy"] (evalApp backend (withInstances {
          settings.inference = root;
          testapp.settings.inference = mainSelection // root;
        }))
        && resolved optedOut == null
        && removeAttrs profileDefault.config.ai.testapp.normalized.settings.inference ["backend" "credentials"]
        == {
          key = instanceKey;
          url = "http://127.0.0.1:8400";
        }
        && failedMessages profileDefault == []
        && failedMessages (evalApp backend optedOut) == []
        && failsWith ["ai.testapp.settings.inference.instance names `missing`, which no proxy owner registers"] (evalApp backend (withInstances {
          settings.inference = mainSelection;
          testapp.settings.inference.instance = "missing";
        }))
        && failsWith ["ai.testapp.settings.inference.key is set without `url`"] (evalApp backend {ai.testapp.settings.inference.key = work.key;})
        && failsWith ["ai.testapp.settings.inference.url needs `key`"] (evalApp backend {
          ai.testapp.settings.inference.url = "http://127.0.0.1:8318";
        })
        && !(builtins.tryEval (builtins.deepSeq (resolved {
            ai.testapp.normalized.settings.inference = lib.mkForce (root
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
    # root's clientKey, and a name two owners register fails through
    # `ai.claims`. Claude and Codex, which have no lowering for that backend,
    # refuse it by name and run no CLIProxyAPI lowering. Given a test-only
    # Claude lowering, that backend gets only what its lowering sets: no
    # CLIProxyAPI settings and no launcher flags.
    module-ai-inference-registry = mkTest "ai-inference-registry" (
      lib.all (backend: let
        evaluate = evalAppWith [secondOwner] backend;
        second.instance = "second";
        withClientKey = evaluate {ai.settings.inference = second // {clientKey = "main";};};
        switched = evaluate {
          ai =
            instances
            // {
              settings.inference = {
                clientKey = "main";
                instance = "main";
              };
              testapp.settings.inference = second;
            };
        };
        resolvedInference = (evaluate {ai.settings.inference = second;}).config.ai.testapp.normalized.settings.inference;
        claudeInference = (import ../../packages/claude-code/lib/inference.nix {inherit lib pkgs;}).withLowerings {
          relay = {resolvedInference, ...}: {settings.env.HTTPS_PROXY = resolvedInference.url;};
        };
        codexInference = import ../../packages/chatgpt-codex/lib/inference.nix {
          inherit lib pkgs;
          inlineToml = import ../../packages/chatgpt-codex/lib/inlineToml.nix {inherit lib;};
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
              {config = claudeInference.config {inherit backend resolvedInference;};}
            ];
          }).config.ai.claude.native.settings;
        # Real Claude and Codex modules selecting the second owner's instance.
        runtimes = evalAppWith [secondOwner] backend {
          ai = {
            claude.enable = true;
            codex = {
              enable = true;
              package = lib.mkIf (backend == "devenv") null;
            };
            settings.inference = second;
          };
        };
        unsupported = runtime: "ai.${runtime}.settings.inference selects a `relay` proxy instance, which ${runtime} cannot use; it supports cliproxyapi.";
      in
        resolvedInference
        == {
          backend = "relay";
          url = "http://127.0.0.1:8500";
        }
        && failedMessages (evaluate {ai.settings.inference = second;}) == []
        && failsWith ["ai.settings.inference.clientKey is set, but `ai.relay.instances.second` declares no clients."] withClientKey
        && withClientKey.config.ai.testapp.normalized.settings.inference == null
        && switched.config.ai.testapp.normalized.settings.inference == resolvedInference
        && failedMessages switched == []
        && relaySettings == {env.HTTPS_PROXY = "http://127.0.0.1:8500";}
        && claudeInference.launcherFlags {inherit backend resolvedInference;} == []
        && codexInference.launcherFlags resolvedInference == []
        && failsWith ["ai.claims.inference-instance.main: claimed by cliproxyapi and relay"] (evaluate {ai = instances // {relay.claims.inference-instance = ["main"];};})
        && failsWith [(unsupported "claude")] runtimes
        && failsWith [(unsupported "codex")] runtimes
        && (backend != "devenv" || !(builtins.any (lib.hasPrefix "ai.codex.settings.inference is selected but ai.codex.package is null") runtimes.config.warnings))
        && runtimes.config.ai.claude.native.settings.apiKeyHelper == null
        && !(runtimes.config.ai.claude.native.settings.env ? ANTHROPIC_BASE_URL)
        && !(runtimes.config.ai.codex.native.settings.tui or {} ? model_availability_nux))
      ["devenv" "hm"]
    );
  };
}
