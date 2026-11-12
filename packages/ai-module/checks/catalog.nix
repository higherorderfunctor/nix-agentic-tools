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
  # use shared maker identities, independently of the legacy prefix refusal.
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
      (row "multiple credentials remain one budget" (map (credential: credential.pool) (shared.credentialsFor "codex")) ["one" "one"])
      (row "iceman has its own undisclosed-maker identity" catalog.defaults.models.iceman-contributor-free.maker "iceman")
      (row "native model maker differs from provider" catalog.defaults.models."glm-5.3".maker "zhipu")
    ]
    ++ moduleRows "hm" harness.evalHm ++ moduleRows "devenv" harness.evalDevenv;
  data = pkgs.writeText "ai-catalog-runtime-reach.json" (builtins.toJSON rows);
in {
  checks.ai-catalog-runtime-reach = pkgs.runCommand "ai-catalog-runtime-reach" {nativeBuildInputs = [pkgs.python3];} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    python3 -I - ${data} > "$out" <<'PYTHON'
    import json, sys
    rows = json.load(open(sys.argv[1]))
    assert rows, "empty catalog check"
    for row in rows:
        assert row["actual"] == row["expected"], row
        print("PASS:", row["name"])
    print("PASS:", len(rows), "labelled catalog assertions")
    PYTHON
    cat "$out"
  '';
}
