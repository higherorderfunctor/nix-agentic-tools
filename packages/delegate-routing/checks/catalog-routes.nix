# Synthetic production-shaped configurations exercise CPA projection and launch identity refusal.
{
  harness,
  lib,
  ...
}: let
  # Secret references have the production type, but no fixture reads their files.
  redact = import ../../../lib/redact {inherit lib;};
  # Both backend evaluations receive the same instance and runtime options.
  backends = {
    devenv = harness.evalDevenvModules;
    hm = harness.evalHmModules;
  };
  # Model facts are deliberately synthetic, with served spellings shared across vendor scopes.
  identity = maker: {
    inherit maker;
    source = ["synthetic route identity"];
  };
  # Each credential offers two APIs; the client route must pick exactly one.
  key = models: {
    apiKey = {
      key = redact.concat ["synthetic-private-upstream-" (redact.file "/run/secrets/upstream")];
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
        test-alpha-1 = identity "alpha";
        test-alpha-2 = identity "alpha";
        test-beta-1 = identity "beta";
        test-unknown-1 = identity null;
      };
      vendors = {
        finite.models = ["test-alpha-1" "test-unknown-1"];
        wide.maker = "alpha";
        zhipuai.models = lib.mkForce ["test-alpha-1"];
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
        aliased = (key ["short"]) // {vendor = "zhipuai";};
        first = key ["test-alpha-1" "test-unknown-1"];
        filtered = (key ["test-alpha-1" "test-beta-1"]) // {excludeMakers = ["alpha"];};
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
    cliproxyapi.servedModels = {
      other.test-beta-1 = ["short"];
      zhipuai.test-alpha-1 = ["short" "solo"];
      zhipuai.test-alpha-2 = ["test-alpha-1"];
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
          techniques.usage.command = "fixture-reader";
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
      servedModels = config.ai.cliproxyapi.servedModels;
      instances = config.ai.cliproxyapi.instances;
      inferenceInstances = config.ai.internal.inferenceInstances;
      selections = lib.genAttrs ["claude" "codex"] (runtime: config.ai.${runtime}.settings.inference);
    };
  inherit (harness) checkRows rejectsChange;
  # Each property labels the wrong implementation it rejects.
  check = projection: evaluate: let
    result = evaluate [fixture];
    inherit (result) config;
    catalog = config.ai.catalog;
    routes = project config;
    change = extra: (evaluate [fixture extra]).config;
    chat = credential: {
      api = "chat";
      inherit credential;
    };
    # Extra settings must not override the client route choices.
    clientRoutes = extra: choices:
      project (change (lib.recursiveUpdate {
          ai.cliproxyapi.instances.test.clientKeys.one.routes = lib.mkForce choices;
        }
        extra));
    oauth = extra: credential: (clientRoutes extra [{inherit credential;}]).claude;
    overlapping = clientRoutes {} (map chat ["first" "second"]);
    aliasOffers = extra:
      map (lib.getAttrs ["id" "maker" "model"]) (clientRoutes extra [(chat "aliased")]).claude;
    scopedAlias = [
      {
        id = "test-alpha-1";
        maker = "alpha";
        model = "short";
      }
    ];
    selection = import ../lib/select-families.nix {
      inherit lib;
      servedModels = config.ai.cliproxyapi.servedModels;
    };
    validate = selection.validateId catalog;
    content = config.ai.internal.roots.delegate-routing-content;
    args = {
      inherit catalog;
      cpaRoutes = routes;
      inherit (config.ai.cliproxyapi) servedModels;
      inherit (config.ai.programs.delegate-routing) families skill;
      models = lib.mapAttrs (_: settings: settings.models) config.ai.programs.delegate-routing.runtimes;
      runtime = "claude";
      techniques = selection.effectiveTechniques config;
    };
    # routing-view takes launch data only; skill prose goes to the renderer.
    view = extra: import ../lib/routing-view.nix ({inherit lib;} // builtins.removeAttrs args ["skill"] // extra);
    launchPin = extra:
      (lib.head (lib.head (view extra).routes).techniques).model.value;
    agentPin = id: {
      resolvedAgentFiles.alpha = {
        family = args.families.fixture.alpha;
        inherit id;
      };
    };
    broadFamily.families.fixture.alpha = args.families.fixture.alpha // {match = "*";};
    pickerModels = picker:
      map (entry: entry.model)
      (view (broadFamily
        // {
          inherit picker;
          runtime = "codex";
        })).pickerEntries;
    manual = content.mkSkill args;
    text = builtins.readFile "${manual}/SKILL.md";
    moduleText = builtins.readFile "${config.ai.claude.skills.delegate-routing}/SKILL.md";
    credentialUsage = builtins.fromJSON (builtins.readFile ./usage/config/input.json);
    registered = change {
      ai.programs.delegate-routing = {inherit credentialUsage;};
      ai.cliproxyapi.instances.test.clientKeys.one.routes = lib.mkAfter (map chat ["second" "second" "filtered"]);
    };
    # Read the actual skill from each builder; its wrapper points to the shipped manifest.
    delivered = runtime: let
      skill = content.mkSkill (args
        // {
          inherit credentialUsage runtime;
          cpaRoutes = project registered;
        });
    in ["${registered.ai.${runtime}.skills.delegate-routing}/SKILL.md" "${skill}/SKILL.md"];
    # Compare prose independently of the manifest's store context.
    withoutHelper = value: lib.concatStringsSep "<helper>" (builtins.filter builtins.isString (builtins.split "/nix/store/[a-z0-9]+-delegate-routing-plan/bin/delegate-routing-plan" value));
    properties =
      {
        "manual builder diverges from module" = withoutHelper text == withoutHelper moduleText && lib.hasInfix "pinning `test-alpha-1`" text;
      }
      // lib.optionalAttrs projection {
        "ambiguous native alias launches or an unambiguous spelling changes" = rejectsChange (validate null) {
          expected = "solo";
          invalid = "short";
          valid = "solo";
        };
        "concrete route trusts the offer maker instead of the current catalog" = rejectsChange launchPin {
          expected = "test-alpha-1";
          invalid.catalog = catalog // {models = catalog.models // {test-alpha-1 = catalog.models.test-alpha-1 // {maker = null;};};};
          valid = {};
        };
        "explicit agent pin escapes selected client" = rejectsChange (id: launchPin (agentPin id)) {
          expected = "test-alpha-1";
          invalid = "test-beta-1";
          valid = "test-alpha-1";
        };
        "explicit picker pin escapes selected client" = let
          entries = model: [
            {
              inherit model;
              effort = "medium";
              technique = "codex exec";
            }
          ];
        in
          rejectsChange (model: pickerModels {entries = entries model;}) {
            expected = ["test-beta-1"];
            invalid = "test-alpha-1";
            valid = "test-beta-1";
          };
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
        "finite vendor list invents OAuth reach" = oauth {} "finite" == [];
        "inherited picker outside client reach fails or stays selectable" =
          (change {ai.programs.delegate-routing.families.fixture.alpha.match = lib.mkForce "*";}).ai.programs.delegate-routing.runtimes.codex.picker.entries
          == [];
        "maker-wide OAuth loses identities, includes another maker, or missing vendor silently passes" = rejectsChange (extra: map (offer: offer.id) (oauth extra "wide")) {
          expected = ["test-alpha-1" "test-alpha-2"];
          invalid.ai.cliproxyapi.instances.test.credentials.wide.oauth.vendor = lib.mkForce "missing";
          valid = {};
        };
        "native alias launch bypasses the provided agent pin" = launchPin (agentPin "solo" // {cpaRoutes = {};}) == "solo";
        "native launch skips unknown identity validation" = rejectsChange (validate null) {
          expected = "test-alpha-1";
          invalid = "missing";
          valid = "test-alpha-1";
        };
        "overlapping credentials replace the configured family pool" =
          (lib.head
            (view {
              cpaRoutes = overlapping;
              families = lib.recursiveUpdate args.families {fixture.alpha.pools.claude = "configured";};
            }).routes).pool
          == "configured";
        "projection exposes secrets" = !lib.any (secret: lib.hasInfix secret (builtins.toJSON routes)) ["/run/secrets" "synthetic-private-upstream-"];
        "singular credential replaces an unset family pool" = (lib.head (view {}).routes).pool == null;
        "unoffered spelling borrows its offered canonical identity" = rejectsChange (validate (oauth {} "wide")) {
          expected = "test-alpha-1";
          invalid = "solo";
          valid = "test-alpha-1";
        };
        "vendor alias borrows another vendor identity or resolves an ambiguity" = rejectsChange aliasOffers {
          expected = scopedAlias;
          invalid.ai.cliproxyapi.servedModels.zhipuai.test-alpha-2 = ["short"];
          valid = {};
        };
        "vendor alias is rewritten at launch" = validate (clientRoutes {} [(chat "aliased")]).claude "short" == "short";
      };
  in
    assert checkRows "delegate-routing CPA routes" properties;
      lib.concatMap delivered ["claude" "codex"];
in
  check true backends.hm ++ check false backends.devenv
