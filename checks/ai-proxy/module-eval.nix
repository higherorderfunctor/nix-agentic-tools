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

  # Runtimes routed through instance `clients`, which lists no runtime key by
  # hand. Claude and Codex are enabled.
  proxyLib = import ../../lib/ai/proxy {inherit lib;};
  runtimeKey = name: redact.file "/run/secrets/cpa-${name}-key";
  routed = name: {
    instance = "clients";
    key = runtimeKey name;
  };
  zai = {
    anthropic = "https://api.z.ai/api/anthropic";
    responses = "https://api.z.ai/api/v1";
  };
  routedEval = backend: ai:
    evalApp backend (lib.recursiveUpdate {
      ai = {
        claude.enable = true;
        cliproxyapi.instances.clients.port = 8402;
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
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;

  # Each runtime with its own key.
  bothRuntimes = {
    claude.proxy = routed "claude";
    codex.proxy = routed "codex";
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
    claimed = "ai.claims.proxy-client-key.${proxyLib.keyClaim (runtimeKey "claude")}: claimed by claude and codex";
    handWritten = settings: {
      claude.proxy = routed "claude";
      cliproxyapi.instances.clients.settings = settings;
    };
    testapp = proxy: {
      testapp = {
        enable = true;
        inherit proxy;
      };
    };
  in {
    # Accepted.
    "a disabled runtime without allow" = accepted {testapp.proxy = routed "testapp";};
    "a hand-written key of another client" = accepted (handWritten {access.api-keys = [instanceKey];});
    "each runtime with its own key" = accepted bothRuntimes;

    # Refused by an assertion.
    "a hand-written allowlist entry for a runtime key" = fails "ai.cliproxyapi.instances.clients.settings.access.key-allowlist has a hand-written entry for ai.claude.proxy.key, whose entry ai.claude.proxy.allow sets. Remove the hand-written entry." (handWritten {
      access.key-allowlist = [
        {
          api-key = runtimeKey "claude";
          credentials = [(oauth "claude")];
        }
      ];
    });
    "a hand-written runtime key" = fails "ai.cliproxyapi.instances.clients.settings.access.api-keys lists ai.claude.proxy.key by hand; ai.claude.proxy adds it to this instance. Remove the hand-written entry." (handWritten {access.api-keys = [(runtimeKey "claude")];});
    "a runtime with no default and no allow" = refused "ai.testapp.proxy.allow is unset" (testapp (routed "testapp"));
    "an instance selection without a key" = refused "ai.codex.proxy.instance needs `key`" {codex.proxy.instance = "clients";};
    # The refusal names the runtime option a bad rule came from.
    "an oauth rule with base-urls from a runtime" = refused "ai.claude.proxy.allow has a rule with kind = \"oauth\" and base-urls" {claude.proxy = routed "claude" // {allow = [(oauth "claude" // {base-urls = [zai.anthropic];})];};};
    "one key on both runtimes" = refused claimed {
      claude.proxy = routed "claude";
      codex.proxy = routed "claude";
    };
    "one root key for both runtimes" = refused claimed {proxy = routed "claude";};
  };
in {
  checks = {
    # Each enabled runtime routed through an instance adds its own key to the
    # instance's `access.api-keys` and its `allow` rules (Claude and Codex
    # default to their own login) as that key's `access.key-allowlist` entry,
    # and its launcher resolves the same key. A disabled runtime or a `url`
    # selection adds nothing. `routingCases` holds the refusals.
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
        ++ lib.optional ((rendered byUrl) ? access || byUrl.config.ai.internal.proxyClients != {}) (label "url selection adds nothing"))
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
