# `ai.proxy` core contracts (lib/ai/proxy): selection validation and
# resolution, and the per-runtime override.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiBase evalDevenv evalDevenvModules evalHm evalHmModules mkTest;

  redact = import ../../lib/redact {inherit lib;};
  # The key a selected CLIProxyAPI instance accepts: one reference on both
  # sides, in the instance's access list and in the selection.
  instanceKey = redact.file "/run/secrets/ai-proxy-key";
  instances.cliproxyapi.instances = {
    main = {
      port = 8400;
      settings.access.api-keys = [instanceKey];
    };
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
  evalApp = backend: config:
    (
      if backend == "hm"
      then evalHmModules
      else evalDevenvModules
    ) [
      (aiBase.app.${backend + "Transform"} record)
      {inherit config;}
    ];

  # Runtimes routed through instance `clients`, which declares `providers`
  # and lists no runtime key by hand: z-ai serves the Anthropic and Responses
  # APIs, other the chat API. Claude and Codex are enabled.
  proxyLib = import ../../lib/ai/proxy {inherit lib;};
  runtimeKey = name: redact.file "/run/secrets/cpa-${name}-key";
  routed = name: {
    instance = "clients";
    key = runtimeKey name;
  };
  routedTo = name: enabled: routed name // {providers = lib.genAttrs enabled (_: {enable = true;});};
  zai = {
    anthropic = "https://api.z.ai/api/anthropic";
    responses = "https://api.z.ai/api/v1";
  };
  chat = "https://other.example/v1";
  providers = {
    other = {
      apis.chat.base-url = chat;
      key = redact.file "/run/secrets/other-key";
      models = ["other-1"];
    };
    z-ai = {
      apis = lib.mapAttrs (_: base-url: {inherit base-url;}) zai;
      key = redact.file "/run/secrets/zai-key";
      models = ["glm-5.3" "glm-5.3-flash"];
    };
  };
  routedEval = backend: ai:
    evalApp backend (lib.recursiveUpdate {
      ai = {
        claude.enable = true;
        cliproxyapi.instances.clients = {
          port = 8402;
          inherit providers;
        };
        codex.enable = true;
      };
    } {inherit ai;});
  oauth = provider: {
    kind = "oauth";
    inherit provider;
  };
  apiKey = provider: base-url: {
    base-urls = [base-url];
    kind = "apikey";
    inherit provider;
  };
  handBlock = {
    base-url = "https://hand.example";
    keys = [{api-key = redact.file "/run/secrets/hand-key";}];
  };
  # Go's strings.TrimSpace trims it; written as the JSON escape so the source
  # holds no invisible character.
  noBreakSpace = builtins.fromJSON ''"\u00a0"'';
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;

  # Each runtime with its own key; Claude keeps its login beside z-ai, and
  # Codex, with `allow = []`, reaches only z-ai and other.
  bothRuntimes = {
    claude.proxy = routed "claude";
    codex.proxy = routed "codex";
  };
  withProviders = {
    claude.proxy = routedTo "claude" ["z-ai"];
    cliproxyapi.instances.clients.settings.api-keys.claude = [handBlock];
    codex.proxy = lib.recursiveUpdate (routedTo "codex" ["z-ai"]) {
      allow = [];
      providers.other = {
        api = "chat";
        enable = true;
      };
    };
  };

  # Runtime routing through an instance, by case name: the `ai` settings and
  # what evaluating them gives, `thrown` when an option type or the render
  # refuses them, else the failed assertions. `refused` matches a fragment of
  # one failure.
  routingCases = let
    accepted = ai: {
      inherit ai;
      expect = outcome: outcome == [];
    };
    fails = message: ai: {
      inherit ai;
      expect = outcome: outcome == [message];
    };
    refused = fragment: ai: {
      inherit ai;
      expect = outcome: lib.isList outcome && lib.any (lib.hasInfix fragment) outcome;
    };
    thrown = ai: {
      inherit ai;
      expect = outcome: outcome == "thrown";
    };
    claimed = "ai.claims.proxy-client-key.${proxyLib.keyClaim (runtimeKey "claude")}: claimed by claude and codex";
    handWritten = settings: {
      claude.proxy = routed "claude";
      cliproxyapi.instances.clients.settings = settings;
    };
    handURL = url: {cliproxyapi.instances.clients.settings.api-keys.claude = [(handBlock // {base-url = url;})];};
    # CPA trims Go's whole space set from a block's URL; Nix cannot, so a
    # hand-written URL in a provider's family must start and end with a
    # printable ASCII character, which makes the exact comparison CPA's.
    unprintable = "ai.cliproxyapi.instances.clients.settings.api-keys.claude: the block with base-url";
    # The type keeps provider URLs to printable ASCII, so padding is not a
    # second spelling of an existing URL.
    providerURL = url: {cliproxyapi.instances.clients.providers.other.apis.chat.base-url = url;};
    testapp = proxy: {
      testapp = {
        enable = true;
        inherit proxy;
      };
    };
  in {
    # Accepted.
    "a disabled runtime without allow" = accepted {testapp.proxy = routed "testapp";};
    # A hand-written block with no base URL, beside a provider in its family,
    # is a direct upstream.
    "a hand-written block without a base URL" = accepted {
      claude.proxy = routedTo "claude" ["z-ai"];
      cliproxyapi.instances.clients.settings.api-keys.claude = [handBlock (handBlock // {base-url = null;})];
    };
    "a hand-written key of another client" = accepted (handWritten {access.api-keys = [instanceKey];});
    "a provider without allow, given an api" = accepted (testapp (routed "testapp"
      // {
        providers.z-ai = {
          api = "anthropic";
          enable = true;
        };
      }));
    "each runtime with its own key" = accepted bothRuntimes;
    "providers on both runtimes" = accepted withProviders;

    # Refused by an assertion.
    "a hand-written allowlist entry for a runtime key" = fails "ai.cliproxyapi.instances.clients.settings.access.key-allowlist has a hand-written entry for ai.claude.proxy.key, whose entry ai.claude.proxy.allow and .providers set. Remove the hand-written entry." (handWritten {
      access.key-allowlist = [
        {
          api-key = runtimeKey "claude";
          credentials = [(oauth "claude")];
        }
      ];
    });
    "a hand-written runtime key" = fails "ai.cliproxyapi.instances.clients.settings.access.api-keys lists ai.claude.proxy.key by hand; ai.claude.proxy adds it to this instance. Remove the hand-written entry." (handWritten {access.api-keys = [(runtimeKey "claude")];});
    "a hand-written URL ending in a no-break space" = refused unprintable (handURL ("https://hand.example" + noBreakSpace));
    "a hand-written URL starting with a space" = refused unprintable (handURL (" " + zai.anthropic));
    "a provider base URL another block shares" = refused "ai.cliproxyapi.instances.clients.providers.z-ai.apis.anthropic.base-url `${zai.anthropic}` is also the base URL of another settings.api-keys.claude block" (handURL zai.anthropic);
    "a provider name that is not one word" = refused "ai.cliproxyapi.instances.clients.providers.../x: a provider name must be" {cliproxyapi.instances.clients.providers."../x" = providers.other;};
    "a provider without the runtime's API" = refused "ai.claude.proxy.providers.other reaches ai.cliproxyapi.instances.clients.providers.other through the anthropic API, which it does not serve: give it `apis.anthropic`, or set `ai.claude.proxy.providers.other.api` to one it serves (chat)." {claude.proxy = routedTo "claude" ["other"];};
    "a runtime with no default and no allow" = refused "ai.testapp.proxy.allow is unset" (testapp (routed "testapp"));
    "a runtime with no API and no api" = refused "ai.testapp.proxy.providers.z-ai.api is unset, and nothing sets a default API: set it to one ai.cliproxyapi.instances.clients.providers.z-ai serves (anthropic, responses)." (testapp (routedTo "testapp" ["z-ai"]));
    "an api the provider does not serve" = refused "ai.codex.proxy.providers.other reaches ai.cliproxyapi.instances.clients.providers.other through the responses API" {
      codex.proxy =
        routed "codex"
        // {
          providers.other = {
            api = "responses";
            enable = true;
          };
        };
    };
    "an instance selection without a key" = refused "ai.codex.proxy.instance needs `key`" {codex.proxy.instance = "clients";};
    # The refusal names the runtime option a bad rule came from.
    "an oauth rule with base-urls from a runtime" = refused "ai.claude.proxy.allow has a rule with kind = \"oauth\" and base-urls" {claude.proxy = routed "claude" // {allow = [(oauth "claude" // {base-urls = [zai.anthropic];})];};};
    "an unknown provider" = refused "ai.claude.proxy.providers.missing names `missing`, which is not a `ai.cliproxyapi.instances.clients.providers` entry." {claude.proxy = routedTo "claude" ["missing"];};
    "one key on both runtimes" = refused claimed {
      claude.proxy = routed "claude";
      codex.proxy = routed "claude";
    };
    "one root key for both runtimes" = refused claimed {proxy = routed "claude";};
    "providers without an instance selection" = refused "ai.claude.proxy.providers.z-ai needs an `instance` selection" {
      claude.proxy = {
        key = runtimeKey "claude";
        providers.z-ai.enable = true;
        url = "http://127.0.0.1:8317";
      };
    };

    # Refused by the option type.
    "a provider URL ending in a no-break space" = thrown (providerURL (chat + noBreakSpace));
    "a provider URL ending in a space" = thrown (providerURL (chat + " "));
  };
in {
  checks = {
    # Each enabled runtime routed through an instance adds its own key to the
    # instance's `access.api-keys` and its `allow` rules (Claude and Codex
    # default to their own login) plus one rule per enabled provider as that
    # key's `access.key-allowlist` entry, and its launcher resolves the same
    # key. The instance's `providers` lower into `settings.api-keys` blocks
    # beside hand-written ones. A disabled runtime or a `url` selection adds
    # nothing. `routingCases` holds the refusals.
    module-ai-proxy-instance-clients = mkTest "ai-proxy-instance-clients" (let
      problems = lib.concatMap (backend: let
        evaluate = routedEval backend;
        label = name: "${backend}: ${name}";
        file = result: result.config.ai.services.cliproxyapi-clients.files.config;
        # The rendered config with each secret placeholder replaced by its
        # reference; null when a reference was written into it as is.
        rendered = result: let
          inherit (file result) content secrets;
          fill = value:
            if builtins.isList value
            then map fill value
            else if builtins.isAttrs value
            then lib.mapAttrs (_: fill) value
            else if builtins.isString value
            then secrets.${lib.removeSuffix "}" (lib.removePrefix "{$" value)} or value
            else value;
        in
          if lib.hasInfix "_redact" content
          then null
          else fill (builtins.fromJSON content);
        # A provider's block as its family renders it.
        lowered = name: base-url: key: {
          inherit base-url name;
          keys = [({api-key = providers.${name}.key;} // key)];
          models = map (model: {name = model;}) providers.${name}.models;
        };
        claim = name: {${proxyLib.keyClaim (runtimeKey name)} = [name];};
        outcome = ai: let
          result = evaluate ai;
          messages = failedMessages result;
        in
          if !succeeds messages
          then "thrown"
          else if messages != [] || succeeds (file result).content
          then messages
          else "thrown";
        both = evaluate bothRuntimes;
        narrowed = evaluate {claude.proxy = routed "claude" // {allow = [(apiKey "claude" zai.anthropic)];};};
        claudeOnly = evaluate {claude.proxy = routed "claude";};
        codexOff = evaluate {
          claude.proxy = routed "claude";
          codex = {
            enable = false;
            proxy = routed "codex";
          };
        };
        byUrl = evaluate {
          claude.proxy = {
            key = runtimeKey "claude";
            url = "http://127.0.0.1:8317";
          };
        };
        result = evaluate withProviders;
        # The credential provider CPA's OpenAICompatibleProviderKey gives each
        # chat block (8.0.38 internal/util/provider.go:18-26): an ordinary
        # name, an uppercase one, one already prefixed, and the special one.
        chatCredentials = {
          Acme = {
            base-url = "https://acme.example/v1";
            provider = "openai-compatible-acme";
          };
          openai-compatibility = {
            base-url = "https://compat.example/v1";
            provider = "openai-compatibility";
          };
          openai-compatible-pre = {
            base-url = "https://pre.example/v1";
            provider = "openai-compatible-pre";
          };
          other = {
            base-url = chat;
            provider = "openai-compatible-other";
          };
        };
        chatRules =
          map (entry: entry.credentials)
          (rendered (evaluate {
            cliproxyapi.instances.clients.providers = lib.mapAttrs (_: credential:
              providers.other // {apis.chat.base-url = credential.base-url;})
            (removeAttrs chatCredentials ["other"]);
            codex.proxy =
              routed "codex"
              // {
                allow = [];
                providers =
                  lib.mapAttrs (_: _: {
                    api = "chat";
                    enable = true;
                  })
                  chatCredentials;
              };
          }))
          .access
          .key-allowlist;
        # The allowlist patch's apikey match: provider equal ignoring case,
        # and the credential's base URL listed.
        admits = rule: credential:
          lib.toLower rule.provider
          == lib.toLower credential.provider
          && lib.elem credential.base-url rule.base-urls;
      in
        lib.optional (routingCases == {}) (label "no routing cases")
        ++ lib.concatLists (lib.mapAttrsToList (name: case: lib.optional (!case.expect (outcome case.ai)) (label "case `${name}`")) routingCases)
        ++ lib.optional ((rendered both).access
          != {
            api-keys = map runtimeKey ["claude" "codex"];
            key-allowlist = map (name: {
              api-key = runtimeKey name;
              credentials = [(oauth name)];
            }) ["claude" "codex"];
          }) (label "generated api-keys and allowlist")
        ++ lib.optional (both.config.ai.claims.proxy-client-key != claim "claude" // claim "codex") (label "claims")
        ++ lib.optional (lib.any (name:
          both.config.ai.${name}.normalized.proxy
          != {
            key = runtimeKey name;
            url = "http://127.0.0.1:8402";
          }) ["claude" "codex"]) (label "launcher keys")
        ++ lib.optional (map (entry: entry.credentials) (rendered narrowed).access.key-allowlist != [[(apiKey "claude" zai.anthropic)]]) (label "allow replaces the default")
        ++ lib.optional ((file codexOff).secrets
          != (file claudeOnly).secrets
          || (rendered codexOff).access.api-keys != [(runtimeKey "claude")]
          || codexOff.config.ai.claims.proxy-client-key != claim "claude") (label "disabled runtime adds nothing")
        ++ lib.optional ((rendered byUrl) ? access || byUrl.config.ai.internal.proxyClients != {}) (label "url selection adds nothing")
        # A hand-written block stays beside the providers'.
        ++ lib.optional ((rendered result).api-keys
          != {
            claude = [(lowered "z-ai" zai.anthropic {}) handBlock];
            codex = [(lowered "z-ai" zai.responses {disable-codex-cloaking = true;})];
            openai-compatibility = [(lowered "other" chat {})];
          }) (label "lowering")
        ++ lib.optional (map (entry: entry.credentials) (rendered result).access.key-allowlist
          != [
            [(oauth "claude") (apiKey "claude" zai.anthropic)]
            [(apiKey "openai-compatible-other" chat) (apiKey "codex" zai.responses)]
          ]) (label "generated allowlist")
        # Each chat rule names the credential CPA synthesizes for its block,
        # and no other provider's rule admits that credential: every
        # credential moved to a rule's base URL, so the provider alone decides.
        ++ lib.optional (chatRules != [(lib.mapAttrsToList (_: credential: apiKey credential.provider credential.base-url) chatCredentials)]) (label "chat provider identities")
        ++ lib.optional (map (rule: lib.attrNames (lib.filterAttrs (_: credential: admits rule (credential // {base-url = lib.head rule.base-urls;})) chatCredentials)) (lib.head chatRules)
          != map lib.singleton (lib.attrNames chatCredentials)) (label "a chat rule admits only its own credential"))
      ["devenv" "hm"];
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
      # An instance selection: valid with a key, refused without one, beside
      # a url, or naming a missing or disabled instance.
      && lib.all (evaluate: let
        select = proxy: evaluate {ai = instances // {inherit proxy;};};
      in
        failedMessages (select {
          instance = "main";
          key = instanceKey;
        })
        == []
        && failsWith ["ai.proxy.instance needs `key`"] (select {instance = "main";})
        && failsWith ["ai.proxy.url and ai.proxy.instance both select a proxy"] (select {
          instance = "main";
          key = instanceKey;
          url = "http://127.0.0.1:8317";
        })
        && failsWith ["ai.proxy.instance names `missing`, which is not an `ai.cliproxyapi.instances` entry."] (select {
          instance = "missing";
          key = instanceKey;
        })
        && failsWith ["ai.proxy.instance names `ai.cliproxyapi.instances.off`, which is disabled."] (select {
          instance = "off";
          key = instanceKey;
        })) [evalDevenv evalHm]
    );

    # The root selection reaches a consuming runtime as the resolved endpoint;
    # a runtime selection replaces it whole, on both backends, so a runtime
    # key never pairs with a root url; a runtime's own invalid selection fails
    # with its own option path, even while the runtime is disabled. A url
    # with a path set on the normalized option directly is refused too.
    module-ai-proxy-runtime-override = mkTest "ai-proxy-runtime-override" (
      lib.all (backend: let
        resolved = config: (evalApp backend config).config.ai.testapp.normalized.proxy;
        root = {
          key = redact.file "/run/secrets/ai-proxy-key";
          url = "http://127.0.0.1:8317";
        };
        work = {
          key = redact.concat ["Bearer " (redact.command "${pkgs.hello}/bin/hello")];
          url = "http://127.0.0.1:8318";
        };
        keyOnly = {
          ai = {
            proxy = root;
            testapp.proxy.key = redact.file "/run/secrets/work-proxy-key";
          };
        };
      in
        resolved {}
        == null
        && resolved {ai.proxy = root;} == root
        && resolved {
          ai = {
            proxy = root;
            testapp.proxy = work;
          };
        }
        == work
        && resolved {ai.testapp.proxy = work;} == work
        # An instance resolves to its loopback origin at either scope, and a
        # runtime instance replaces a root url whole.
        && resolved {
          ai =
            instances
            // {
              proxy = {
                instance = "main";
                key = instanceKey;
              };
            };
        }
        == {
          key = instanceKey;
          url = "http://127.0.0.1:8400";
        }
        && resolved {
          ai =
            instances
            // {
              proxy = root;
              testapp.proxy = {
                instance = "main";
                inherit (work) key;
              };
            };
        }
        == {
          inherit (work) key;
          url = "http://127.0.0.1:8400";
        }
        && failsWith ["ai.testapp.proxy.instance names `missing`"] (evalApp backend {
          ai.testapp.proxy = {
            instance = "missing";
            inherit (work) key;
          };
        })
        && resolved keyOnly == root
        && failsWith ["ai.testapp.proxy.key is set without `url`"] (evalApp backend keyOnly)
        && failsWith ["ai.testapp.proxy.url needs `key`"] (evalApp backend {
          ai.testapp.proxy.url = "http://127.0.0.1:8318";
        })
        && !(builtins.tryEval (builtins.deepSeq (resolved {
            ai.testapp.normalized.proxy = lib.mkForce (root // {url = "http://127.0.0.1:8317/v1";});
          })
          true)).success)
      ["devenv" "hm"]
    );
  };
}
