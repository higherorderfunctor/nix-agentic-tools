# Synthetic production-shaped configurations exercise CPA projection and launch identity refusal.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  # Secret references have the production type, but no fixture reads their files.
  redact = import ../../../lib/redact {inherit lib;};
  # Both backend evaluations receive the same instance and runtime options.
  backends = {
    devenv = harness.evalDevenvModules;
    hm = harness.evalHmModules;
  };
  # Model facts are deliberately synthetic, with aliases shared across vendor scopes.
  identity = maker: aliases: {
    inherit aliases maker;
    source = ["synthetic route identity"];
  };
  # Each credential offers two APIs; the client route must pick exactly one.
  key = models: {
    apiKey = {
      key = redact.file "/run/secrets/upstream";
      inherit models;
      apis = {
        anthropic = {
          base-url = "https://fixture.example/anthropic";
          models = ["test-beta-1"];
        };
        chat.base-url = "https://fixture.example/chat";
      };
    };
  };
  # Clients differ in API and credential; overlap is deliberately not exclusive.
  fixture.ai = {
    catalog = {
      models = {
        test-alpha-1 = identity "z-ai" {z-ai = ["short"];};
        test-alpha-2 = identity "z-ai" {};
        test-beta-1 = identity "beta" {other = ["short"];};
        test-unknown-1 = identity null {};
      };
      vendors = {
        finite.models = ["test-alpha-1" "test-unknown-1"];
        wide.maker = "z-ai";
        z-ai.models = lib.mkForce ["test-alpha-1" "test-alpha-2" "test-beta-1" "test-unknown-1"];
      };
    };
    claude = {
      enable = true;
      settings.inference = {
        instance = "test";
        clientKey = "one";
      };
    };
    codex = {
      enable = true;
      settings.inference = {
        instance = "test";
        clientKey = "two";
      };
    };
    cliproxyapi.instances.test = {
      enable = true;
      settings.config-version = 8;
      credentials = {
        aliased = (key ["short"]) // {vendor = "z-ai";};
        first = key ["test-alpha-1" "test-unknown-1"];
        filtered = (key ["test-alpha-1" "test-beta-1"]) // {excludeMakers = ["z-ai"];};
        finite.oauth = {
          vendor = "finite";
          account = redact.file "/run/secrets/finite";
        };
        second = key ["test-alpha-1"];
        wide.oauth = {
          vendor = "wide";
          account = redact.file "/run/secrets/wide";
        };
      };
      clientKeys = {
        one = {
          key = redact.file "/run/secrets/one";
          routes = [
            {
              credential = "first";
              api = "chat";
            }
          ];
        };
        two = {
          key = redact.file "/run/secrets/two";
          routes = [
            {
              credential = "first";
              api = "anthropic";
            }
          ];
        };
      };
    };
    programs.delegate-routing = {
      enable = true;
      skill.entries."Family tables" = {
        after = ["Routing helper"];
        text = "{families}";
      };
      families.fixture.alpha = {
        match = "test-alpha-*";
        tier = "strong";
        useFor = "synthetic fixture";
      };
      runtimes = {
        claude = {
          models = [{families = ["alpha"];}];
        };
        codex = {
          models = [{families = ["alpha"];}];
        };
      };
    };
  };
  # Projection consumes evaluated CPA options, including credential filtering.
  project = config:
    import ../lib/cpa-routes.nix {
      inherit lib;
      inherit (config.ai) catalog;
      instances = config.ai.cliproxyapi.instances;
      inferenceInstances = config.ai.internal.inferenceInstances;
      selections = lib.genAttrs ["claude" "codex"] (runtime: config.ai.${runtime}.settings.inference);
    };
  # A failed deep evaluation proves refusal rather than an unevaluated thunk.
  refuses = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  # All overlap cases select the same explicit chat API.
  chatRoutes = map (credential: {
    inherit credential;
    api = "chat";
  });
  # Each property labels the wrong implementation it rejects.
  check = projection: evaluate: let
    result = evaluate [fixture];
    inherit (result) config;
    catalog = config.ai.catalog;
    routes = project config;
    change = extra: (evaluate [fixture extra]).config;
    clientRoutes = choices: project (change {ai.cliproxyapi.instances.test.clientKeys.one.routes = lib.mkForce choices;});
    oauth = vendor: (clientRoutes [{credential = vendor;}]).claude;
    overlapping = clientRoutes (chatRoutes ["first" "second"]);
    selection = import ../lib/select-families.nix {inherit lib;};
    validate = selection.validateId catalog;
    content = config.ai.internal.roots.delegate-routing-content;
    args = {
      inherit catalog;
      cpaRoutes = routes;
      inherit (config.ai.programs.delegate-routing) families skill;
      models = lib.mapAttrs (_: settings: settings.models) config.ai.programs.delegate-routing.runtimes;
      runtime = "claude";
      techniques = selection.effectiveTechniques config;
    };
    # routing-view takes launch data only; skill prose goes to the renderer.
    view = extra: import ../lib/routing-view.nix ({inherit lib;} // builtins.removeAttrs args ["skill"] // extra);
    pinned = builtins.head (builtins.head (view {}).routes).techniques;
    manual = content.mkSkill args;
    text = builtins.readFile "${manual}/SKILL.md";
    moduleText = builtins.readFile "${config.ai.claude.skills.delegate-routing}/SKILL.md";
    # Compare prose independently of the manifest's store context.
    withoutHelper = value: lib.concatStringsSep "<helper>" (builtins.filter builtins.isString (builtins.split "/nix/store/[a-z0-9]+-delegate-routing-plan/bin/delegate-routing-plan" value));
    # Real module defaults preserve the distinction between omitted and empty bindings.
    firstParty = extra:
      change (lib.recursiveUpdate {
          ai.cliproxyapi.instances.test.credentials.first.vendor = "z-ai";
        }
        extra);
    poolView = configured:
      view {
        cpaRoutes = project configured;
        families = configured.ai.programs.delegate-routing.families;
      };
    poolOf = configured: (lib.head (poolView configured).routes).pool;
    firstPartyProperties = {
      "alias loses first-party credential" =
        poolOf (firstParty {
          ai.cliproxyapi.instances.test.clientKeys.one.routes = lib.mkForce (chatRoutes ["aliased"]);
          ai.programs.delegate-routing.families.fixture.alpha.example.claude = "short";
        })
        == "aliased";
      "ambiguous first-party credentials choose first" =
        poolOf (firstParty {
          ai.cliproxyapi.instances.test = {
            credentials.second.vendor = "z-ai";
            clientKeys.one.routes = lib.mkForce (chatRoutes ["first" "second"]);
          };
        })
        == null;
      "different aliases hide ambiguous first-party credentials" = lib.all (model:
        poolOf (firstParty {
          ai.cliproxyapi.instances.test.clientKeys.one.routes = lib.mkForce (chatRoutes ["aliased" "first"]);
          ai.programs.delegate-routing.families.fixture.alpha.example.claude = model;
        })
        == null) ["short" "test-alpha-1"];
      "empty bindings acquire a default" = poolOf (firstParty {ai.programs.delegate-routing.families.fixture.alpha.pools = {};}) == null;
      "explicit binding loses precedence" = poolOf (firstParty {ai.programs.delegate-routing.families.fixture.alpha.pools.claude = "chosen";}) == "chosen";
      "explicit null acquires a default" = poolOf (firstParty {ai.programs.delegate-routing.families.fixture.alpha.pools.claude = null;}) == null;
      "first-party default missing" = poolOf (firstParty {}) == "first";
      "first-party offer on another client leaks" =
        poolOf (firstParty {
          ai.cliproxyapi.instances.test.clientKeys.one.routes = lib.mkForce (chatRoutes ["second"]);
        })
        == null;
      "multiple models from one credential look ambiguous" = poolOf (firstParty {ai.cliproxyapi.instances.test.credentials.first.apiKey.models = lib.mkForce ["test-alpha-1" "test-alpha-2"];}) == "first";
      "reseller alias hides unique first-party default" =
        poolOf (firstParty {
          ai = {
            catalog.models.test-alpha-1.aliases.opencode-go = ["resold"];
            cliproxyapi.instances.test = {
              credentials.second = {
                apiKey.models = lib.mkForce ["resold"];
                vendor = "opencode-go";
              };
              clientKeys.one.routes = lib.mkForce (chatRoutes ["first" "second"]);
            };
            programs.delegate-routing.families.fixture.alpha.example.claude = "resold";
          };
        })
        == "first";
      "reseller blocks unique first-party default" =
        poolOf (firstParty {
          ai.cliproxyapi.instances.test.clientKeys.one.routes = lib.mkForce (chatRoutes ["first" "second"]);
        })
        == "first";
      "reseller gains a default" = poolOf config == null;
      "synthetic vendor equality requires a hardcoded mapping" =
        (lib.head
          (view {
            catalog = catalog // {models = catalog.models // {test-alpha-1 = identity "synthetic-maker" {};};};
            cpaRoutes.claude = [
              {
                credential = "synthetic-first";
                id = "test-alpha-1";
                maker = "synthetic-maker";
                model = "test-alpha-1";
                vendor = "synthetic-maker";
              }
              {
                credential = "synthetic-reseller";
                id = "test-alpha-1";
                maker = "synthetic-maker";
                model = "test-alpha-1";
                vendor = "reseller";
              }
            ];
          }).routes).pool
        == "synthetic-first";
      "unrelated first-party model supplies default" =
        poolOf (firstParty {
          ai.cliproxyapi.instances.test.credentials.first.apiKey.models = lib.mkForce ["test-beta-1"];
          ai.cliproxyapi.instances.test.clientKeys.one.routes = lib.mkForce (chatRoutes ["first" "second"]);
        })
        == null;
    };
    properties =
      firstPartyProperties
      // {
        "manual builder diverges from module" = withoutHelper text == withoutHelper moduleText && lib.hasInfix "pinning `test-alpha-1`" text;
        "module reach differs from projection" = pinned.model.value == (lib.head routes.claude).model;
        "rendered agent and launch pins differ" = pinned.model.value == "test-alpha-1" && lib.hasInfix "model: \"test-alpha-1\"" config.ai.claude.agents.alpha;
      }
      // lib.optionalAttrs projection {
        "API override ignored" = map (offer: offer.model) routes.codex == ["test-beta-1"];
        "ambiguous vendor alias chooses first identity" = refuses (project (change {
          ai.catalog.models.test-alpha-2.aliases.z-ai = ["short"];
          ai.cliproxyapi.instances.test.clientKeys.one.routes = lib.mkForce (chatRoutes ["aliased"]);
        }));
        "client inherits other API offers" = map (offer: offer.model) routes.claude == ["test-alpha-1" "test-unknown-1"];
        "concrete route bypasses maker validation" =
          refuses
          (view {
            catalog = catalog // {models = catalog.models // {test-alpha-1 = catalog.models.test-alpha-1 // {maker = null;};};};
          }).routes;
        "explicit agent pin escapes selected client" =
          refuses
          (view {
            resolvedAgentFiles.alpha = {
              family = args.families.fixture.alpha;
              id = "test-beta-1";
            };
          }).routes;
        "external URL invents CPA offers" =
          (project (change {
            ai.claude.settings.inference = {
              instance = lib.mkForce null;
              clientKey = lib.mkForce null;
              url = "https://external.example";
              key = redact.file "/run/secrets/external";
            };
          })).claude
          == null;
        "filtered credential regains excluded maker" =
          map (offer: offer.model)
          (clientRoutes [
            {
              credential = "filtered";
              api = "chat";
            }
          ]).claude
          == ["test-beta-1"];
        "finite vendor list invents OAuth reach" = oauth "finite" == [];
        "inherited picker outside client reach throws" = let
          defaults =
            (import ../lib/defaults.nix {
              inherit lib;
              claudeUsageScript = null;
              codexUsageScript = null;
            }).picker.codex.entries;
          inherit (lib.head defaults) model;
          configured = change {ai.programs.delegate-routing.families.fixture.alpha.match = lib.mkForce "*";};
          pickerView = picker:
            view {
              inherit picker;
              runtime = "codex";
              families.fixture.alpha = args.families.fixture.alpha // {match = "*";};
            };
        in
          !lib.any (offer: offer.model == model) routes.codex
          && configured.ai.programs.delegate-routing.runtimes.codex.picker.entries == []
          && (pickerView null).pickerEntries == []
          && refuses (pickerView {entries = defaults;}).pickerEntries;
        "maker-wide OAuth misses synthetic identities" = map (offer: offer.id) (oauth "wide") == ["test-alpha-1" "test-alpha-2"];
        "missing OAuth vendor silently empties reach" = refuses (project (change {
          ai.cliproxyapi.instances.test.credentials.finite.oauth.vendor = lib.mkForce "missing";
          ai.cliproxyapi.instances.test.clientKeys.one.routes = lib.mkForce [{credential = "finite";}];
        }));
        "multiple credentials lose offers or replace family pool" =
          (lib.head
            (view {
              cpaRoutes = overlapping;
              families = lib.recursiveUpdate args.families {fixture.alpha.pools.claude = "configured";};
            }).routes).pool
          == "configured"
          && lib.length overlapping.claude == 3;
        "native known identity refused" = validate null "test-alpha-1" == "test-alpha-1";
        "native launch skips identity validation" = refuses (validate null "missing");
        "null-maker concrete launch succeeds" = refuses (validate routes.claude "test-unknown-1");
        "outside-client concrete launch succeeds" = refuses (validate routes.claude "test-beta-1");
        "projection drops credential or vendor provenance" =
          lib.sort builtins.lessThan (map (offer: offer.credential) overlapping.claude)
          == ["first" "first" "second"]
          && lib.all (offer: offer.vendor == null) overlapping.claude
          && lib.all (offer: offer.credential == "wide" && offer.vendor == "wide") (oauth "wide");
        "projection exposes secrets" = !(lib.hasInfix "/run/secrets" (builtins.toJSON routes));
        "singular credential replaces family pool" = (lib.head (view {}).routes).pool == null;
        "unknown offers disappear" = (lib.last routes.claude).maker == null;
        "unoffered alias borrows another vendor identity" = refuses (validate (oauth "wide") "short");
        "unscoped ambiguous alias chooses first identity" = refuses (validate null "short");
        "vendor alias borrows another vendor" =
          validate
          (clientRoutes [
            {
              credential = "aliased";
              api = "chat";
            }
          ]).claude "short"
          == "short";
      };
  in
    lib.all (name: properties.${name} || throw "delegate-routing CPA routes: ${name}") (builtins.attrNames properties);
  # Delivered helpers must not mistake a CPA credential name for Reader identity.
  helperCases = lib.concatMap (backend:
    map (binding: let
      registered = binding != "unregistered";
      configured =
        (backends.${backend} [
          fixture
          {
            ai = {
              cliproxyapi.instances.test.credentials.first.vendor = "z-ai";
              codex.settings.inference.clientKey = lib.mkForce "one";
              programs.delegate-routing = {
                families.fixture.alpha.pools =
                  if binding == "explicit"
                  then {
                    claude = "first";
                    codex = "first";
                  }
                  else null;
                pools = lib.optionalAttrs registered {
                  first.usage = {
                    runtime = "claude";
                    technique = "fixture-reader";
                  };
                };
                runtimes.claude = {
                  manualExternalDelegates = ["codex"];
                  picker.entries = [
                    {
                      effort = "medium";
                      model = "test-alpha-1";
                      technique = "claude -p";
                    }
                  ];
                  techniques.fixture-reader = {
                    command = "${pkgs.coreutils}/bin/cat ${pkgs.writeText "first-party-reader.json" (builtins.toJSON {
                      account = {
                        auth_index = null;
                        name = "fixture";
                        plan = null;
                      };
                      balances = [];
                      bonuses = [];
                      pool = "fixture";
                      windows = {};
                    })}";
                    kind = "usage";
                  };
                };
              };
            };
          }
        ]).config;
    in {
      inherit backend binding;
      expectedPool =
        if binding == "explicit"
        then "first"
        else null;
      skill = builtins.readFile "${configured.ai.claude.skills.delegate-routing}/SKILL.md";
    }) ["explicit" "registered" "unregistered"]) (builtins.attrNames backends);
