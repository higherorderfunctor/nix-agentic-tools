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
in {
  checks = {
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
    );

    # The root selection reaches a consuming runtime as the resolved endpoint;
    # a runtime selection replaces it whole, on both backends, so a runtime
    # key never pairs with a root url; a runtime's own invalid selection fails
    # with its own option path, even while the runtime is disabled.
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
        && resolved {ai.proxy = root;} == {endpoint = root;}
        && resolved {
          ai = {
            proxy = root;
            testapp.proxy = work;
          };
        }
        == {endpoint = work;}
        && resolved {ai.testapp.proxy = work;} == {endpoint = work;}
        && resolved keyOnly == {endpoint = root;}
        && failsWith ["ai.testapp.proxy.key is set without `url`"] (evalApp backend keyOnly)
        && failsWith ["ai.testapp.proxy.url needs `key`"] (evalApp backend {
          ai.testapp.proxy.url = "http://127.0.0.1:8318";
        }))
      ["devenv" "hm"]
    );
  };
}
