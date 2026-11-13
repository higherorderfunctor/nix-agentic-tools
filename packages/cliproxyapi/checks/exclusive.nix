# Real HM/devenv credential shapes exercise opt-in overlap assertions and preserved grants.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  # References are synthetic; no fixture copies account or key values.
  redact = import ../../../lib/redact {inherit lib;};
  # All names are synthetic so catalog releases cannot retire a probe.
  model = maker: aliases: {
    inherit aliases maker;
    source = ["exclusive fixture"];
  };
  # Hand-written identities specify expected canonicalization independently of the checker.
  catalog = {
    models = {
      fixture-a = model "fixture-maker-a" {opencode-go = ["fixture-alias" "fixture-shared"];};
      fixture-b = model "fixture-maker-b" {z-ai = ["fixture-shared" "fixture-a"];};
      fixture-unknown = model null {};
    };
    vendors = {
      fixture-empty.maker = "fixture-maker-empty";
      fixture-login.maker = "fixture-maker-a";
      fixture-no-maker.models = ["fixture-a"];
      fixture-other-empty.maker = "fixture-maker-empty";
      fixture-other-login.maker = "fixture-maker-a";
    };
  };
  # Each API URL is credential-specific, as production allowlist assertions require.
  finite = name: models: {
    apiKey = {
      apis.chat.base-url = "https://${name}.example/v1";
      key = redact.file "/run/secrets/${name}";
      inherit models;
    };
  };
  # OAuth fixtures use the production account/vendor shape.
  oauth = vendor: {
    oauth = {
      inherit vendor;
      account = redact.file "/run/secrets/login";
    };
  };
  # Route helpers omit the API only for sole-API credentials and OAuth.
  route = credential: {inherit credential;};
  # Distinct synthetic client secrets prevent accidental grant coalescing.
  client = name: routes: {
    inherit routes;
    key = redact.file "/run/secrets/client-${name}";
  };
  # Default-false is exercised by omission on both credentials.
  base = {
    clientKeys.main = client "main" [(route "left") (route "right")];
    credentials = {
      left = finite "left" ["fixture-a"];
      right = finite "right" ["fixture-a"];
    };
    enable = true;
    settings.config-version = 8;
  };
  # Updates with apiKey or oauth replace a credential; other updates merge its fields.
  change = update:
    (lib.recursiveUpdate base update)
    // {
      credentials =
        base.credentials
        // lib.mapAttrs (name: credential:
          if credential ? apiKey || credential ? oauth
          then credential
          else (base.credentials.${name} or {}) // credential) (update.credentials or {});
    };
  # Common overlap evidence must include the complete client path and both credential names.
  overlap = ["instances.main.clientKeys.main" "`left`" "`right`" "canonical models" "`fixture-a`"];
  # Passthrough groups deliberately share a model and endpoint, like JSON fallback providers.
  passthrough = name: {
    exclusive = true;
    apiKey = {
      apis.passthrough = {
        base-url = "https://json.example";
        models = [{name = "fixture-a";}];
        path = "/query";
      };
      key = redact.file "/run/secrets/${name}";
    };
  };
  # Multiple APIs expose implementations that inspect all APIs or only one selected API.
  multi =
    (finite "left" ["fixture-b"])
    // {
      exclusive = true;
      apiKey =
        (finite "left" ["fixture-b"]).apiKey
        // {
          apis = {
            anthropic = {
              base-url = "https://left.example/anthropic";
              models = ["fixture-a"];
            };
            chat = {
              base-url = "https://left.example/chat";
              models = ["fixture-b"];
            };
            responses = {
              base-url = "https://left.example/responses";
              models = ["fixture-a"];
            };
          };
        };
    };
  # Every row names the incorrect behavior it rejects; expected diagnostics are literal synthetic facts.
  cases = {
    "ambiguous alias silently picks first" = {
      instance = change {credentials.left = (finite "left" ["fixture-shared"]) // {exclusive = true;};};
      fragments = ["credential `left`" "ambiguous model alias `fixture-shared`" "fixture-a" "fixture-b"];
    };
    # Fails a check that reads exclusive as "exactly one side" or reports the pair twice.
    "both sides exclusive reported once" = {
      instance = change {
        credentials.left.exclusive = true;
        credentials.right.exclusive = true;
      };
      fragments = overlap;
    };
    "canonical id loses to alias" = {
      instance = change {credentials.left.exclusive = true;};
      fragments = overlap;
    };
    "default false rejects fallback" = {instance = base;};
    "disabled instance checked" = {
      instance = change {
        enable = false;
        credentials.left.exclusive = true;
      };
    };
    "disjoint client keys compared" = {
      instance = change {
        credentials.left.exclusive = true;
        clientKeys = {
          main = client "main" [(route "left")];
          other = client "other" [(route "right")];
        };
      };
    };
    "excluded overlap still compared" = {
      instance = change {
        credentials.left =
          (finite "left" ["fixture-a" "fixture-b"])
          // {
            excludeMakers = ["fixture-maker-a"];
            exclusive = true;
          };
      };
    };
    "finite alias compared as raw string" = {
      instance = change {credentials.left = (finite "left" ["fixture-alias"]) // {exclusive = true;};};
      fragments = overlap;
    };
    "finite unknown identity cannot compare" = {
      instance = change {
        credentials = {
          left = (finite "left" ["fixture-unknown"]) // {exclusive = true;};
          right = finite "right" ["fixture-unknown"];
        };
      };
      fragments = ["`left`" "`right`" "canonical models `fixture-unknown`"];
    };
    "finite versus OAuth ignored" = {
      instance = change {
        credentials.left.exclusive = true;
        credentials.right = oauth "fixture-login";
      };
      fragments = overlap;
    };
    "future model omitted from OAuth" = {
      instance = change {
        credentials = {
          left = (finite "left" ["fixture-future"]) // {exclusive = true;};
          right = oauth "fixture-login";
        };
      };
      extra.models.fixture-future = model "fixture-maker-a" {};
      fragments = ["`left`" "`right`" "canonical models `fixture-future`"];
    };
    "missing maker treated as disjoint" = {
      instance = change {
        credentials = {
          left = (finite "left" ["fixture-unknown"]) // {exclusive = true;};
          right = oauth "fixture-login";
        };
      };
      fragments = ["`left`" "`right`" "model `fixture-unknown`" "declare ai.catalog.models.fixture-unknown.maker"];
    };
    "missing OAuth maker becomes empty offer" = {
      instance = change {
        credentials.left.exclusive = true;
        credentials.right = oauth "fixture-no-maker";
      };
      fragments = ["credential `right`" "OAuth vendor `fixture-no-maker`" "declare ai.catalog.vendors.fixture-no-maker.maker"];
    };
    "multiple selected APIs lose anthropic" = {
      instance = change {
        credentials.left = multi;
        clientKeys.main.routes = [
          {
            credential = "left";
            api = "anthropic";
          }
          {
            credential = "left";
            api = "chat";
          }
          (route "right")
        ];
      };
      fragments = overlap;
    };
    "multiple selected APIs lose responses" = {
      instance = change {
        credentials.left = multi;
        clientKeys.main.routes = [
          {
            credential = "left";
            api = "chat";
          }
          {
            credential = "left";
            api = "responses";
          }
          (route "right")
        ];
      };
      fragments = overlap;
    };
    "nonexclusive aliases validated" = {instance = change {credentials.left = finite "left" ["fixture-shared"];};};
    "nonexclusive pair compared when another credential opts in" = {
      instance = change {
        clientKeys.main.routes = [(route "left") (route "right") (route "third")];
        credentials = {
          left.exclusive = true;
          right = finite "right" ["fixture-a" "fixture-b"];
          third = finite "third" ["fixture-b"];
        };
      };
      fragments = overlap;
    };
    "nonexclusive unknown OAuth validated" = {instance = change {credentials.right = oauth "fixture-missing";};};
    "OAuth vendor name exempts same maker" = {
      instance = change {
        credentials = {
          left = (oauth "fixture-login") // {exclusive = true;};
          right = oauth "fixture-other-login";
        };
      };
      fragments = overlap;
    };
    "OAuth symbolic collision without members" = {
      instance = change {
        credentials = {
          left = (oauth "fixture-empty") // {exclusive = true;};
          right = oauth "fixture-other-empty";
        };
      };
    };
    "passthrough exclusive enters conversation" = {instance = change {credentials.left = passthrough "left";};};
    "passthrough fallback refused" = {
      instance = change {
        credentials = {
          left = passthrough "left";
          right = passthrough "right";
        };
      };
    };
    "repeated credential compares with itself" = {
      instance = change {
        credentials.left.exclusive = true;
        clientKeys.main.routes = [(route "left") (route "left")];
      };
    };
    "right opt-in ignored" = {
      instance = change {credentials.right.exclusive = true;};
      fragments = overlap;
    };
    "scoped alias borrows other vendor" = {
      instance = change {
        credentials.left = {
          exclusive = true;
          vendor = "opencode-go";
          apiKey = lib.mkForce (finite "left" ["fixture-shared"]).apiKey;
        };
      };
      fragments = overlap;
    };
    "undeclared finite spelling rejected" = {
      instance = change {
        credentials = {
          left = (finite "left" ["fixture-undeclared"]) // {exclusive = true;};
          right = finite "right" ["fixture-undeclared"];
        };
      };
      fragments = ["canonical models `fixture-undeclared`"];
    };
    "undeclared maker assumed disjoint" = {
      instance = change {
        credentials = {
          left = (finite "left" ["fixture-undeclared"]) // {exclusive = true;};
          right = oauth "fixture-login";
        };
      };
      fragments = ["model `fixture-undeclared`" "declare ai.catalog.models.fixture-undeclared.maker"];
    };
    "unknown OAuth vendor ignored" = {
      instance = change {
        credentials.left.exclusive = true;
        credentials.right = oauth "fixture-missing";
      };
      fragments = ["credential `right`" "OAuth vendor `fixture-missing`" "declare ai.catalog.vendors.fixture-missing.maker"];
    };
    "unresolved route enters overlap check" = {
      instance = change {
        credentials.left.exclusive = true;
        clientKeys.main.routes = [(route "left") (route "missing")];
      };
      routeError = "unknown upstream credential `missing`";
    };
    "unselected APIs compared" = {
      instance = change {
        credentials.left = multi;
        clientKeys.main.routes = [
          {
            credential = "left";
            api = "chat";
          }
          (route "right")
        ];
      };
    };
  };
  # Both owner makers use the same refusal case with independent expected identities.
  ownerCases = lib.mapAttrs' (vendor: maker:
    lib.nameValuePair "owner ${vendor} maker ignored" {
      instance = change {
        credentials = {
          left = (finite "left" ["fixture-owner"]) // {exclusive = true;};
          right = oauth vendor;
        };
      };
      extra.models.fixture-owner = model maker {};
      fragments = ["canonical models `fixture-owner`"];
    }) {
    claude = "anthropic";
    codex = "openai";
  };
  # Both backend harnesses evaluate the same production options and module assertions.
  backends = {
    devenv = harness.evalDevenvModules;
    hm = harness.evalHmModules;
  };
  # Check assertions as well as the pure result: deleting the module caller must fail.
  run = evaluate: label: test: let
    result = evaluate [
      {
        ai = {
          catalog = lib.recursiveUpdate catalog (test.extra or {});
          cliproxyapi.instances.main = test.instance;
        };
      }
    ];
    inherit (result) config;
    instance = config.ai.cliproxyapi.instances.main;
    providers = import ../lib/providers.nix {
      inherit lib;
      catalog = config.ai.catalog;
    };
    checker = import ../lib/exclusive.nix {
      inherit lib providers;
      catalog = config.ai.catalog;
    };
    errors = checker "main" instance;
    failed = map (entry: entry.message) (lib.filter (entry: !entry.assertion) config.assertions);
    matches = fragments: messages: lib.any (message: lib.all (fragment: lib.hasInfix fragment message) fragments) messages;
    fragments = test.fragments or [];
  in
    lib.assertMsg (
      if test ? routeError
      then errors == [] && matches [test.routeError] failed
      else if fragments == []
      then errors == [] && failed == []
      else lib.length errors == 1 && lib.length failed == 1 && matches fragments errors && matches fragments failed
    ) "exclusive case: ${label}";
  # Grant membership is hand specified; changing order alone must not break the check.
  grants = evaluate: let
    cpa = (import ../lib/default.nix {inherit lib;}).cliproxyapi;
    renderedGrants = definition: let
      evaluated = evaluate [{ai.cliproxyapi.instances.main = definition;}];
      rendered = builtins.fromJSON (cpa.render evaluated.config.ai.cliproxyapi.instances.main.settings).content;
    in
      (lib.head rendered.access.key-allowlist).credentials;
    sameMembers = expected: definition: let
      actual = renderedGrants definition;
    in
      lib.length actual == lib.length expected && lib.all (grant: lib.elem grant actual) expected;
    expected = [
      {
        base-urls = ["https://left.example/v1"];
        kind = "apikey";
        provider = "openai-compatible-left";
      }
      {
        base-urls = ["https://right.example/v1"];
        kind = "apikey";
        provider = "openai-compatible-right";
      }
    ];
    passthroughExpected = [
      {
        base-urls = ["https://json.example"];
        kind = "apikey";
        provider = "passthrough-left";
      }
      {
        base-urls = ["https://json.example"];
        kind = "apikey";
        provider = "passthrough-right";
      }
    ];
  in
    sameMembers expected base
    && sameMembers passthroughExpected cases."passthrough fallback refused".instance;
  # One owner check combines table results without maintaining a rendered-order snapshot.
  checks = lib.mapAttrs (backend: evaluate:
    harness.mkTest "cliproxyapi-exclusive-${backend}"
    (lib.all (value: value) (lib.mapAttrsToList (run evaluate) (cases // ownerCases)) && grants evaluate))
  backends;
in {
  checks.cliproxyapi-exclusive = pkgs.linkFarm "cliproxyapi-exclusive" (lib.mapAttrsToList (name: path: {inherit name path;}) checks);
}
