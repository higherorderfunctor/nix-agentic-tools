{
  harness,
  lib,
}: let
  redact = import ../../../lib/redact {inherit lib;};
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
}