in {
  # Synthetic property: rejects invalid unregistered pools and accidental account attribution.
  checks.delegate-routing-first-party-pool-helper =
    pkgs.runCommand "delegate-routing-first-party-pool-helper" {
      cases = builtins.toJSON helperCases;
      passAsFile = ["cases"];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 - <<'PYTHON'
      import json
      import os
      from pathlib import Path
      import re
      import subprocess

      context = Path("context.json").resolve()
      context.write_text(json.dumps({
          "taskSummary": "synthetic first-party pool check",
          "nonInteractive": True,
          "roles": {"writer": {"effort": "medium"}},
          "techniques": [{"efforts": ["medium"], "model": "test-alpha-1", "runtime": "claude", "technique": "Agent with generated agent file"}],
      }))
      for case in json.loads(Path(os.environ["casesPath"]).read_text()):
          wrapper = Path(re.search(r"`(/nix/store/[^` ]+/bin/delegate-routing-plan) --role", case["skill"])[1])
          manifest = json.loads(Path(re.search(r"--manifest (/nix/store/[^\s]+)", wrapper.read_text())[1]).read_text())
          assert [route["pool"] for route in manifest["routes"]] == [case["expectedPool"]], (case["backend"], case["binding"])
          assert [route["pool"] for route in manifest["manualRoutes"]] == [case["expectedPool"]], (case["backend"], case["binding"])
          assert [entry["pool"] for entry in manifest["pickerEntries"]] == [case["expectedPool"]], (case["backend"], case["binding"])
          assert ("pool first" in case["skill"]), case
          result = subprocess.run([str(wrapper), "--role", "writer", "--launch-context", str(context), "--now", "2026-11-15T00:00:00Z"], capture_output=True, text=True)
          output = json.loads(result.stdout)
          assert result.returncode == 0, output
          candidates = output["roles"]["writer"]["candidates"]
          assert len(candidates) == 1, output
          assert candidates[0]["pool"] == case["expectedPool"], output
          print(f"{case['backend']} {case['binding']}: retained one launch; helper pool={case['expectedPool']}")
      PYTHON
      touch "$out"
    '';
  # The combined owner check exercises production options on each backend.
  checks.delegate-routing-cpa-routes = harness.mkTest "delegate-routing-cpa-routes" (check true backends.hm && check false backends.devenv);
}
