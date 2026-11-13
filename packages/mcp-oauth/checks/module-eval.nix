{
  harness,
  lib,
  pkgs,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  backend = import ./backend.nix {inherit harness lib;};
  inherit (backend) account;
  evaluate = name: accounts: backend.evaluate name {ai.mcp-oauth.accounts = accounts;};
  cases = {
    devenv = {
      accounts = {
        disabled = account // {enable = false;};
        work =
          account
          // {
            provider =
              account.provider
              // {
                extraScopes = ["keys:read"];
                loginLifetimeDays = 30;
              };
          };
      };
      name = "work";
    };
    hm = {
      accounts.personal = account;
      name = "personal";
    };
  };
  configs = lib.mapAttrs (name: case: (evaluate name case.accounts).config) cases;
  proxy = import ./proxy.nix {inherit harness lib pkgs;};
  wrapper = config: name: builtins.head config.ai.services.${name}.command;
  snapshot = config: name: {
    activation = builtins.attrNames config.ai.mcp-oauth.activation;
    claims = config.ai.mcp-oauth.claims.path;
    command = config.ai.services.${name}.command;
    environment = config.ai.services.${name}.environment;
    files = config.ai.mcp-oauth.files;
    restartOnChange = config.ai.services.${name}.restartOnChange;
    services = builtins.attrNames config.ai.mcp-oauth.services;
  };
  # Each bad declaration must fail while forcing the option, before a wrapper
  # or daemon can consume it. The valid control uses the identical forcing.
  accepts = backend: accounts: (builtins.tryEval (builtins.deepSeq (evaluate backend accounts).config.ai.mcp-oauth.accounts true)).success;
  refused =
    [
      {"../escape" = account;}
      {work = account // {clientId = "plaintext-canary";};}
      {work = account // {clientId = redact.command "/bin/read-secret";};}
      {work = account // {clientSecret = account.clientId;};}
      {work = account // {redirectUri = "https://localhost:8080/callback";};}
      {work = account // {redirectUri = "http://example.com:8080/callback";};}
      {work = account // {redirectUri = "http://localhost:0/callback";};}
      {work = account // {redirectUri = "http://localhost:65536/callback";};}
      {work = account // {redirectUri = "http://localhost:8080";};}
      {work = account // {redirectUri = "http://localhost:8080/callback?code=x";};}
      {work = account // {scopes = [];};}
      {work = account // {scopes = ["data:read injected"];};}
      {work = account // {provider = account.provider // {extraScopes = ["keys:read injected"];};};}
      {work = account // {provider = account.provider // {authorizeUrl = 42;};};}
      {work = account // {provider = account.provider // {tokenUrl = 42;};};}
    ]
    # Required credentials, provider endpoints and scopes have no implicit fallback.
    ++ map (field: {work = builtins.removeAttrs account [field];}) ["clientId" "clientSecret" "provider" "scopes"]
    ++ map (field: {work = account // {provider = builtins.removeAttrs account.provider [field];};}) ["authorizeUrl" "tokenUrl"]
    # Reject non-positive lifetimes and values outside the nullable integer contract.
    ++ map (value: {work = account // {provider = account.provider // {loginLifetimeDays = value;};};}) [0 (-1) "30" 1.5 true [] {}];
  valid = backend:
    accepts backend {work = account;}
    && accepts backend {work = account // {redirectUri = "http://[::1]:8080/callback";};}
    && accepts backend {work = cases.devenv.accounts.work;};
  checks =
    lib.all (backend: valid backend && !(lib.any (accepts backend) refused)) ["devenv" "hm"]
    && (evaluate "hm" {}).config.ai.mcp-oauth.services == {}
    && lib.all (config: lib.all (entry: entry.assertion) config.assertions) (builtins.attrValues configs)
    && proxy.checks;
  fixture = pkgs.writeText "mcp-oauth-backends.json" (builtins.toJSON {
    backends = lib.mapAttrs (backend: config: let
      name = "mcp-oauth-${cases.${backend}.name}";
      unit = config.systemd.user.services.${name};
      process = config.processes.${name};
    in
      (snapshot config name)
      // {
        installed =
          lib.any (package:
            "${package}/bin/mcp-oauth"
            == wrapper config name
            && (backend == "hm" || package.meta.priority == -10))
          (
            if backend == "hm"
            then config.home.packages
            else config.packages
          );
        launcher =
          if backend == "hm"
          then unit.Service.ExecStart
          else process.exec;
        prerequisites =
          if backend == "hm"
          then {inherit (unit.Unit) After Wants;}
          else {watchPaths = process.watch.paths;};
      })
    configs;
    proxy = proxy.snapshots;
  });
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    mcp-oauth-backends = assert checks;
      pkgs.runCommand "mcp-oauth-backends" {nativeBuildInputs = [pkgs.python3];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export PYTHONDONTWRITEBYTECODE=1
        python3 ${./wrappers.py} ${fixture}
        echo 'PASS: declaration refusals and real backend module lowering'
        touch "$out"
      '';
  };
}
