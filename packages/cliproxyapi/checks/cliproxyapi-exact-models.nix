{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  exact = import ../lib/exact-models.nix {inherit lib;};
  redact = import ../../../lib/redact {inherit lib;};
  readCatalog = import ../lib/oauth-catalog.nix {inherit lib;};
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) get load;
  rawCatalog = get (load {dir = ../extracted;}).aggregate "models";
  validCatalog = raw: (builtins.tryEval (builtins.deepSeq (readCatalog raw) true)).success;
  login = {
    oauth = {
      authFile = "claude.json";
      vendor = "claude";
    };
    models = [(lib.head exact.catalogs.claude)];
  };
  apiKey.apiKey = {
    key = redact.file "/run/secrets/upstream";
    models = ["glm-5.3" "glm-flash"];
    apis.chat.base-url = "https://example.invalid/v1";
  };
  base = {
    exactModels = true;
    credentials = {
      personal = login;
      upstream = apiKey;
    };
  };
  evaluate = backend: instance: let
    evaluated = (
      if backend == "hm"
      then evalHm
      else evalDevenv
    ) {ai.cliproxyapi.instances.main = instance;};
  in {
    inherit (evaluated) config;
    content = evaluated.config.ai.services.cliproxyapi-main.files.config.content;
    assertions = lib.all (item: item.assertion) evaluated.config.assertions;
  };
  accepts = backend: instance: let
    attempt = builtins.tryEval (let result = evaluate backend instance; in builtins.deepSeq result.content result.assertions);
  in
    attempt.success && attempt.value;
  # CPA's Claude/Codex families fold IDs within a single selected list.
  native = api: models: excludedModels:
    base
    // {
      credentials =
        base.credentials
        // {
          upstream = {
            inherit excludedModels;
            apiKey =
              apiKey.apiKey
              // {
                inherit models;
                apis.${api}.base-url = "https://example.invalid/v1";
              };
          };
        };
    };
  rawBlock = family: models: {
    api-keys.${family} = [
      {
        name = "raw";
        base-url = "https://raw.invalid/v1";
        keys = [{api-key = redact.file "/run/secrets/raw";}];
        inherit models;
      }
    ];
  };
  rawSettings = [
    (rawBlock "claude" [])
    (rawBlock "codex" [])
    (rawBlock "openai-compatibility" [{name = "auto";}])
    {oauth.excluded-models.claude = ["*"];}
    {oauth.excluded-models.claude = login.models;}
  ];
  variants = {
    "api-key-exclusion" = {
      instance = lib.recursiveUpdate base {credentials.upstream.excludedModels = ["glm-flash"];};
      valid = true;
    };
    "api-key-typo" = {
      instance = lib.recursiveUpdate base {credentials.upstream.excludedModels = ["missing"];};
      valid = false;
    };
    "codex-models" = {
      instance = lib.recursiveUpdate base {
        credentials.personal = {
          oauth.vendor = "codex";
          models = [(lib.head exact.catalogs.codex)];
        };
      };
      valid = true;
    };
    "empty-api-key-result" = {
      instance = lib.recursiveUpdate base {credentials.upstream.excludedModels = apiKey.apiKey.models;};
      valid = false;
    };
    "empty-list" = {
      instance = lib.recursiveUpdate base {credentials.personal.models = [];};
      valid = false;
    };
    "empty-oauth-result" = {
      instance = lib.recursiveUpdate base {
        credentials.personal = {
          models = null;
          excludedModels = exact.catalogs.claude;
        };
      };
      valid = false;
    };
    "equal-vendor-sets" = {
      instance = lib.recursiveUpdate base {
        credentials.second = {
          oauth = {
            authFile = "second.json";
            vendor = "claude";
          };
          excludedModels = lib.subtractLists login.models exact.catalogs.claude;
        };
      };
      valid = true;
    };
    "merged-empty-exclusions" = {
      instance = lib.recursiveUpdate base {
        credentials.personal = {
          models = null;
          excludedModels = [(lib.mkIf false "missing")];
        };
      };
      valid = false;
    };
    "merged-empty-models" = {
      instance = lib.recursiveUpdate base {credentials.personal.models = [(lib.mkIf false "missing")];};
      valid = false;
    };
    "oauth-excluded-typo" = {
      instance = lib.recursiveUpdate base {
        credentials.personal = {
          models = null;
          excludedModels = ["missing"];
        };
      };
      valid = false;
    };
    "oauth-exclusion" = {
      instance = lib.recursiveUpdate base {
        credentials.personal = {
          models = null;
          excludedModels = [(lib.head exact.catalogs.claude)];
        };
      };
      valid = true;
    };
    "oauth-typo" = {
      instance = lib.recursiveUpdate base {credentials.personal.models = ["missing"];};
      valid = false;
    };
    "unequal-vendor-sets" = {
      instance = lib.recursiveUpdate base {credentials.second = login // {models = lib.tail exact.catalogs.claude;};};
      valid = false;
    };
    "valid" = {
      instance = base;
      valid = true;
    };
    "xor-both" = {
      instance = lib.recursiveUpdate base {credentials.personal.excludedModels = [(lib.last exact.catalogs.claude)];};
      valid = false;
    };
    "xor-neither" = {
      instance = lib.recursiveUpdate base {credentials.personal.models = null;};
      valid = false;
    };
  };
  refusedSettings =
    [
      {client.codex.optimize-multi-agent-v2 = true;}
      {management.secret-key = redact.file "/run/secrets/management";}
      {models.catalog = "/catalog.json";}
      {models.codex-catalog = "/catalog.json";}
      {models.devin-catalog = "/catalog.json";}
      {multimedia.disable-image-generation = false;}
      {
        oauth.model-alias.claude = [
          {
            name = "source";
            alias = "target";
          }
        ];
      }
      {oauth.providers.antigravity.antigravity-credits = true;}
      {plugins.enabled = true;}
      {
        requests.payload.override = [
          {
            models = [{name = "source";}];
            params.model = "target";
          }
        ];
      }
      {routing.force-model-prefix = true;}
      {upstream.claude.disable-claude-cloak-mode = false;}
      {upstream.claude.disable-cloaking-model-list = false;}
    ]
    ++ map (key: {api-keys.claude = [{${key} = "rewrite";}];}) ["prefix"]
    ++ [
      {api-keys.claude = [{keys = [{cloak = {};}];}];}
      {api-keys.claude = [{keys = [{cloak.mode = "always";}];}];}
      {
        api-keys.claude = [
          {
            models = [
              {
                name = "source";
                alias = "target";
              }
            ];
          }
        ];
      }
      {api-keys.gemini = [{keys = [{api-key = redact.file "/run/secrets/gemini";}];}];}
      {home.enabled = true;}
    ];
  checksFor = backend: let
    result = evaluate backend (lib.recursiveUpdate base {credentials.upstream.excludedModels = ["glm-flash"];});
    rendered = builtins.fromJSON result.content;
    # Independent literal expectations: deleting any one forced switch fails.
    switches =
      rendered.client.codex.optimize-multi-agent-v2
      == false
      && rendered.multimedia.disable-image-generation == true
      && rendered.oauth.model-alias == {}
      && rendered.oauth.providers.antigravity.antigravity-credits == false
      && rendered.plugins.enabled == false
      && rendered.requests.payload == {}
      && rendered.routing.force-model-prefix == false
      && rendered.upstream.claude.disable-claude-cloak-mode == true
      && rendered.upstream.claude.disable-cloaking-model-list == true;
    ordered = builtins.fromJSON (evaluate backend (lib.recursiveUpdate base {credentials.upstream.apiKey.models = ["z" "A"];})).content;
    legacy = base // {exactModels = false;};
    legacyDocument = {
      api-keys.openai-compatibility = [
        {
          name = "upstream";
          base-url = "https://example.invalid/v1";
          keys = [{api-key = "{$CLIPROXYAPI_API_KEYS_OPENAI_COMPATIBILITY_0_KEYS_0_API_KEY}";}];
          models = map (name: {inherit name;}) apiKey.apiKey.models;
        }
      ];
      management.disable-auto-update-panel = true;
      oauth.auth-dir =
        (
          if backend == "hm"
          then "/home/test/.local/state"
          else "/tmp/devenv-state"
        )
        + "/cliproxyapi/main/auth";
      server = {
        host = "127.0.0.1";
        port = 8317;
      };
    };
  in {
    "module-cpa-exact-models-launcher-${backend}" = pkgs.runCommand "cpa-exact-models-launcher-${backend}" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      script=${lib.head result.config.ai.services.cliproxyapi-main.command}
      ${pkgs.gnugrep}/bin/grep -F -- '--config "$CPA_CONFIG" --local-model' "$script"
      ${pkgs.gnugrep}/bin/grep -F 'exact-models-scan.py' "$script"
      if ${pkgs.gnugrep}/bin/grep -F -- '-password' "$script"; then exit 1; fi
      touch "$out"
    '';
    "module-cpa-exact-models-${backend}" = mkTest "cpa-exact-models-${backend}" (
      switches
      && validCatalog rawCatalog
      && !(validCatalog (rawCatalog // {claude = [];}))
      && !(validCatalog (rawCatalog // {claude = [{id = 1;}];}))
      && result.assertions
      && rendered.api-keys.openai-compatibility
      == [
        {
          name = "upstream";
          base-url = "https://example.invalid/v1";
          keys = [{api-key = "{$CLIPROXYAPI_API_KEYS_OPENAI_COMPATIBILITY_0_KEYS_0_API_KEY}";}];
          models = [{name = "glm-5.3";}];
        }
      ]
      && (lib.head ordered.api-keys.openai-compatibility).models == [{name = "z";} {name = "A";}]
      && rendered.oauth.excluded-models.claude == lib.subtractLists login.models exact.catalogs.claude
      # Unset and explicit false must render byte-identically, including named credentials.
      && (evaluate backend legacy).content == builtins.toJSON legacyDocument
      && (evaluate backend legacy).content == (evaluate backend (builtins.removeAttrs legacy ["exactModels"])).content
      && lib.all (row: accepts backend row.instance == row.valid) (builtins.attrValues variants)
      && lib.all (settings:
        !(accepts backend (base // {inherit settings;}))
        && accepts backend (base
          // {
            inherit settings;
            exactModels = false;
          }))
      rawSettings
      && lib.all (
        api:
          !(accepts backend (native api ["M" "m"] null))
          && accepts backend (native api ["M" "n"] null)
          && accepts backend (native api ["M" "m"] ["m"])
          && (lib.head
            (builtins.fromJSON
              (evaluate backend (native api ["M" "n"] null)).content).api-keys.${
              if api == "anthropic"
              then "claude"
              else "codex"
            }).models
          == [{name = "M";} {name = "n";}]
      ) ["anthropic" "responses"]
      && accepts backend (native "chat" ["M" "m"] null)
      && lib.all (settings: !(accepts backend (base // {inherit settings;}))) refusedSettings
      && !(accepts backend (base // {fetchModelCatalogs = true;}))
      && lib.all (vendor: !(accepts backend (lib.recursiveUpdate base {credentials.personal.oauth.vendor = vendor;}))) ["antigravity" "gemini" "kimi" "meta" "xai"]
      && lib.all (name: !(accepts backend (lib.recursiveUpdate base {credentials.upstream.apiKey.models = [name];}))) ["" "auto" "m(high)" "models/m" "m*" "claude-fable-5-dd-m" "m " "M\né"]
      && accepts backend (lib.recursiveUpdate base {credentials.upstream.apiKey.models = ["M-v1.2:exact_+"];})
    );
  };
in {
  checks =
    checksFor "devenv"
    // checksFor "hm"
    // {
      cliproxyapi-exact-models-scan = pkgs.runCommand "cliproxyapi-exact-models-scan" {nativeBuildInputs = [pkgs.python3];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 ${./exact_models_scan_test.py} ${../lib/exact-models-scan.py}
        touch "$out"
      '';
    };
}
