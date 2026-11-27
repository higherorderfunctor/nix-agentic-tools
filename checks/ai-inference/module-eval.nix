# `ai.settings.inference` core contracts (lib/ai/inference): selection validation and
# resolution, the field-wise copy-down, and the instance registry.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiBase checkRows claudeSettings evalDevenv evalDevenvModules evalHm evalHmModules mkTest rejectsChange;

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
    key = redact.file "/run/secrets/zhipuai-key";
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
    zhipuai = {inherit apiKey;};
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
            credential = "zhipuai";
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
    # A command reference's program path carries its store context, which
    # fromJSON refuses; content itself holds only placeholders.
    builtins.fromJSON (builtins.unsafeDiscardStringContext (fill secrets content));
  oauthRule = name: {
    provider = "claude";
    kind = "oauth";
    accounts = [credentials.${name}.oauth.account];
  };
  refused = backend: fragment: ai: lib.any (lib.hasInfix fragment) (failedMessages (evaluate backend ai));
  instanceChange = change: {cliproxyapi.instances.clients = change;};
in {
  checks = {
    # The catalog check owns the rendered inventory. Pin a mixed subset here
    # to catch the runtime grant drifting to the wrong API.
    module-ai-inference-opencode-go-credential = mkTest "ai-inference-opencode-go-credential" (
      lib.all (backend: let
        result = evaluate backend ((instanceChange {
            credentials.go = {
              vendor = "opencode-go";
              apiKey.key = clientKey "go";
            };
            clientKeys.personal.routes = lib.mkForce [
              {
                api = "chat";
                credential = "go";
              }
            ];
          })
          // {
            catalog.vendors.opencode-go.models = ["beam-free" "claude-haiku-5-5" "gemini-4-argon"];
          });
        chatModels = ["beam-free" "gemini-4-argon"];
      in
        checkRows "${backend}: OpenCode Go chat grant" {
          "named chat selection is accepted" = failedMessages result == [];
          "runtime grant includes Gemini fallback but not native Claude messages" =
            result.config.ai.claude.normalized.settings.inference.credentials
            == [
              {
                name = "go";
                models = chatModels;
              }
            ];
        }) ["devenv" "hm"]
    );

    # Cross-owner consumption only: CPA's extracted offers reach Claude's selected API.
    module-ai-inference-zhipuai-credential = mkTest "ai-inference-zhipuai-credential" (
      lib.all (backend: let
        facts = import ../../lib/extracted/facts.nix {inherit lib;};
        expected = (facts.get (facts.load {dir = ../../packages/cliproxyapi/extracted;}).aggregate "zhipuai").models;
        result = evaluate backend (instanceChange {
          credentials.zhipuai = lib.mkForce {
            vendor = "zhipuai";
            apiKey.key = apiKey.key;
          };
        });
      in
        checkRows "${backend}: z.ai grant" {
          "named Anthropic selection is accepted" = failedMessages result == [];
          "vendor defaults reach the API-key grant without expanding the OAuth grant" =
            result.config.ai.claude.normalized.settings.inference.credentials
            == [
              {
                name = "personal";
                models = [];
              }
              {
                name = "zhipuai";
                models = expected;
              }
            ];
        }) ["devenv" "hm"]
    );

    module-ai-inference-instance-clients = mkTest "ai-inference-instance-clients" (let
      # Exercise the public renderer with the shape used before module defaults
      # supplied modelContextLengths. Only the module checks get those defaults.
      legacyBlocks = (import ../../packages/cliproxyapi/lib {inherit lib;}).cliproxyapi.providers.lower pkgs {
        legacy = {
          vendor = null;
          apiKey = {
            apis.responses = {
              base-url = "https://legacy.example/v1";
              models = ["legacy-model"];
            };
            key = clientKey "legacy";
            models = null;
            priority = null;
          };
        };
      };
      clientsHold = lib.all (backend: let
        result = evaluate backend {};
        settings = rendered result;
        rules = map (entry: entry.credentials) settings.access.key-allowlist;
        rows = map (expectedPickerRow "zhipuai") ["glm-5.3" "glm-5.3-flash"];
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
        # Read the settings file passed to Claude by the generated devenv launcher.
        launcherSettings = evaluation: let
          launcher = lib.findFirst (package: package.name or "" == "claude-code-inference") null evaluation.config.packages;
          matches = builtins.split "--settings ([^ ']+)" (launcher.buildCommand or "");
          path = lib.findFirst lib.isList [] matches;
        in
          if path == []
          then {}
          else builtins.fromJSON (builtins.readFile (lib.head path));
        instanceAfter = change: (evaluate backend (instanceChange change)).config.ai.cliproxyapi.instances.clients;
        readLengths = response: (instanceAfter {credentials.zhipuai.apiKey.apis.responses = response;}).credentials.zhipuai.apiKey.apis.responses.modelContextLengths;
        rejectsLength = invalid:
          rejectsChange readLengths {
            valid.modelContextLengths."glm-5.3" = 272000;
            invalid.modelContextLengths."glm-5.3" = invalid;
            expected."glm-5.3" = 272000;
          };
        readPickerModels = pickerModels:
          (lib.head
            (instanceAfter {
              clientKeys.personal.routes = lib.mkForce [((route "personal") // {inherit pickerModels;})];
            }).clientKeys.personal.routes).pickerModels;
        rejectsPickerModels = invalid:
          rejectsChange readPickerModels {
            valid = ["gpt-6.2-sol"];
            inherit invalid;
            expected = ["gpt-6.2-sol"];
          };
        aliasProblem = "settings.api-keys.claude[].tool-aliases requires";
        duplicateTargets = {
          A = "Z";
          B = "Z";
        };
        longAlias = lib.concatStrings (lib.replicate 65 "x");
        rejectsAlias = toolAliases:
          refused backend aliasProblem (instanceChange {credentials.zhipuai.apiKey = {inherit toolAliases;};});
        rejectsRaw = block:
          refused backend aliasProblem (instanceChange {settings.api-keys.claude = [block];});
        rawAccounts = accounts:
          instanceChange {
            settings.access.key-allowlist = [
              {
                api-key = clientKey "raw";
                credentials = [
                  {
                    inherit accounts;
                    kind = "oauth";
                    provider = "claude";
                  }
                ];
              }
            ];
          };
        rejectsAccounts = fragment: accounts: refused backend fragment (rawAccounts accounts);
        restricted = evaluate backend (rawAccounts [credentials.work.oauth.account]);
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
        splitModels = evaluation: family:
          (lib.findFirst (entry: entry.name == "split") null (rendered evaluation).api-keys.${family}).models;
        fallback = split {
          apis.chat.models = null;
          models = ["split-shared"];
        };
        priorityBlocks = priority:
          lib.concatLists (builtins.attrValues
            (rendered (evaluate backend (instanceChange {
              credentials = lib.mapAttrs (_: _: {apiKey = {inherit priority;};}) (lib.filterAttrs (_: credential: credential ? apiKey) credentials);
            }))).api-keys);
        priorityHolds = priority: map (block: block.priority) (priorityBlocks priority) == [priority priority priority];
        inheritedContext = evaluate backend (instanceChange {
          credentials.zhipuai.apiKey.apis.responses.modelContextLengths."glm-5.3" = 200000;
        });
        paidModels = [
          {
            name = "gpt-6.2-astra";
            max-context-length = 272000;
          }
          {
            name = "gpt-6.2-sol";
            max-context-length = 500000;
          }
        ];
        paidBlock = result: lib.findFirst (entry: entry.name == "paid") null (rendered result).api-keys.codex;
        # Both clients can reach the login. Only Claude can spill over to the paid key.
        codexGrants = routes:
          instanceChange {
            credentials = {
              codex.oauth = {
                account = redact.file "/fixture/codex-account";
                vendor = "codex";
              };
              paid.apiKey = {
                apis.responses = {
                  base-url = "https://api.openai.com/v1";
                  modelContextLengths = {
                    "gpt-6.2-astra" = 272000;
                    "gpt-6.2-sol" = 500000;
                  };
                  models = ["gpt-6.2-astra" "gpt-6.2-sol"];
                };
                key = redact.file "/fixture/openai-api-key";
                priority = -1;
              };
            };
            clientKeys.personal.routes = lib.mkForce routes;
            clientKeys.work.routes = lib.mkForce [(route "codex")];
          };
        codexOptIn = routes: evaluate backend (codexGrants routes);
        codexPickerRoute = (route "codex") // {pickerModels = ["gpt-6-luna" "gpt-6.1-terra" "gpt-6.2-astra" "gpt-6.2-sol"];};
        opted = codexOptIn [codexPickerRoute (route "paid")];
        filteredPaid = evaluate backend (lib.recursiveUpdate (codexGrants [(route "paid")]) {
          catalog.models.fixture-excluded = {
            maker = "fixture-maker";
            source = ["Responses context fixture"];
          };
          cliproxyapi.instances.clients.credentials.paid = {
            excludeMakers = ["fixture-maker"];
            apiKey.apis.responses = {
              models = ["fixture-excluded" "gpt-6.2-sol" "gpt-6.2-astra"];
              modelContextLengths.fixture-excluded = 12345;
            };
          };
        });
        paidFirst = codexOptIn [(route "paid") codexPickerRoute];
        plain = codexOptIn [(route "codex") (route "paid")];
        expectedPickerRow = credential: model: {
          inherit model;
          description = "${credential} through CLIProxyAPI";
        };
        expectedPicker = {
          modelPicker.options = map (expectedPickerRow "codex") ["gpt-6-luna" "gpt-6.1-terra" "gpt-6.2-astra" "gpt-6.2-sol"];
        };
        codexAccountRule = {
          accounts = [(redact.file "/fixture/codex-account")];
          kind = "oauth";
          provider = "codex";
        };
      in
        checkRows "${backend}: instance clients" {
          # A negative priority enables fallback; zero is a value, not an unset option.
          "negative API-key priority is forwarded to every served API" = priorityHolds (-1);
          "unset API-key priority is omitted from the three named blocks" =
            lib.mapAttrs (_:
              map (block: {
                inherit (block) name;
                hasPriority = block ? priority;
              }))
            settings.api-keys
            == {
              claude = [
                {
                  name = "zhipuai";
                  hasPriority = false;
                }
              ];
              codex = [
                {
                  name = "zhipuai";
                  hasPriority = false;
                }
              ];
              openai-compatibility = [
                {
                  name = "chat";
                  hasPriority = false;
                }
              ];
            };
          "zero API-key priority is forwarded rather than omitted" = priorityHolds 0;
          "OAuth rejects priority" = rejectsChange (change: (instanceAfter change).credentials.work.oauth) {
            valid = {};
            invalid.credentials.work.oauth.priority = -1;
            expected = credentials.work.oauth;
          };
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
          "API-key blocks" =
            settings.api-keys.claude
            == [
              {
                name = "zhipuai";
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
                name = "zhipuai";
                inherit (apiKey) models;
              }
            ];
          "per-API models accepted" = failedMessages splitResult == [];
          "per-API models do not bleed into another API" =
            splitModels splitResult "claude"
            == [{name = "split-anthropic";}]
            && splitModels splitResult "openai-compatibility" == [{name = "split-chat";}];
          "API without models falls back without replacing a different API's override" =
            failedMessages fallback
            == []
            && splitModels fallback "openai-compatibility" == [{name = "split-shared";}]
            && splitModels fallback "claude" == [{name = "split-anthropic";}];
          "API missing both model lists is refused" =
            failsWith ["credentials.split.apiKey serves API `chat` without models"] (split {apis.chat.models = null;});
          "API whose declared list merges empty is refused" =
            failsWith ["credentials.split.apiKey serves API `chat` without models"] (split {apis.chat.models = [(lib.mkIf false "split-chat")];});
          "picker lists the routed API's models" =
            splitResult.config.ai.claude.normalized.settings.inference.credentials
            == [
              {
                name = "split";
                models = ["split-chat"];
              }
            ];
          "Claude user picker" = backend != "hm" || ((claudeSettings result).modelPicker.options or null) == rows;
          "Claude devenv picker follows routes" = backend == "hm" || launcherSettings result == {modelPicker.options = rows;};
          "maker exclusions remove annotated models before rendering and grants" =
            failedMessages filteredPaid
            == []
            && (paidBlock filteredPaid).models == lib.reverseList paidModels
            && filteredPaid.config.ai.claude.normalized.settings.inference.credentials
            == [
              {
                name = "paid";
                models = ["gpt-6.2-sol" "gpt-6.2-astra"];
              }
            ];
          "only Responses annotates inherited models with configured context lengths" =
            failedMessages inheritedContext
            == []
            && (lib.head (rendered inheritedContext).api-keys.codex).models
            == [
              {
                name = "glm-5.3";
                max-context-length = 200000;
              }
              {name = "glm-5.3-flash";}
            ]
            && (lib.head (rendered inheritedContext).api-keys.claude).models
            == [{name = "glm-5.3";} {name = "glm-5.3-flash";}];
          "Responses context length rejects a string" = rejectsLength "272000";
          "Responses context length rejects zero" = rejectsLength 0;
          "Responses context lengths reject IDs outside the API override" = rejectsChange readLengths {
            valid = {
              models = ["glm-5.3"];
              modelContextLengths."glm-5.3" = 100;
            };
            invalid = {
              models = ["glm-5.3-flash"];
              modelContextLengths."glm-5.3" = 100;
            };
            expected."glm-5.3" = 100;
          };
          "inherited Responses list refuses an unlisted context length" = rejectsChange readLengths {
            valid.modelContextLengths."glm-5.3" = 100;
            invalid.modelContextLengths."glm-9" = 100;
            expected."glm-5.3" = 100;
          };
          "OAuth picker fixture accepted" = failedMessages opted == [] && failedMessages plain == [];
          "OAuth picker metadata stays on its selected route" =
            opted.config.ai.claude.normalized.settings.inference.credentials
            == [
              {
                models = [];
                name = "codex";
                pickerModels = ["gpt-6-luna" "gpt-6.1-terra" "gpt-6.2-astra" "gpt-6.2-sol"];
              }
              {
                models = ["gpt-6.2-astra" "gpt-6.2-sol"];
                name = "paid";
              }
            ]
            && opted.config.ai.codex.normalized.settings.inference.credentials
            == [
              {
                models = [];
                name = "codex";
              }
            ];
          "library lists each raw id once with its first route" =
            (import ../../packages/claude-code/lib/inference.nix {inherit lib pkgs;}).modelPickerOptions {
              inherit backend;
              resolvedInference = opted.config.ai.claude.normalized.settings.inference;
            }
            == expectedPicker.modelPicker.options;
          "paid route first supplies both shared picker descriptions" = let
            settingsWithPicker =
              if backend == "hm"
              then claudeSettings paidFirst
              else launcherSettings paidFirst;
          in
            failedMessages paidFirst
            == []
            && (settingsWithPicker.modelPicker.options or null)
            == [
              (expectedPickerRow "paid" "gpt-6.2-astra")
              (expectedPickerRow "paid" "gpt-6.2-sol")
              (expectedPickerRow "codex" "gpt-6-luna")
              (expectedPickerRow "codex" "gpt-6.1-terra")
            ];
          "OAuth picker in Claude user settings" = backend != "hm" || ((claudeSettings opted).modelPicker or null) == expectedPicker.modelPicker;
          "OAuth picker in Claude launcher settings only" = backend == "hm" || (launcherSettings opted == expectedPicker && !((claudeSettings opted) ? modelPicker));
          "picker models preserve CPA config and Codex files" = rendered opted == rendered plain && opted.config.ai.codex.files == plain.config.ai.codex.files;
          "only Claude has the paid route" =
            (rendered opted).access.key-allowlist
            == [
              {
                api-key = clientKey "personal";
                credentials = [
                  codexAccountRule
                  {
                    base-urls = ["https://api.openai.com/v1"];
                    kind = "apikey";
                    provider = "codex";
                  }
                ];
              }
              {
                api-key = clientKey "work";
                credentials = [codexAccountRule];
              }
            ];
          "API-key route refuses pickerModels" = let
            apiKeyRoute =
              (route "zhipuai")
              // {
                api = "anthropic";
                pickerModels = ["gpt-6.2-sol"];
              };
          in
            refused backend "API-key credential `zhipuai` takes its picker rows from its declared models; remove pickerModels" (instanceChange {clientKeys.personal.routes = lib.mkForce [(route "personal") apiKeyRoute];});
          "OAuth picker rejects an empty model ID" = rejectsPickerModels [""];
          "OAuth picker rejects a tab next to a valid model ID" = rejectsPickerModels ["gpt-6.2-sol" "\t"];
          "OAuth picker rejects whitespace inside a model ID" = rejectsPickerModels ["gpt 6"];
          "client key hand-written access refused" = refused backend "lists ai.cliproxyapi.instances.clients.clientKeys.personal.key by hand" (instanceChange {settings.access.api-keys = [(clientKey "personal")];});
          "client key hand-written rule refused" = refused backend "hand-written entry for ai.cliproxyapi.instances.clients.clientKeys.personal.key" (instanceChange {
            settings.access.key-allowlist = [
              {
                api-key = clientKey "personal";
                credentials = [(oauthRule "work")];
              }
            ];
          });
          "Codex has no credential profiles" = !(result.config.ai.codex.files ? ".codex/zhipuai.config.toml");
          "external adds no keys or rules" = !((rendered byUrl) ? access) && byUrl.config.ai.claude.normalized.settings.inference.key == clientKey "external";
          "config content contains placeholders rather than secret reference objects or paths" = let
            inherit (result.config.ai.services.cliproxyapi-clients.files.config) content;
          in
            !lib.any (fragment: lib.hasInfix fragment content) ["_redact" "/run/secrets/"];
          "unknown client key" = refused backend "clientKey names `missing`" {claude.settings.inference.clientKey = "missing";};
          "runtime instance refuses a direct key at the runtime option" =
            refused backend "ai.claude.settings.inference.key is set without `url`; Instance selections use `clientKey`" {claude.settings.inference.key = clientKey "direct";};
          "runtime instance without client key is refused at the runtime option" =
            refused backend "ai.claude.settings.inference.instance needs `clientKey`" {claude.settings.inference.clientKey = null;};
          "ambiguous API needs choice" = refused backend "needs api because it does not serve exactly one API" (instanceChange {clientKeys.work.routes = lib.mkForce [(route "zhipuai")];});
          "unserved API" = refused backend "does not serve API `chat`" (instanceChange {
            clientKeys.work.routes = lib.mkForce [
              {
                credential = "zhipuai";
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
          "both credential kinds refused" = refused backend "credentials.personal: declare exactly one" (instanceChange {credentials.personal = {inherit apiKey;};});
          "alias duplicate targets" = rejectsAlias duplicateTargets;
          "alias source collision" = rejectsAlias {
            A = "B";
            B = "C";
          };
          "alias source too long" = rejectsAlias {${longAlias} = "A";};
          "alias target too long" = rejectsAlias {A = longAlias;};
          "raw API key alias collision" = rejectsRaw {keys = [{tool-aliases = duplicateTargets;}];};
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
          "empty account restriction would grant every account" = rejectsAccounts "accounts merged to an empty list" [(lib.mkIf false credentials.work.oauth.account)];
          "null account restriction would be dropped at rendering" = rejectsAccounts "accounts contains null" [null];
          "raw account restriction retains its exact reference" =
            (lib.findFirst (entry: entry.api-key == clientKey "raw") null (rendered restricted).access.key-allowlist)
            == {
              api-key = clientKey "raw";
              credentials = [(oauthRule "work")];
            };
          "literal OAuth account" = rejectsChange (change: (instanceAfter change).credentials.personal.oauth.account) {
            valid = {};
            invalid.credentials.personal.oauth.account = lib.mkForce "secret";
            expected = credentials.personal.oauth.account;
          };
          "required OAuth account" = rejectsChange (change: (instanceAfter change).credentials.personal.oauth.account) {
            valid = {};
            invalid.credentials.personal = lib.mkForce {oauth.vendor = "claude";};
            expected = credentials.personal.oauth.account;
          };
          "literal client key" = rejectsChange (change: (instanceAfter change).clientKeys.personal.key) {
            valid = {};
            invalid.clientKeys.personal.key = lib.mkForce "secret";
            expected = clientKey "personal";
          };
          "literal upstream credential" = rejectsChange (change: (instanceAfter change).credentials.zhipuai.apiKey.key) {
            valid = {};
            invalid.credentials.zhipuai.apiKey.key = lib.mkForce "secret";
            expected = apiKey.key;
          };
        }) ["devenv" "hm"];
    in
      checkRows "instance clients" {
        "client contracts hold on both backends" = clientsHold;
        "legacy public renderer emits a name-only Responses row" = (lib.head legacyBlocks.codex).models == [{name = "legacy-model";}];
      });

    # The authentication key requires a redact reference at both scopes;
    # cleartext and the retired credential branches cannot enter normalization.
    module-ai-inference-redacted-key = mkTest "ai-inference-redacted-key" (
      lib.all (backend:
        lib.all (scope: let
          readKey = key: let
            result = evalApp backend {
              ai = lib.setAttrByPath scope {
                inherit key;
                url = "http://127.0.0.1:8317";
              };
            };
          in
            (lib.getAttrFromPath scope result.config.ai).key;
          rejects = invalid:
            rejectsChange readKey {
              valid = instanceKey;
              inherit invalid;
              expected = instanceKey;
            };
        in
          checkRows "${backend}: ${lib.showOption (["ai"] ++ scope ++ ["key"])}" {
            "legacy file attribute is rejected" = rejects {file = "/run/secrets/key";};
            "literal key is rejected" = rejects "literal-client-key";
            "store path reference is rejected" = rejects {_redact.file = "${builtins.storeDir}/key";};
          }) [["settings" "inference"] ["testapp" "settings" "inference"]])
      ["devenv" "hm"]
    );

    # Cover valid origin/key and instance/client pairs, incomplete or conflicting
    # selections, and missing or disabled instances. Runtimes append their own URL paths.
    module-ai-inference-root-selection-validation = mkTest "ai-inference-root-selection-validation" (let
      checkBackend = backend: evaluate: let
        select = inference: evaluate {ai = instances // {settings.inference = inference;};};
        valid = {
          key = instanceKey;
          url = "http://[::1]:8317";
        };
        selected = {
          clientKey = "main";
          instance = "main";
        };
        rejects = fragment: inference: failsWith ["ai.settings.inference.${fragment}"] (select inference);
      in
        checkRows "${backend}: root inference selection" {
          "client key without instance rejected" = rejects "clientKey is set without `instance`" (valid // {inherit (selected) clientKey;});
          "command key and hostname accepted" =
            failedMessages (select {
              key = redact.command "${pkgs.hello}/bin/hello";
              url = "http://localhost:8317";
            })
            == [];
          "disabled instance rejected" = rejects "instance names `ai.cliproxyapi.instances.off`, which is disabled." (selected // {instance = "off";});
          "instance and origin rejected together" = rejects "url and ai.settings.inference.instance both select a proxy" (selected // valid);
          "instance with named client accepted" = failedMessages (select selected) == [];
          "instance without client key rejected" = rejects "instance needs `clientKey`" {inherit (selected) instance;};
          "key without origin rejected" = rejects "key is set without `url`" {inherit (valid) key;};
          "missing instance rejected with registered names" = rejects "instance names `missing`, which no proxy owner registers; registered instances: alt, main, off." (selected // {instance = "missing";});
          "origin with IPv6 and file key accepted" = failedMessages (select valid) == [];
          "origin with a path rejected" = rejects "url must be the proxy origin only" (valid // {url = "http://127.0.0.1:8317/v1";});
          "origin without key rejected" = rejects "url needs `key`" {inherit (valid) url;};
        };
    in
      checkRows "root inference selection" {
        devenv = checkBackend "devenv" evalDevenv;
        hm = checkBackend "hm" evalHm;
      });

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
        checkRows "${backend}: runtime inference" {
          "directly assigned normalized URL must be an origin" = rejectsChange (url:
            (evalApp backend {
              ai.testapp.normalized.settings.inference = lib.mkForce {
                inherit url;
                backend = "cliproxyapi";
              };
            }).config.ai.testapp.normalized.settings.inference.url) {
            valid = "http://127.0.0.1:8317";
            invalid = "http://127.0.0.1:8317/v1";
            expected = "http://127.0.0.1:8317";
          };
          "explicit runtime instance null opts out without rejecting the inherited client key" =
            resolved optedOut == null && failedMessages (evalApp backend optedOut) == [];
          "profile default is not in conflict with unset root fields" =
            removeAttrs profileDefault.config.ai.testapp.normalized.settings.inference ["backend" "credentials"]
            == {
              key = instanceKey;
              url = "http://127.0.0.1:8400";
            }
            && failedMessages profileDefault == [];
          "root URL and key become a CLIProxyAPI endpoint with no grants" =
            (evalApp backend {ai.settings.inference = root;}).config.ai.testapp.normalized.settings.inference
            == root
            // {
              backend = "cliproxyapi";
              credentials = [];
            };
          "runtime URL selection drops the inherited instance and client key" =
            resolved switchedToUrl == work && failedMessages (evalApp backend switchedToUrl) == [];
          "runtime cannot explicitly select both forms" = failsWith ["ai.testapp.settings.inference.url and ai.testapp.settings.inference.instance both select a proxy"] (evalApp backend (withInstances {
            settings.inference = root;
            testapp.settings.inference = mainSelection // root;
          }));
          "runtime instance changes the origin while retaining the client key" =
            resolved (withInstances {
              settings.inference = mainSelection;
              testapp.settings.inference.instance = "alt";
            })
            == {
              key = instanceKey;
              url = "http://127.0.0.1:8403";
            };
          "runtime instance selection drops the inherited URL and key" =
            resolved switchedToInstance
            == {
              key = instanceKey;
              url = "http://127.0.0.1:8400";
            }
            && failedMessages (evalApp backend switchedToInstance) == [];
          "runtime key-only override keeps the root origin" =
            resolved keyOnly == root // {inherit (work) key;} && failedMessages (evalApp backend keyOnly) == [];
          "runtime key without an origin is rejected at the runtime option" =
            failsWith ["ai.testapp.settings.inference.key is set without `url`"] (evalApp backend {ai.testapp.settings.inference.key = work.key;});
          "runtime missing instance is rejected at the runtime option" = failsWith ["ai.testapp.settings.inference.instance names `missing`, which no proxy owner registers"] (evalApp backend (withInstances {
            settings.inference = mainSelection;
            testapp.settings.inference.instance = "missing";
          }));
          "runtime origin without a key is rejected at the runtime option" = failsWith ["ai.testapp.settings.inference.url needs `key`"] (evalApp backend {
            ai.testapp.settings.inference.url = "http://127.0.0.1:8318";
          });
        })
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
        clientless = evaluate {ai.settings.inference = second;};
        expectedEndpoint = {
          backend = "relay";
          url = "http://127.0.0.1:8500";
        };
        resolvedInference = clientless.config.ai.testapp.normalized.settings.inference;
        claudeInference = (import ../../packages/claude-code/lib/inference.nix {inherit lib pkgs;}).withLowerings {
          relay = {resolvedInference, ...}: {settings.env.HTTPS_PROXY = resolvedInference.url;};
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
        checkRows "${backend}: inference instance registry" {
          "Claude names the unsupported owner" = failsWith [(unsupported "claude")] runtimes;
          "Claude does not install CLIProxyAPI settings for an unsupported owner" =
            runtimes.config.ai.claude.native.settings.apiKeyHelper
            == null
            && !(runtimes.config.ai.claude.native.settings.env ? ANTHROPIC_BASE_URL);
          "Codex names the unsupported owner" = failsWith [(unsupported "codex")] runtimes;
          "Codex does not apply CLIProxyAPI settings for an unsupported owner" =
            !(runtimes.config.ai.codex.native.settings.tui or {} ? model_availability_nux);
          "Codex does not warn about a missing launcher when it has no lowering" =
            backend != "devenv" || !(builtins.any (lib.hasPrefix "ai.codex.settings.inference is selected but ai.codex.package is null") runtimes.config.warnings);
          "a clientless instance uses its own backend and needs no key" =
            resolvedInference == expectedEndpoint && failedMessages clientless == [];
          "adding a client key to a clientless instance is refused and leaves no endpoint" =
            failsWith ["ai.settings.inference.clientKey is set, but `ai.relay.instances.second` declares no clients."] withClientKey
            && withClientKey.config.ai.testapp.normalized.settings.inference == null;
          "custom Claude lowering takes only its own settings" = relaySettings == {env.HTTPS_PROXY = "http://127.0.0.1:8500";};
          "custom Claude lowering does not inherit CLIProxyAPI launcher flags" = claudeInference.launcherFlags {inherit backend resolvedInference;} == [];
          "duplicate instance names are refused by the owner claim" =
            failsWith ["ai.claims.inference-instance.main: claimed by cliproxyapi and relay"] (evaluate {ai = instances // {relay.claims.inference-instance = ["main"];};});
          "switching to a clientless instance discards the root client key" =
            switched.config.ai.testapp.normalized.settings.inference == expectedEndpoint && failedMessages switched == [];
        })
      ["devenv" "hm"]
    );
  };
}
