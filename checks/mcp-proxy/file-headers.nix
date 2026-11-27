{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
  proxy = import ../../lib/ai/mcpProxy.nix {inherit lib pkgs;};
  header = {
    file = "/TOKEN";
    prefix = "Bearer ";
  };
  declared = {
    Authorization = header;
    "X-Token" = {file = "/SECOND";};
  };
  evaluate = definitions:
    (lib.evalModules {
      modules =
        [
          ../../lib/ai/mcpServer/commonSchema.nix
          {proxy.port = 19591;}
        ]
        ++ map (headers: {proxy = {inherit headers;};}) definitions;
    }).config.proxy.headers;
  readHeader = field: value: (evaluate [{Authorization = header // {${field} = value;};}]).Authorization.${field};
  rejectHeader = field:
    lib.mapAttrs (_: invalid:
      rejectsChange (readHeader field) {
        inherit invalid;
        valid = header.${field};
        expected = header.${field};
      });
  readNames = definitions: builtins.attrNames (evaluate definitions);
  rejectName = invalid:
    rejectsChange (name: readNames [{${name} = header;}]) {
      inherit invalid;
      valid = "Authorization";
      expected = ["Authorization"];
    };
  rejectCollision = definitions:
    rejectsChange (name: readNames (definitions name)) {
      valid = "X-Drop-Me";
      invalid = "authorization";
      expected = ["Authorization" "X-Drop-Me"];
    };
  spec = proxy.specFor "fixture" {
    url = "http://127.0.0.1/endpoint";
    proxy = {
      host = "127.0.0.1";
      port = 19591;
      headers = evaluate [declared];
    };
  };
in {
  checks.module-mcp-proxy-file-headers = assert checkRows "proxy file headers" (
    {
      "file-backed headers do not require startup secrets" = spec.headerSecrets == {};
      "header name cannot contain a space" = rejectName "Bad Header";
      "header name cannot start with a hyphen" = rejectName "-Authorization";
      "header name cannot use a stripped hop header" = rejectName "X-Forwarded-For";
      "header names reject a case collision across definitions" = rejectCollision (name: [{Authorization = header;} {${name} = null;}]);
      "header names reject a case collision within one definition" = rejectCollision (name: [
        {
          Authorization = header;
          ${name} = null;
        }
      ]);
    }
    // rejectHeader "file" {
      "path cannot be relative" = "relative";
      "path cannot be under the store directory" = "${builtins.storeDir}/token";
      "path cannot contain a backslash" = "/bad\\path";
      "path cannot contain a brace" = "/bad{path}";
      "path cannot contain a carriage return" = "/bad\rpath";
      "path cannot contain a newline" = "/bad\npath";
      "path cannot contain a quote" = "/bad\"path";
      "path cannot contain a space" = "/bad path";
      "path cannot contain a traversal segment" = "/run/../nix/store/token";
      "path cannot contain an empty leading segment" = "//nix/store/token";
      "path cannot contain an empty trailing segment" = "/run/token/";
      "path cannot contain an explicit current-directory segment" = "/run/./token";
      "path cannot refer to a store output through string context" = builtins.appendContext "/runtime-token" (builtins.getContext "${pkgs.caddy}");
      "path cannot reference a store output" = "${pkgs.caddy}/token";
    }
    // rejectHeader "prefix" {
      "prefix cannot contain a backslash" = "bad\\";
      "prefix cannot contain a carriage return" = "bad\r";
      "prefix cannot contain a newline" = "bad\n";
      "prefix cannot contain a placeholder" = "{env.SECRET}";
      "prefix cannot contain a quote" = "bad\"";
    }
  );
    pkgs.runCommand "module-mcp-proxy-file-headers" {nativeBuildInputs = [pkgs.python3];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python ${./file-headers.py} ${pkgs.caddy}/bin/caddy ${proxy.caddyfileFor spec}
      touch "$out"
    '';
}
