# `ai.airlock.instances` on both backends: service contract, claims, rendered
# settings, proxy registration, and what selecting an instance gives Claude
# through the shared network surface.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeSettings evalDevenv evalHm mkTest;
  evaluate = backend:
    if backend == "hm"
    then evalHm
    else evalDevenv;
  redact = import ../../../lib/redact {inherit lib;};
  empty = backend: (evaluate backend {}).config;
  enabled = backend:
    (
      evaluate backend {
        ai.airlock.instances.main = {};
      }
    )
    .config;
  enabledWith = backend: settings: (evaluate backend {ai.airlock.instances.main.settings = settings;}).config;
  configured = backend:
    (
      evaluate backend {
        ai.airlock.instances.main.port = 8400;
      }
    )
    .config;
  # A store-backed trust bundle, so the rendered file carries store context.
  interceptionSettings = {
    destinations = ["localhost:443"];
    upstream_roots = "${pkgs.cacert}/etc/ssl/certs/ca-no-trust-rules-bundle.crt";
  };
  runtimeWith = backend: intercepting: nativeEnv:
    (
      evaluate backend {
        ai.airlock.instances.main = {
          port = 18439;
          settings = lib.optionalAttrs intercepting {interception = interceptionSettings;};
          stateDir = "/tmp/airlock-main-runtime-check-${backend}";
        };
        ai.claude = {
          enable = true;
          native.settings.env = nativeEnv;
          package = mockClaude;
          proxy.instance = "main";
        };
      }
    )
    .config;
  runtime = backend: intercepting: runtimeWith backend intercepting {};
  mockClaude = pkgs.writeScriptBin "claude" ''
    #!${pkgs.python3}/bin/python3
    import json, os
    print(json.dumps(os.environ.get("NODE_EXTRA_CA_CERTS")))
  '';
  clientPackage = config:
    lib.findFirst (package: builtins.elem (lib.getName package) ["claude" "claude-launcher"])
    (throw "no Claude package installed") (config.home.packages or config.packages);
  clientLauncher = config: "${clientPackage config}/bin/claude";
  # Claude's own environment, which a selection must leave in place.
  nativeEnv = {
    ANTHROPIC_BASE_URL = "https://native.example.invalid";
  };
  # A configured instance and Claude with its own native environment.
  claudeWith = backend: extra:
    evaluate backend (lib.recursiveUpdate {
        ai = {
          airlock.instances.main.port = 8400;
          claude = {
            enable = true;
            native.settings.env = nativeEnv;
          };
        };
      }
      extra);
  failedAssertions = result:
    map (item: item.message)
    (builtins.filter (item: !item.assertion) result.config.assertions);
  noAirlockActivation = config:
    config.ai.airlock.activation
    == {}
    && !(builtins.any (name: lib.hasPrefix "airlock" name)
      (builtins.attrNames (config.home.activation or config.tasks)));
  serviceContract = backend: let
    config = enabled backend;
    entry = config.ai.services.airlock-main;
    native =
      if backend != "hm"
      then config.processes ? "airlock-main"
      else if pkgs.stdenv.hostPlatform.isLinux
      then config.systemd.user.services ? "airlock-main"
      else
        builtins.any (
          warning:
            warning
            == "ai.services.airlock-main: Home Manager writes services as systemd user units, which this platform lacks; the service is not written"
        )
        config.warnings;
  in
    config.ai.airlock.instances.main.port
    == 8318
    && config.ai.claims.service.airlock-main == ["airlock"]
    && config.ai.claims.port."8318" == ["airlock:airlock-main.ports.main"]
    && entry.enable
    && entry.ports.main == 8318
    && entry.environment == {}
    && builtins.attrNames entry.files == ["config"]
    && entry.files.config
    == {
      content = ''{"listen":"127.0.0.1:8318"}'';
      secrets = {};
      variable = "AIRLOCK_CONFIG";
    }
    && builtins.length entry.command == 1
    && native
    && noAirlockActivation config;
  portDerived = backend: let
    config = configured backend;
    entry = config.ai.services.airlock-main;
  in
    entry.files.config.content
    == ''{"listen":"127.0.0.1:8400"}''
    && entry.ports.main == 8400
    && config.ai.claims.port."8400" == ["airlock:airlock-main.ports.main"];
  listenOverrideRefused = backend:
    !(
      builtins.tryEval (
        builtins.deepSeq
        (evaluate backend {
          ai.airlock.instances.main.settings.listen = "0.0.0.0:8400";
        })
          .config
          .ai
          .services
          .airlock-main
          .files
          .config
        true
      )
    ).success;
  # The services launcher validates placeholders on a context-free copy and
  # keeps the bundle a dependency of the content it renders.
  interceptionRendered = backend: let
    inherit ((enabledWith backend {interception = interceptionSettings;}).ai.services.airlock-main.files.config) content;
  in
    builtins.fromJSON (builtins.unsafeDiscardStringContext content)
    == {
      interception = interceptionSettings;
      listen = "127.0.0.1:8318";
    }
    && builtins.hasContext content;
  # The CA directory belongs to the runtime directory, never to settings.
  invalidInterceptionRefused = backend:
    lib.all (interception:
      !(builtins.tryEval (builtins.deepSeq
        (enabledWith backend {inherit interception;}).ai.services.airlock-main.files.config
        true)).success) [
      {destinations = [443];}
      {
        destinations = ["localhost:443"];
        upstream_roots = 443;
      }
      {
        destinations = ["localhost:443"];
        upstream_roots = "/home/alice/certs/roots.pem";
      }
      {
        ca_directory = "/persistent/ca";
        destinations = ["localhost:443"];
      }
    ];
  launcher = backend: intercepting:
    if backend == "hm"
    then (runtime backend intercepting).systemd.user.services.airlock-main.Service.ExecStart
    else (runtime backend intercepting).processes.airlock-main.exec;
  registered = backend: let
    config = enabled backend;
  in
    config.ai.internal.proxyInstances.main
    == {
      enable = true;
      http = "http://127.0.0.1:8318";
      https = "http://127.0.0.1:8318";
      trust = null;
    }
    && config.ai.claims.proxy-instance.main == ["airlock"];
  # Declaring an instance selects nothing.
  unselected = backend:
    evaluate backend {
      ai = {
        airlock.instances.main = {};
        claude = {
          enable = true;
          native.settings.env = nativeEnv;
        };
      };
    };
  unselectedUntouched = backend: let
    evaluated = unselected backend;
    inherit (claudeSettings evaluated) env;
  in
    evaluated.config.ai.claude.normalized.proxy
    == {
      http = null;
      https = null;
    }
    && lib.intersectAttrs nativeEnv env == nativeEnv
    && !(env ? HTTPS_PROXY);
  # Root and runtime selection share protocol defaults and native delivery.
  external = "http://external.invalid:8080";
  origin = "http://127.0.0.1:8400";
  selectionCases = {
    root = {
      extra.ai.proxy.instance = "main";
      expected = {
        http = origin;
        https = origin;
      };
    };
    root-explicit-http = {
      extra.ai.proxy = {
        http = external;
        instance = "main";
      };
      expected = {
        http = external;
        https = origin;
      };
    };
    runtime = {
      extra.ai.claude.proxy.instance = "main";
      expected = {
        http = origin;
        https = origin;
      };
    };
  };
  selectedCorrectly = backend: test: let
    evaluated = claudeWith backend test.extra;
    expectedEnv = lib.filterAttrs (_: value: value != null) {
      HTTP_PROXY = test.expected.http;
      HTTPS_PROXY = test.expected.https;
      NO_PROXY = "127.0.0.1,localhost,::1";
    };
  in
    failedAssertions evaluated
    == []
    && evaluated.config.ai.claude.normalized.proxy == test.expected
    && claudeSettings evaluated == lib.recursiveUpdate (claudeSettings (unselected backend)) {env = expectedEnv;};
  # Trust is generic proxy metadata and follows the effective instance origin.
  caSelection = backend: extra:
    evaluate backend (lib.recursiveUpdate {
        ai = {
          airlock.instances.main.settings.interception = interceptionSettings;
          claude = {
            enable = true;
            package = mockClaude;
          };
          proxy.instance = "main";
        };
      }
      extra);
  contains = needle: text:
    lib.hasInfix (builtins.unsafeDiscardStringContext needle) (builtins.unsafeDiscardStringContext text);
  missingTrustWarnings = config:
    lib.filter (lib.hasInfix "routing TLS through the intercepting proxy will fail") config.warnings;
  trustIsDelivered = backend: extra: let
    evaluated = caSelection backend extra;
    helper = evaluated.config.ai.internal.proxyInstances.main.trust;
    installed = clientPackage evaluated.config;
  in
    failedAssertions evaluated
    == []
    && lib.getName helper == "airlock-main-trust"
    && contains (lib.getExe helper) installed.buildCommand
    && lib.hasInfix "NODE_EXTRA_CA_CERTS" installed.buildCommand
    && missingTrustWarnings evaluated.config == []
    && !((claudeSettings evaluated).env ? NODE_EXTRA_CA_CERTS);
  # Either protocol can retain the selected origin after the other is replaced.
  trustRetained = backend:
    lib.all (trustIsDelivered backend) (lib.concatMap (path:
      lib.concatMap (field:
        map (value: lib.setAttrByPath (path ++ [field]) value) [null external])
      ["http" "https"])
    [["ai" "proxy"] ["ai" "claude" "proxy"]]);
  trustOmitted = backend:
    lib.all (extra: clientPackage (caSelection backend extra).config == mockClaude) (
      [
        {ai.airlock.instances.main.settings.interception = null;}
        {ai.claude.proxy.instance = null;}
        {
          ai.airlock.instances.other.port = 8500;
          ai.claude.proxy.instance = "other";
        }
      ]
      ++ lib.concatMap (path:
        map (protocols: lib.setAttrByPath path protocols) [
          {
            http = null;
            https = null;
          }
          {
            http = null;
            https = external;
          }
          {
            http = external;
            https = null;
          }
          {
            http = external;
            https = external;
          }
        ])
      [["ai" "proxy"] ["ai" "claude" "proxy"]]
    );
  # Structural rendering omits production base permissions and cannot prove
  # mount behavior; the runtime fixture below uses jailLib.wrap with that base.
  jailSelection = backend: extra:
    caSelection backend (lib.recursiveUpdate {ai.jail.enable = true;} extra);
  jailLib = import ../../../lib/ai/jail {inherit lib;};
  jailMaskText = backend: runtime: extra: let
    evaluated = jailSelection backend extra;
    inherit (evaluated.config.ai.internal) jail;
    profile = evaluated.config.ai.${runtime}.normalized.jail;
    render = jail.extend {
      inherit pkgs;
      additionalCombinators = jail.combinators pkgs;
      basePermissions = [];
    };
  in
    (render "airlock-ca-mask" "${mockClaude}/bin/claude" (c:
        lib.optionals (profile != null && profile.permissions != null) (profile.permissions c))).text;
  jailMasksKey = backend: let
    text = jailMaskText backend "claude" {ai.jail.permissions = c: [(c.mask-path "/user/secret")];};
    # Only the CA mask can satisfy this assertion: trim off the caller mask.
    afterKey = builtins.elemAt (lib.splitString ''realpath -e -- "$_ai_ca_key"'' text) 1;
    beforeCaller = builtins.head (lib.splitString "realpath -e -- /user/secret" afterKey);
  in
    contains ''_ai_dir="$XDG_RUNTIME_DIR"/ai-service-airlock-main'' text
    && contains ''ai-service-$('' text
    && contains ''_ai_ca_key="$_ai_dir"/ca/ca.key'' text
    && contains "cannot jail client: CA key missing at" text
    && contains ''--ro-bind ${pkgs.emptyFile} "$jail_mask"'' beforeCaller
    && contains ''realpath -e -- /user/secret'' text
    && !(contains ''realpath -e -- "$_ai_dir"/ca/ca.pem'' text);
  jailOmitsKeyMask = backend:
    lib.all (extra: !(contains "/ca/ca.key" (jailMaskText backend "claude" extra))) [
      {ai.airlock.instances.main.settings.interception = null;}
      {ai.claude.jail.enable = false;}
      {ai.claude.proxy.instance = null;}
      {
        ai.claude.proxy = {
          http = external;
          https = external;
        };
      }
      {ai.jail.enable = false;}
    ];
  # Removing the shared hook from a runtime without trust delivery must fail.
  codexJailMasksKey = backend: let
    text = jailMaskText backend "codex" {ai.codex.enable = true;};
  in
    contains ''_ai_ca_key="$_ai_dir"/ca/ca.key'' text
    && contains "cannot jail client: CA key missing at" text
    && contains ''realpath -e -- "$_ai_ca_key"'' text;
  # The probe has no trust helper: only the shared Codex jail profile can
  # refuse a missing key and mask the real service's key with the base intact.
  jailProbe = pkgs.writeScriptBin "airlock-jail-probe" ''
    #!${pkgs.python3}/bin/python3
    import pathlib, sys
    ca = pathlib.Path(sys.argv[1]) / "ca"
    assert (ca / "ca.key").read_bytes() == b"", "CA key exposed inside jail"
    assert (ca / "ca.pem").read_bytes().startswith(b"-----BEGIN CERTIFICATE-----")
    print("CA key hidden; certificate readable")
  '';
  jailedPackage = backend: runtime: package: executable:
    jailLib.wrap {
      executables = [executable];
      inherit package pkgs;
      inherit ((jailSelection backend {}).config.ai.internal) jail;
      name = "airlock-${runtime}-fixture";
      profile = (jailSelection backend (lib.optionalAttrs (runtime == "codex") {ai.codex.enable = true;})).config.ai.${runtime}.normalized.jail;
    };
  jailedLauncher = backend: native: "${jailedPackage backend "claude" (clientPackage (runtimeWith backend true native)) "claude"}/bin/claude";
  nativeCaWins = backend: let
    evaluated = caSelection backend {ai.claude.native.settings.env.NODE_EXTRA_CA_CERTS = "/user/ca.pem";};
    installed = clientPackage evaluated.config;
  in
    (claudeSettings evaluated).env.NODE_EXTRA_CA_CERTS
    == "/user/ca.pem"
    && lib.hasInfix "/user/ca.pem" installed.buildCommand
    && !(contains (lib.getExe evaluated.config.ai.internal.proxyInstances.main.trust) installed.buildCommand);
  nullPackageWarnsTrust = backend:
    builtins.any (lib.hasInfix "NODE_EXTRA_CA_CERTS")
    (caSelection backend {ai.claude.package = null;}).config.warnings;
  otherRuntimeSelection = backend: runtime: intercepting:
    (evaluate backend (lib.recursiveUpdate (harness.setEnable runtime true) {
      ai.airlock.instances.main.settings = lib.optionalAttrs intercepting {interception = interceptionSettings;};
      ai.proxy.instance = "main";
    }))
    .config;
  otherRuntimes = ["codex" "copilot" "kimchi" "kiro"];
  otherRuntimesWarn = backend:
    lib.all (runtime: let
      config = otherRuntimeSelection backend runtime true;
      path =
        if runtime == "copilot"
        then "ai.proxy"
        else "ai.${runtime}.proxy";
    in
      missingTrustWarnings config
      == ["${path} selects a TLS-intercepting network proxy for ${runtime}, which does not deliver its CA; routing TLS through the intercepting proxy will fail unless you configure trust yourself."]
      && (runtime
        != "copilot"
        || (
          builtins.any (lib.hasPrefix "ai.proxy is set but ") config.warnings
          && !(builtins.any (lib.hasInfix "ai.copilot.proxy") config.warnings)
        )))
    otherRuntimes;
  opaqueRuntimesDoNotWarn = backend:
    lib.all (runtime: missingTrustWarnings (otherRuntimeSelection backend runtime false) == []) otherRuntimes;
  nativeProxyWins = backend: let
    inherit
      (claudeSettings (claudeWith backend {
        ai.proxy.instance = "main";
        ai.claude.native.settings.env = {
          HTTPS_PROXY = external;
          NO_PROXY = "native.example.invalid";
        };
      }))
      env
      ;
  in
    env.HTTPS_PROXY == external && env.NO_PROXY == "native.example.invalid";
  selectionRefused = backend: scope: disabled: let
    path = ["ai"] ++ lib.optional (scope == "runtime") "claude" ++ ["proxy"];
    name =
      if disabled
      then "main"
      else "missing";
    result = enabled:
      claudeWith backend (lib.recursiveUpdate
        (lib.setAttrByPath (path ++ ["instance"]) name)
        {
          ai.airlock.instances.main.enable = !disabled;
          ai.claude.enable = enabled;
        });
    message = "${lib.showOption path}.instance names `${name}`, which is ${
      if disabled
      then "disabled"
      else "not registered"
    }; registered instances: main.";
  in
    # Inherited invalid selections report only the root; independent runtime
    # selections remain checked even when the runtime is disabled.
    lib.all (enabled: failedAssertions (result enabled) == [message]) [false true];
  inferenceIndependent = backend: let
    evaluated = claudeWith backend {
      ai = {
        cliproxyapi.instances.main = {
          clientKeys.main = {
            key = redact.file "/run/secrets/inference-key";
            routes = [{credential = "login";}];
          };
          credentials.login.oauth = {
            account = redact.file "/run/secrets/inference-account";
            vendor = "claude";
          };
        };
        proxy.instance = "main";
        settings.inference = {
          clientKey = "main";
          instance = "main";
        };
      };
    };
    inherit (evaluated) config;
  in
    failedAssertions evaluated
    == []
    && config.ai.claims.inference-instance.main == ["cliproxyapi"]
    && config.ai.claims.proxy-instance.main == ["airlock"]
    && config.ai.internal.inferenceInstances.main.url == "http://127.0.0.1:8317"
    && config.ai.internal.proxyInstances.main.https == origin
    && (claudeSettings evaluated).env.NO_PROXY == "127.0.0.1,localhost,::1";
  # Named so a failure reports which condition broke.
  conditions = backend:
    {
      "${backend}: Claude trusts the selected intercepting instance at launch" = trustIsDelivered backend {};
      "${backend}: inference and network instance names coexist" = inferenceIndependent backend;
      "${backend}: instances are registered proxies" = registered backend;
      "${backend}: interception renders with its store bundle" = interceptionRendered backend;
      "${backend}: invalid interception is refused" = invalidInterceptionRefused backend;
      "${backend}: jail masks the selected instance key and keeps caller permissions" = !pkgs.stdenv.hostPlatform.isLinux || jailMasksKey backend;
      "${backend}: jail omits the key mask without trust or when disabled" = !pkgs.stdenv.hostPlatform.isLinux || jailOmitsKeyMask backend;
      "${backend}: listen cannot be overridden" = listenOverrideRefused backend;
      "${backend}: native CA wins at launch" = nativeCaWins backend;
      "${backend}: native HTTPS_PROXY and NO_PROXY win" = nativeProxyWins backend;
      "${backend}: no instance by default" =
        (empty backend).ai.airlock.instances
        == {}
        && !(builtins.any (name: lib.hasPrefix "airlock" name)
          (builtins.attrNames ((empty backend).ai.services or {})))
        && noAirlockActivation (empty backend);
      "${backend}: no launcher warns about CA trust" = nullPackageWarnsTrust backend;
      "${backend}: opaque selections do not warn about CA trust" = opaqueRuntimesDoNotWarn backend;
      "${backend}: other runtimes warn about CA trust" = otherRuntimesWarn backend;
      "${backend}: port derives listen" = portDerived backend;
      "${backend}: service contract" = serviceContract backend;
      "${backend}: trust follows effective instance selection" = trustOmitted backend;
      "${backend}: trust remains when either protocol retains the instance origin" = trustRetained backend;
      "${backend}: unselected Claude is untouched" = unselectedUntouched backend;
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      "${backend}: Codex jail masks the key without CA trust delivery" = codexJailMasksKey backend;
    }
    // lib.mapAttrs' (name: test: lib.nameValuePair "${backend}: ${name} selection" (selectedCorrectly backend test)) selectionCases
    // lib.concatMapAttrs (scope: _:
      lib.mapAttrs' (kind: disabled:
        lib.nameValuePair "${backend}: ${scope} ${kind} selection refused"
        (selectionRefused backend scope disabled)) {
        disabled = true;
        unknown = false;
      })
    {
      root = null;
      runtime = null;
    };
  failing = lib.concatMap (backend:
    builtins.attrNames (lib.filterAttrs (_: passed: !passed) (conditions backend)))
  ["devenv" "hm"];
