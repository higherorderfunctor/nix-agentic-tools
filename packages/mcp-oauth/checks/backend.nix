{
  harness,
  lib,
}: let
  redact = import ../../../lib/redact {inherit lib;};
  mountedOwner = (import ../lib/mount.nix {inherit lib;}).mkOAuthMount {
    owner = "sample";
    profile = {
      authorizeUrl = "https://identity.example/authorize";
      extraScopes = ["keys:read"];
      loginLifetimeDays = 30;
      name = "sample";
      scopes = ["data:read"];
      tokenUrl = "https://identity.example/token";
    };
  };
in {
  account = {
    clientId = redact.file "/run/secrets/oauth-id";
    clientSecret = redact.file "/run/secrets/oauth-secret";
    provider = {
      authorizeUrl = "https://identity.example/authorize";
      tokenUrl = "https://identity.example/token";
    };
    scopes = ["data:read" "profile:read"];
  };
  evaluate = backend: extra:
    (
      if backend == "hm"
      then harness.evalHm
      else harness.evalDevenv
    )
    (lib.recursiveUpdate
      (
        if backend == "hm"
        then {xdg.stateHome = "/tmp/oauth-hm";}
        else {devenv.state = "/tmp/oauth-project";}
      )
      extra);
  mounted = backend: extra:
    (
      if backend == "hm"
      then harness.evalHmModules
      else harness.evalDevenvModules
    ) [
      mountedOwner.module
      {config = extra;}
      {
        options.ai.sample.instances = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options.enable = lib.mkEnableOption "sample instance";
          });
        };
        config =
          {
            ai.sample.instances = {
              disabled.enable = false;
              personal = {
                enable = true;
                oauth = {
                  clientId = redact.file "/run/secrets/personal-id";
                  clientSecret = redact.file "/run/secrets/personal-secret";
                };
              };
              work = {
                enable = true;
                oauth = {
                  clientId = redact.file "/run/secrets/work-id";
                  clientSecret = redact.file "/run/secrets/work-secret";
                  scopes = ["override:read"];
                };
              };
            };
            ai.mcp-oauth.accounts.unrelated = {
              clientId = redact.file "/run/secrets/other-id";
              clientSecret = redact.file "/run/secrets/other-secret";
              provider = {
                authorizeUrl = "https://other.example/authorize";
                tokenUrl = "https://other.example/token";
              };
              scopes = ["other:read"];
            };
          }
          // (
            if backend == "hm"
            then {xdg.stateHome = "/tmp/mounted-hm";}
            else {devenv.state = "/tmp/mounted-project";}
          );
      }
    ];
}
