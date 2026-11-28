# cspell:ignore nonloopback
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
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
  proxy = import ./proxy.nix {inherit harness lib;};
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
  # Force just the option that owns the restriction; these checks do not
  # depend on manifest or service generation succeeding for a bad declaration.
  accountRows = backendName: let
    accounts = declarations: (evaluate backendName declarations).config.ai.mcp-oauth.accounts;
    reject = path: valid: invalid:
      rejectsChange (declaration: lib.attrByPath path null (accounts {work = declaration;}).work) {
        inherit invalid valid;
        expected = lib.getAttrFromPath path valid;
      };
    field = name: invalid: reject [name] account (account // {${name} = invalid;});
    provider = name: valid: invalid:
      reject ["provider" name]
      (account // {provider = account.provider // {${name} = valid;};})
      (account // {provider = account.provider // {${name} = invalid;};});
    redirect = invalid:
      rejectsChange (value: (accounts {work = account // {redirectUri = value;};}).work.redirectUri) {
        inherit invalid;
        valid = "http://localhost:8080/callback";
        expected = "http://localhost:8080/callback";
      };
    lifetime = provider "loginLifetimeDays" 30;
  in
    {
      "account IDs cannot traverse directories" = rejectsChange (name: (accounts {${name} = account;}).${name}.clientId) {
        valid = "work";
        invalid = "../escape";
        expected = account.clientId;
      };
      "client ID cannot use a command reference" = field "clientId" (redact.command "/bin/read-secret");
      "client ID cannot use plaintext" = field "clientId" "plaintext-canary";
      "credential files cannot be shared" = field "clientSecret" account.clientId;
      "extra scopes cannot contain spaces" = provider "extraScopes" ["keys:read"] ["keys:read injected"];
      "login lifetime cannot be fractional" = lifetime 1.5;
      "login lifetime cannot be negative" = lifetime (-1);
      "login lifetime cannot be text" = lifetime "30";
      "login lifetime cannot be zero" = lifetime 0;
      "redirect accepts bracketed IPv6 loopback" =
        (accounts {work = account // {redirectUri = "http://[::1]:8080/callback";};}).work.redirectUri
        == "http://[::1]:8080/callback";
      "redirect cannot omit callback path" = redirect "http://localhost:8080";
      "redirect cannot use HTTPS" = redirect "https://localhost:8080/callback";
      "redirect cannot use a nonloopback host" = redirect "http://example.com:8080/callback";
      "redirect cannot use a query" = redirect "http://localhost:8080/callback?code=x";
      "redirect cannot use port 0" = redirect "http://localhost:0/callback";
      "redirect cannot use port 65536" = redirect "http://localhost:65536/callback";
      "scopes cannot be empty" = field "scopes" [];
      "scopes cannot contain spaces" = field "scopes" ["data:read injected"];
    }
    // lib.listToAttrs (map (name:
        lib.nameValuePair "account requires ${name}" (reject [name] account (builtins.removeAttrs account [name]))) ["clientId" "clientSecret" "scopes"])
    // {
      "account requires a provider" = reject ["provider" "authorizeUrl"] account (builtins.removeAttrs account ["provider"]);
    }
    // lib.listToAttrs (lib.concatMap (name: [
      (lib.nameValuePair "provider requires ${name}" (reject ["provider" name] account (account
        // {
          provider = builtins.removeAttrs account.provider [name];
        })))
      (lib.nameValuePair "provider ${name} must be a string" (provider name account.provider.${name} 42))
    ]) ["authorizeUrl" "tokenUrl"]);
  mountedRows = backendName: let
    instances = extra: (backend.mounted backendName extra).config.ai.sample.instances;
    reject = read: expected: invalid:
      rejectsChange (extra: read (instances extra)) {
        inherit expected invalid;
        valid = {};
      };
    # Unknown options are reported by the submodule merge, not by reading a
    # declared child (which can remain lazy). Force the OAuth record itself.
    mountCredentials = instances: builtins.deepSeq instances.work.oauth (builtins.attrNames instances.work.oauth);
    rejectOverride = reject mountCredentials ["clientId" "clientSecret" "scopes"];
  in {
    "disabled instance IDs cannot traverse directories" =
      reject (instances: lib.mapAttrs (_: instance: instance.enable) instances)
      {
        disabled = false;
        personal = true;
        work = true;
      }
      {ai.sample.instances."../bad".enable = false;};
    "instance credentials cannot share a file" =
      reject (instances: instances.work.oauth.clientSecret) (redact.file "/run/secrets/work-secret")
      {ai.sample.instances.work.oauth.clientSecret = lib.mkForce (redact.file "/run/secrets/work-id");};
    "instance scopes cannot be empty" =
      reject (instances: instances.work.oauth.scopes) ["override:read"]
      {ai.sample.instances.work.oauth.scopes = lib.mkForce [];};
    "mounted provider is not consumer configurable" = rejectOverride {ai.sample.instances.work.oauth.provider.name = "override";};
    "mounted redirect is not consumer configurable" = rejectOverride {ai.sample.instances.work.oauth.redirectUri = "http://localhost:8081/callback";};
  };
  checks =
    checkRows "OAuth account declarations (devenv)" (accountRows "devenv")
    && checkRows "OAuth mounted declarations (devenv)" (mountedRows "devenv")
    && checkRows "OAuth backend integration" {
      "configured backends satisfy module assertions" = lib.all (config: lib.all (entry: entry.assertion) config.assertions) (builtins.attrValues configs);
    }
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
    cliSource = ../src;
    mounted = lib.genAttrs ["devenv" "hm"] (name: let
      cfg = (backend.mounted name {}).config;
      packages =
        if name == "hm"
        then cfg.home.packages
        else cfg.packages;
    in {
      accounts = builtins.attrNames cfg.ai.mcp-oauth.accounts;
      claims = cfg.ai.mcp-oauth.claims.path;
      commands = lib.mapAttrs (_: service: service.command) cfg.ai.mcp-oauth.services;
      logins = map (package: "${package}/bin/sample-login") (lib.filter (package: package.name == "mcp-oauth-logins") packages);
    });
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