in {
  checks =
    {
      airlock-instances = mkTest "airlock-instances" (
        lib.assertMsg (failing == []) "failing: ${lib.concatStringsSep ", " failing}"
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      airlock-instance-runtime = pkgs.runCommandLocal "airlock-instance-runtime" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        ${pkgs.python3}/bin/python3 ${./airlock-instance-runtime.py} ${lib.getExe pkgs.bubblewrap} \
          ${pkgs.writeText "airlock-runtime-cases.json" (builtins.toJSON (lib.concatMap (backend:
          map (intercepting: {
            inherit backend intercepting;
            client = clientLauncher (runtime backend intercepting);
            clientOverride = clientLauncher (runtimeWith backend intercepting {NODE_EXTRA_CA_CERTS = "/user/ca.pem";});
            config = (runtime backend intercepting).ai.services.airlock-main.files.config.content;
            jailedClient = jailedLauncher backend {};
            jailedNativeClient = jailedLauncher backend {NODE_EXTRA_CA_CERTS = "/user/ca.pem";};
            jailedProbe = "${jailedPackage backend "codex" jailProbe "airlock-jail-probe"}/bin/airlock-jail-probe";
            launcher = launcher backend intercepting;
          }) [false true]) ["hm" "devenv"]))}
        echo "ok — both generated Airlock launchers serve health, keep their CA and deliver it to Claude at startup" >"$out"
      '';
    };
}
