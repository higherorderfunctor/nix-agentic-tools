# `ai.proxy` core contracts (lib/ai/proxy): selection validation and
# resolution, and the per-runtime override.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiBase evalDevenv evalDevenvModules evalHm evalHmModules mkTest;

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
    # A key without a url and a url without a key each fail with the option
    # path; a valid `url` form passes on both backends. A url carrying a path
    # fails, since every runtime appends its own.
    module-ai-proxy-root-selection-validation = mkTest "ai-proxy-root-selection-validation" (
      failsWith ["ai.proxy.url needs `key`"] (evalHm {ai.proxy.url = "http://127.0.0.1:8317";})
      && failsWith ["ai.proxy.key is set without `url`"] (evalHm {ai.proxy.key.plain = "sk-local";})
      && failsWith ["ai.proxy.url must be the proxy origin only"] (evalHm {
        ai.proxy = {
          url = "http://127.0.0.1:8317/v1";
          key.plain = "sk-local";
        };
      })
      && failsWith ["ai.proxy.key.plain must be"] (evalDevenv {
        ai.proxy = {
          url = "http://127.0.0.1:8317";
          key.plain = "sk local";
        };
      })
      && failedMessages (evalHm {
        ai.proxy = {
          url = "http://[::1]:8317";
          key.file = "/run/secrets/ai-proxy-key";
        };
      })
      == []
      && failedMessages (evalDevenv {
        ai.proxy = {
          url = "http://localhost:8317";
          key.helper = "/run/current-system/sw/bin/proxy-key";
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
          url = "http://127.0.0.1:8317";
          key.plain = "sk-local";
        };
        work = {
          url = "http://127.0.0.1:8318";
          key.file = "/run/secrets/ai-proxy-key";
        };
        keyOnly = {
          ai = {
            proxy = root;
            testapp.proxy.key.plain = "sk-work";
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
