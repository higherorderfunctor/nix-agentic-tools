# Literal expectations reject unused graph declarations, protocol-kind gaps,
# same-provider exemptions, alias string comparisons and instance-wide checks.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  catalog = (import ../lib/default.nix).aiModule.catalog {inherit lib;};
  model = maker: {
    inherit maker;
    aliases = {};
    source = "synthetic catalog fixture";
  };
  identityModels = {
    future-openai = model "openai";
    gpt = (model "openai") // {aliases.go = ["go-gpt"];};
    other = model "deepseek";
  };
  resolve = definitions: catalog.resolve ({models = identityModels;} // definitions);
  finite = resolve {
    pools = {
      a.models = ["gpt"];
      b.models = ["go-gpt"];
    };
    runtimes.codex.pools = ["b" "a"];
  };
  mixed = resolve {
    pools = {
      codex.providerCatalogs = ["codex"];
      go.models = ["go-gpt"];
    };
    runtimes.codex.pools = ["go" "codex"];
  };
  open = resolve {
    pools = {
      personal.providerCatalogs = ["codex"];
      work.providerCatalogs = ["codex"];
    };
    runtimes.codex.pools = ["work" "personal"];
  };
  openAliases = resolve {
    providers = {
      codex.maker = "openai";
      secondary.maker = "openai";
    };
    pools = {
      personal.providerCatalogs = ["codex"];
      work.providerCatalogs = ["secondary"];
    };
    runtimes.codex.pools = ["work" "personal"];
  };
  future = resolve {
    pools = {
      codex.providerCatalogs = ["codex"];
      go.models = ["future-openai"];
    };
    runtimes.codex.pools = ["go" "codex"];
  };
  disjoint = resolve {
    pools = {
      a.models = ["gpt"];
      b.models = ["go-gpt"];
    };
    runtimes = {
      claude.pools = ["a"];
      codex.pools = ["b"];
    };
  };
  shared = resolve {
    pools.one = {
      models = ["gpt"];
      credentials = {
        first = {
          auth = "apiKey";
          binding = "main/first";
        };
        second = {
          auth = "apiKey";
          binding = "main/second";
        };
      };
    };
    runtimes.codex.pools = ["one" "one"];
  };
  rejected = value: !(builtins.tryEval (builtins.deepSeq value.pools true)).success;
  redact = import ../../../lib/redact {inherit lib;};
  secret = name: redact.file "/synthetic/${name}";
  key = name: api: url: ids: {
    apiKey = {
      key = secret name;
      models = ids;
      apis.${api}.base-url = url;
    };
  };
  binding = name: auth: {
    inherit auth;
    binding = "main/${name}";
  };
  route = credential: {inherit credential;};
  goOffers = lib.filterAttrs (id: _: !lib.elem catalog.defaults.models.${id}.maker ["anthropic" "openai" "zhipu"]) catalog.opencodeGo.models;
  goProvider = (import ../../cliproxyapi/lib/providers.nix {inherit lib;}).opencodeGo goOffers;
  # Hand-written inventory of every extracted Go offer remaining after the
  # operator's maker exclusions. A dropped model (including iceman) must fail.
  expectedGoModels = [
    "beam-free"
    "deepseek-v4-pro"
    "deepseek-v4.1-flash"
    "gemini-4-argon"
    "grok-4.7"
    "hy3"
    "hy4"
    "hy4-preview"
    "iceman-contributor-free"
    "kimi-k2.7-code"
    "kimi-k3"
    "kimi-k3.1-pro"
    "longcat-2.0"
    "longcat-2.5-free"
    "mimo-v2.6-flash"
    "mimo-v2.6-pro"
    "minimax-m3"
    "minimax-m3.1-flash"
    "muse-spark-1.2-contributor"
    "muse-spark-1.3-contributor"
    "qwen3.7-plus"
    "qwen3.8-flash"
    "qwen3.8-max"
    "step-5-preview"
  ];
  operatorRoutes = names:
    lib.concatMap (name:
      if name == "go"
      then
        map (api: {
          credential = name;
          inherit api;
        }) (builtins.attrNames goProvider.apis)
      else [(route name)])
    names;
  # All extracted Go offers travel through their native CPA APIs. Exclusions
  # use shared maker identities, without a package-wide maker exclusion.
  operator.ai = {
    catalog = {
      pools = {
        anthropic-api.credentials.metered = binding "api" "apiKey";
        claude.credentials.subscription = binding "claude" "oauth";
        codex.credentials.subscription = binding "codex" "oauth";
        opencode-go.credentials.subscription = binding "go" "apiKey";
        z-ai.credentials.subscription = binding "zai" "apiKey";
      };
      runtimes = {
        claude.pools = ["claude" "opencode-go" "z-ai"];
        codex.pools = ["anthropic-api" "codex" "opencode-go" "z-ai"];
      };
    };
    claude = {
      enable = true;
      settings.inference = {
        instance = "main";
        clientKey = "claude";
      };
    };
    codex = {
      enable = true;
      settings.inference = {
        instance = "main";
        clientKey = "codex";
      };
    };
    cliproxyapi.instances.main = {
      credentials = {
        api = key "api" "anthropic" "https://api.anthropic.com" (builtins.attrNames (lib.filterAttrs (_: identity: identity.maker == "anthropic") catalog.defaults.models));
        claude.oauth = {
          account = secret "claude";
          vendor = "claude";
        };
        codex.oauth = {
          account = secret "codex";
          vendor = "codex";
        };
        go = {
          vendor = "opencode-go";
          apiKey = {
            key = secret "go";
            inherit (goProvider) apis;
          };
        };
        zai = key "zai" "chat" "https://zai.invalid/v1" catalog.zAi.models;
      };
      clientKeys = {
        claude = {
          key = secret "claude-client";
          routes = operatorRoutes ["api" "claude" "go" "zai"];
        };
        codex = {
          key = secret "codex-client";
          routes = operatorRoutes ["api" "claude" "codex" "go" "zai"];
        };
      };
    };
    programs.delegate-routing = {
      enable = true;
      skill.entries."Graph fixture".text = "{families}";
    };
  };
  row = name: actual: expected: {inherit name actual expected;};
  moduleRows = backend: evaluate: let
    # Removing the module assertion must fail even if the pure resolver still
    # reports overlap. Read assertions without forcing a checked projection.
    overlap =
      (evaluate {
        ai.catalog = {
          models = identityModels;
          pools = {
            a.models = ["gpt"];
            b.models = ["go-gpt"];
          };
          runtimes.codex.pools = ["b" "a"];
        };
      }).config;
    split =
      (evaluate {
        ai = {
          catalog.models = identityModels;
          cliproxyapi.instances.split = {
            credentials = {
              a.apiKey = {
                apis = {
                  anthropic = {
                    base-url = "https://split.invalid/anthropic";
                    models = ["other"];
                  };
                  chat = {
                    base-url = "https://split.invalid/chat";
                    models = ["gpt"];
                  };
                };
                key = secret "split";
              };
              b = key "other" "chat" "https://other.invalid/chat" ["other"];
            };
            clientKeys.client = {
              key = secret "split-client";
              routes = [
                {
                  credential = "a";
                  api = "chat";
                }
                (route "b")
              ];
            };
          };
        };
      }).config.ai.catalog.resolved;
    cfg = (evaluate operator).config;
    passthroughCfg =
      (evaluate (lib.recursiveUpdate operator {
        ai.cliproxyapi.instances.main = {
          credentials.structured.apiKey = {
            key = secret "structured";
            apis.passthrough = {
              base-url = "https://structured.invalid";
              models = [
                {
                  name = "gpt";
                  alias = "decision";
                }
              ];
              path = "/decision";
            };
          };
          clientKeys.codex.routes = operatorRoutes ["api" "claude" "codex" "go" "zai"] ++ [(route "structured")];
        };
      })).config;
    passthroughGraph = passthroughCfg.ai.catalog.resolved;
    aliasCfg =
      (evaluate (lib.recursiveUpdate operator {
        ai.catalog.models.deepseek-v4-pro = (model "deepseek") // {aliases.go = ["go-deepseek"];};
        ai.cliproxyapi.instances.main = {
          credentials.go = lib.mkForce (key "go" "chat" "https://go.invalid/v1" ["go-deepseek"]);
          clientKeys.claude.routes = map route ["api" "claude" "go" "zai"];
          clientKeys.codex.routes = map route ["api" "claude" "codex" "go" "zai"];
        };
      })).config;
    graph = cfg.ai.catalog.resolved;
    portable = cfg.ai.programs.delegate-routing;
    inherit (portable) families;
    models = lib.mapAttrs (_: entry: entry.models) portable.runtimes;
    techniques = (import ../../delegate-routing/lib/select-families.nix {inherit lib;}).effectiveTechniques cfg;
    skill = cfg.ai.internal.roots.delegate-routing-content.passthru.mkSkill {
      catalog = graph;
      inherit families models techniques;
      inherit (portable) pools skill;
      runtime = "codex";
      picker = {entries = [];};
    };
    manifest = builtins.fromJSON (builtins.readFile skill.manifest);
    cpa = cfg.ai.cliproxyapi.instances.main.settings.access.key-allowlist;
    routePools = lib.unique (map (entry: entry.pool) manifest.routes);
    rules = map (entry: map (rule: {inherit (rule) kind provider;}) entry.credentials) cpa;
  in [
    (row "${backend}: passthrough beside operator pools passes" passthroughGraph.errors [])
    (row "${backend}: passthrough is not a catalog pool" (builtins.attrNames passthroughGraph.pools) ["anthropic-api" "claude" "codex" "opencode-go" "z-ai"])
    (row "${backend}: passthrough grant survives catalog projection"
      (map (entry: entry.provider) (lib.last passthroughCfg.ai.cliproxyapi.instances.main.settings.access.key-allowlist).credentials)
      ["claude" "codex" "claude" "openai-compatible-go" "codex" "openai-compatible-zai" "passthrough-structured"])
    (row "${backend}: module assertion rejects overlap"
      (map (entry: entry.message) (lib.filter (entry: !entry.assertion) overlap.assertions))
      [''ai.catalog: runtime "codex" offers model "gpt" from multiple pools: a, b. Select one pool for this model in this runtime. Reason: duplicate finite offers.''])
    (row "${backend}: selected API avoids false overlap" split.errors [])
    (row "${backend}: selected API owns model" (split.poolFor "cliproxyapi:split/client" "other") "split/b")
    (row "${backend}: operator graph passes" graph.errors [])
    (row "${backend}: runtime reach" graph.runtimes {
      claude = ["claude" "opencode-go" "z-ai"];
      codex = ["anthropic-api" "codex" "opencode-go" "z-ai"];
    })
    (row "${backend}: OAuth remains open" graph.pools.codex.providerCatalogs ["codex"])
    (row "${backend}: full Go offer inventory" graph.pools.opencode-go.models expectedGoModels)
    (row "${backend}: full Go reach on Claude" (lib.filter (id: graph.poolFor "claude" id == "opencode-go") (graph.modelsFor "claude")) expectedGoModels)
    (row "${backend}: full Go reach on Codex" (lib.filter (id: graph.poolFor "codex" id == "opencode-go") (graph.modelsFor "codex")) expectedGoModels)
    (row "${backend}: CPA renders all Go offers"
      (lib.sort builtins.lessThan (lib.concatMap (block: map (model: model.name) block.models)
          (lib.filter (block: block.name == "go") (lib.concatLists (lib.filter builtins.isList (builtins.attrValues cfg.ai.cliproxyapi.instances.main.settings.api-keys))))))
      expectedGoModels)
    (row "${backend}: CPA renders canonical alias"
      (map (entry: {inherit (entry) alias name;}) (lib.findFirst (entry: entry.name == "go") null aliasCfg.ai.cliproxyapi.instances.main.settings.api-keys.openai-compatibility).models)
      [
        {
          name = "go-deepseek";
          alias = "deepseek-v4-pro";
        }
      ])
    (row "${backend}: inference picker uses canonical alias"
      (lib.findFirst (entry: entry.name == "go") null aliasCfg.ai.claude.normalized.settings.inference.credentials).models
      ["deepseek-v4-pro"])
    (row "${backend}: CPA reads graph grants" rules [
      [
        {
          kind = "oauth";
          provider = "claude";
        }
        {
          kind = "apikey";
          provider = "claude";
        }
        {
          kind = "apikey";
          provider = "openai-compatible-go";
        }
        {
          kind = "apikey";
          provider = "codex";
        }
        {
          kind = "apikey";
          provider = "openai-compatible-zai";
        }
      ]
      [
        {
          kind = "apikey";
          provider = "claude";
        }
        {
          kind = "oauth";
          provider = "codex";
        }
        {
          kind = "apikey";
          provider = "claude";
        }
        {
          kind = "apikey";
          provider = "openai-compatible-go";
        }
        {
          kind = "apikey";
          provider = "codex";
        }
        {
          kind = "apikey";
          provider = "openai-compatible-zai";
        }
      ]
    ])
    (row "${backend}: routing manifest reads graph" routePools ["codex"])
    (row "${backend}: routing prose reads graph" (lib.hasInfix "pool codex" (builtins.readFile "${skill}/SKILL.md")) true)
    (row "${backend}: all launch pins are concrete" (lib.all (entry: lib.all (technique: !technique.model.isPattern) entry.techniques) manifest.routes) true)
  ];
  rows =
    [
      (row "finite aliases: exact diagnostic" finite.errors [''ai.catalog: runtime "codex" offers model "gpt" from multiple pools: a, b. Select one pool for this model in this runtime. Reason: duplicate finite offers.''])
      (row "finite aliases: refused projection" (rejected finite) true)
      (row "OAuth plus finite: exact diagnostic" mixed.errors [''ai.catalog: runtime "codex" offers model "gpt" from multiple pools: codex, go. Select one pool for this model in this runtime. Reason: finite offer intersects an open OAuth catalog.''])
      (row "OAuth plus finite: refused projection" (rejected mixed) true)
      (row "same-provider OAuth: exact diagnostic" open.errors [''ai.catalog: runtime "codex" offers model "provider-catalog:codex" from multiple pools: personal, work. Select one pool for this model in this runtime. Reason: the same open OAuth provider catalog is reachable through multiple budgets.''])
      (row "same-provider OAuth: refused projection" (rejected open) true)
      (row "open catalog maker aliases: exact diagnostic" openAliases.errors [''ai.catalog: runtime "codex" offers model "provider-catalog:codex" from multiple pools: personal, work. Select one pool for this model in this runtime. Reason: the same open OAuth provider catalog is reachable through multiple budgets.''])
      (row "future model: maker comparison without prefix" future.errors [''ai.catalog: runtime "codex" offers model "future-openai" from multiple pools: codex, go. Select one pool for this model in this runtime. Reason: finite offer intersects an open OAuth catalog.''])
      (row "disjoint runtime pool" (disjoint.poolFor "codex" "go-gpt") "b")
      (row "multiple credentials remain one budget" (map (credential: credential.pool) (catalog.credentialBindings shared.pools shared.runtimes.codex)) ["one" "one"])
      (row "iceman has its own undisclosed-maker identity" catalog.defaults.models.iceman-contributor-free.maker "iceman")
    ]
    ++ moduleRows "hm" harness.evalHm ++ moduleRows "devenv" harness.evalDevenv;
  # Literal identities reject maker=provider, guessed IDs, ambiguous aliases,
  # and a selected custom model silently retaining an unknown maker.
  nativeGraph = catalog.resolve {};
  customGraph = resolve {
    pools.custom.models = ["other"];
    runtimes.claude.pools = ["custom"];
  };
  unknownGraph = catalog.resolve {
    models.custom = model null;
    pools.custom.models = ["custom"];
    runtimes.claude.pools = ["custom"];
  };
  ambiguousGraph = catalog.resolve {
    models = {
      first = (model "openai") // {aliases.go = ["shared"];};
      second = (model "anthropic") // {aliases.go = ["shared"];};
    };
  };
  identityView = graph: match:
    import ../../delegate-routing/lib/routing-view.nix {
      inherit lib;
      catalog = graph;
      runtime = "claude";
      families.provider.custom = {
        inherit match;
        tier = "strong";
        example = {};
      };
      models.claude = [{families = ["custom"];}];
      picker.entries = [];
      techniques.claude.fixture = {
        enable = true;
        kind = "subagent";
        launchRoute = true;
        modelArg = "--model";
        pinsEffort = true;
        pinsModel = true;
      };
    };
  glmGraph = catalog.resolve {
    pools.zai.models = ["glm-5.3" "glm-5.3-flash"];
    runtimes.claude.pools = ["zai"];
  };
  scopedModel = pattern: (lib.head (lib.head (identityView glmGraph pattern).routes).techniques).model.value;
  identityRows = [
    (row "maker accessor reads known model" (nativeGraph.makerOf "gpt-6.1-sol") "openai")
    (row "maker accessor resolves provider alias" (nativeGraph.makerOf "deepseek/deepseek-v4-pro") "deepseek")
    (row "maker accessor retains unknown offered maker" (unknownGraph.makerOf "custom") null)
    (row "selected custom model requires maker"
      (builtins.tryEval (unknownGraph.modelFor "custom").maker).success
      false)
    (row "maker accessor refuses unregistered model"
      (builtins.tryEval (nativeGraph.makerOf "gpt-999-sol")).success
      false)
    (row "maker accessor refuses overlapping budgets"
      (builtins.tryEval (mixed.makerOf "gpt")).success
      false)
    (row "native Claude maker" (nativeGraph.modelFor "claude-opus-4-6").maker "anthropic")
    (row "native Codex maker" (nativeGraph.modelFor "gpt-6.1-sol").maker "openai")
    (row "GLM maker independent of z.ai billing" (nativeGraph.modelFor "glm-5.3").maker "zhipu")
    # Selectors are the identity-only portion of dcaf19f9 families.nix:81,88;
    # adding their fit/tier/effort presets is deliberately outside this catalog.
    (row "GLM scope excludes Flash" (scopedModel "glm-[0-9]*.[0-9]") "glm-5.3")
    (row "GLM Flash scope selects exact pinned ID" (scopedModel "glm-*-flash") "glm-5.3-flash")
    (row "GLM Flash maker" (nativeGraph.modelFor "glm-5.3-flash").maker "zhipu")
    (row "Go maker independent of serving provider" (nativeGraph.modelFor "deepseek-v4-pro").maker "deepseek")
    (row "Go canonical alias maker" (nativeGraph.modelFor "deepseek/deepseek-v4-pro").maker "deepseek")
    (row "Go alias canonical identity" (nativeGraph.canonical "deepseek/deepseek-v4-pro") "deepseek-v4-pro")
    (row "custom selected model maker" (customGraph.modelFor "other").maker "deepseek")
    (row "routing pins the canonical custom ID"
      (lib.head (lib.head (identityView customGraph "*").routes).techniques).model.value "other")
    (row "routing refuses selected custom model without maker"
      (builtins.tryEval (builtins.deepSeq (identityView unknownGraph "*").routes true)).success
      false)
    (row "identity records contain no fit or effort policy"
      (builtins.attrNames (nativeGraph.modelFor "gpt-6.1-sol")) ["aliases" "maker" "source"])
    (row "unselected unknown maker retains its offer" (unknownGraph.modelsFor "claude") ["custom"])
    (row "concrete IDs are never guessed"
      (builtins.tryEval (nativeGraph.canonical "gpt-999-sol")).success
      false)
    (row "ambiguous identity aliases refused"
      (builtins.tryEval (ambiguousGraph.modelFor "shared").maker).success
      false)
  ];
  providerLib = import ../../cliproxyapi/lib/providers.nix {inherit lib;};
  fullProvider = providerLib.vendors.opencode-go;
  # Hand-written additions to the existing operator-selected inventory. These
  # offers must remain available to a consumer without the operator's overlaps.
  expectedFullGoModels = lib.sort builtins.lessThan (expectedGoModels
    ++ [
      "claude-haiku-5-5"
      "glm-5.2"
      "glm-5.3"
      "glm-5.3-flash"
      "gpt-5.6-luna"
      "gpt-6-luna"
    ]);
  fullGoRows = backend: evaluate: let
    cfg =
      (evaluate {
        ai = {
          catalog = {
            pools.go.credentials.subscription = {
              auth = "apiKey";
              binding = "full/go";
            };
            runtimes.claude.pools = ["go"];
          };
          cliproxyapi.instances.full = {
            credentials.go = {
              vendor = "opencode-go";
              apiKey.key = secret "full-go";
            };
            clientKeys.client = {
              key = secret "full-client";
              routes = map (api: {
                credential = "go";
                inherit api;
              }) ["anthropic" "chat" "responses"];
            };
          };
        };
      }).config;
    graph = cfg.ai.catalog.resolved;
    rendered = lib.concatLists (lib.filter builtins.isList (builtins.attrValues cfg.ai.cliproxyapi.instances.full.settings.api-keys));
    # The same production routing view used by mkSkill, one exact family per
    # offer so no highest-version selector hides a dropped canonical model.
    view = import ../../delegate-routing/lib/routing-view.nix {
      inherit lib;
      catalog = graph;
      runtime = "claude";
      families.go = lib.genAttrs expectedFullGoModels (id: {
        match = id;
        tier = "strong";
        example = {};
      });
      models.claude = [{vendors = ["go"];}];
      picker.entries = [];
      techniques.claude.fixture = {
        enable = true;
        kind = "subagent";
        launchRoute = true;
        modelArg = "--model";
        pinsEffort = true;
        pinsModel = true;
      };
    };
  in [
    (row "${backend}: full Go defaults pass module assertions" (map (entry: entry.message) (lib.filter (entry: !entry.assertion) cfg.assertions)) [])
    (row "${backend}: full Go defaults pass shared overlap evaluation" graph.errors [])
    (row "${backend}: CPA full Go inventory"
      (lib.sort builtins.lessThan (lib.concatMap (block: map (entry: entry.name) block.models) rendered))
      expectedFullGoModels)
    (row "${backend}: shared graph full Go inventory" graph.pools.go.models expectedFullGoModels)
    (row "${backend}: routing full Go canonical pins"
      (lib.sort builtins.lessThan (map (route: (lib.head route.techniques).model.value) view.routes))
      expectedFullGoModels)
    (row "${backend}: routing full Go budget identities" (lib.unique (map (route: route.pool) view.routes)) ["go"])
  ];
  providerRows =
    [
      (row "full Go inventory includes native guidance makers"
        (lib.sort builtins.lessThan (lib.concatMap (api: api.models) (builtins.attrValues fullProvider.apis)))
        expectedFullGoModels)
      (row "every extracted Go canonical alias resolves to its offer"
        (map (id: nativeGraph.canonical (catalog.opencodeGo.models.${id}.canonical_id or id)) expectedFullGoModels)
        expectedFullGoModels)
      (row "Go messages native placement" fullProvider.apis.anthropic.models ["claude-haiku-5-5" "minimax-m3" "qwen3.7-plus" "qwen3.8-flash" "qwen3.8-max"])
      (row "Go Responses native placement" fullProvider.apis.responses.models ["gpt-5.6-luna" "gpt-6-luna" "grok-4.7" "muse-spark-1.2-contributor" "muse-spark-1.3-contributor"])
      (row "Go messages base URL removes executor suffix" fullProvider.apis.anthropic.base-url "https://opencode.ai/inference/go/anthropic")
      (row "every extracted Go offer has its evidence-backed maker"
        (map (id: (nativeGraph.modelFor id).maker) expectedFullGoModels)
        ["reflection" "anthropic" "deepseek" "deepseek" "google" "zhipu" "zhipu" "zhipu" "openai" "openai" "xai" "tencent" "tencent" "tencent" "iceman" "moonshot" "moonshot" "moonshot" "meituan" "meituan" "xiaomi" "xiaomi" "minimax" "minimax" "meta" "meta" "alibaba" "alibaba" "alibaba" "stepfun"])
      (row "Go provider namespace is not its model maker" (nativeGraph.modelFor "moonshotai/kimi-k3").maker "moonshot")
      (row "Go versioned provider alias resolves exactly" (nativeGraph.canonical "deepseek/deepseek-v4.1-flash-1017") "deepseek-v4.1-flash")
      (row "Go unknown canonical alias refused"
        (builtins.tryEval (nativeGraph.canonical "moonshotai/kimi-unknown")).success
        false)
      (row "Go native maker identities"
        (map (id: (nativeGraph.modelFor id).maker) ["claude-haiku-5-5" "glm-5.3" "gpt-6-luna"]) ["anthropic" "zhipu" "openai"])
    ]
    ++ fullGoRows "hm" harness.evalHm ++ fullGoRows "devenv" harness.evalDevenv;
  providerData = pkgs.writeText "ai-catalog-provider-offers.json" (builtins.toJSON providerRows);
  nativeData = pkgs.writeText "ai-catalog-native-models.json" (builtins.toJSON identityRows);
  data = pkgs.writeText "ai-catalog-runtime-reach.json" (builtins.toJSON rows);
in {
  checks = lib.mapAttrs (name: assertions:
    pkgs.runCommand name {nativeBuildInputs = [pkgs.python3] ++ lib.optional (name == "ai-catalog-provider-offers") pkgs.nix;} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 -I - ${assertions} > "$out" <<'PYTHON'
      import json, sys
      rows = json.load(open(sys.argv[1]))
      assert rows, "empty catalog check"
      for row in rows:
          assert row["actual"] == row["expected"], row
          print("PASS:", row["name"])
      print("PASS:", len(rows), "labelled catalog assertions")
      PYTHON
      ${lib.optionalString (name == "ai-catalog-provider-offers") ''
        # tryEval alone could accept an unrelated evaluation failure. Require
        # the shared resolver's literal unknown-alias error as well.
        if nix-instantiate --eval --strict --store dummy:// --expr '
          let catalog = import ${../lib/catalog/resolve.nix} {
            lib = import ${pkgs.path}/lib;
          }; in (catalog.resolve { models = {}; providers = {}; }).canonical "moonshotai/kimi-unknown"
        ' > "$TMPDIR/alias.out" 2> "$TMPDIR/alias.err"; then
          echo "FAIL: unknown canonical alias accepted" >&2
          exit 1
        fi
        ${pkgs.gnugrep}/bin/grep -F 'ai.catalog: unknown model "moonshotai/kimi-unknown".' "$TMPDIR/alias.err"
        echo 'PASS: literal unknown canonical alias diagnostic' >> "$out"
      ''}
      cat "$out"
    '') {
    ai-catalog-native-models = nativeData;
    ai-catalog-provider-offers = providerData;
    ai-catalog-runtime-reach = data;
  };
}
