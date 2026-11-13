{
  lib,
  pkgs,
  ...
}: let
  proxy = import ../../lib/ai/mcpProxy.nix {inherit lib pkgs;};
  header = {
    file = "/TOKEN";
    prefix = "Bearer ";
  };
  declared = {
    Authorization = header;
    "X-Token" = {file = "/SECOND";};
  };
  evaluate = headers:
    (lib.evalModules {
      modules = [
        ../../lib/ai/mcpServer/commonSchema.nix
        {
          proxy = {
            inherit headers;
            port = 19591;
          };
        }
      ];
    }).config.proxy.headers;
  splitCollision =
    (lib.evalModules {
      modules = [
        ../../lib/ai/mcpServer/commonSchema.nix
        {
          proxy = {
            headers.Authorization = header;
            port = 19591;
          };
        }
        {proxy.headers.authorization = null;}
      ];
    }).config.proxy.headers;
  accepts = headers: (builtins.tryEval (builtins.deepSeq (evaluate headers) true)).success;
  badPaths = [(builtins.appendContext "/runtime-token" (builtins.getContext "${pkgs.caddy}")) "${pkgs.caddy}/token" "${builtins.storeDir}/token" "relative" "/run/../nix/store/token" "//nix/store/token" "/run/./token" "/run/token/" "/bad path" "/bad\npath" "/bad\rpath" "/bad{path}" "/bad\"path" "/bad\\path"];
  badPrefixes = ["bad\n" "bad\r" "bad\"" "bad\\" "{env.SECRET}"];
  spec = proxy.specFor "fixture" {
    url = "http://127.0.0.1/endpoint";
    proxy = {
      host = "127.0.0.1";
      port = 19591;
      headers = evaluate declared;
    };
  };
in {
  checks.module-mcp-proxy-file-headers = assert accepts declared;
  assert lib.all (file: !(accepts {Authorization = {inherit file;};})) badPaths;
  assert lib.all (prefix: !(accepts {Authorization = header // {inherit prefix;};})) badPrefixes;
  assert !(accepts {
    Authorization = header;
    authorization = null;
  });
  assert !(accepts {"X-Forwarded-For" = header;});
  assert !(accepts {"Bad Header" = header;});
  assert !(accepts {"-Authorization" = header;});
  assert !(builtins.tryEval (builtins.deepSeq splitCollision true)).success;
  assert spec.headerSecrets == {};
    pkgs.runCommand "module-mcp-proxy-file-headers" {nativeBuildInputs = [pkgs.python3];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python ${./file-headers.py} ${pkgs.caddy}/bin/caddy ${proxy.caddyfileFor spec}
      touch "$out"
    '';
}
