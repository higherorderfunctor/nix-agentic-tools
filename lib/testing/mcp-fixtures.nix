{
  lib,
  pkgs,
  ...
}: let
  redact = import ../../lib/redact {inherit lib;};
  # Local credential-injecting reverse proxy (lib/ai/mcpProxy.nix).
  mcpProxyLib = import ../ai/mcpProxy.nix {inherit lib pkgs;};
  # Exercises all three header shapes the renderer must handle: a
  # credential WITH a prefix, a credential without one, and a plain
  # literal string that is not a secret at all — plus a credential url.
  #
  # Deliberately generic. A fixture copied from a real deployment
  # documents that deployment's topology in a public repository, and this
  # one only needs the SHAPES.
  proxySampleServer = {
    type = "http";
    url = redact.file "/run/secrets/upstream-url";
    timeout = 300000;
    proxy = {
      enable = true;
      host = "127.0.0.1";
      port = 9501;
      headers = {
        "X-Api-Key" = redact.concat ["Bearer " (redact.file "/run/secrets/api-key")];
        "X-Route" = "primary";
        "X-Service-Token" = redact.file "/run/secrets/service-token";
        # Null is a DELETION — the client sent it, the upstream must not
        # see it. Included in the shared fixture so every Caddyfile
        # assertion below exercises the third value shape.
        "X-Drop-Me" = null;
      };
    };
  };
in {
  inherit mcpProxyLib proxySampleServer;
}
