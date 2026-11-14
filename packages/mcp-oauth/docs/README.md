# MCP OAuth

Use the backend-installed `mcp-oauth` wrapper for confidential-client OAuth
authorization-code login and refresh. Accounts hold provider data and two
credential file references. A proxy names an account with `proxy.oauthAccount`;
clients receive only a loopback URL. Enable an AI consumer: unused root server
declarations do not start proxies.

## Configure

Register `http://localhost:8080/callback` with your provider. Both `127.0.0.1`
and `::1` must be available on the callback port. Reserve the chosen proxy port.
The reserved `example.test` endpoints below are placeholders; replace them with
your provider and MCP endpoints and choose the scopes your server needs.

Save this shared module as `oauth.nix`; pass flake `inputs` through module
arguments (Home Manager's `extraSpecialArgs.inputs`, or devenv's `inputs`):

```nix
{ clientIdFile, clientSecretFile }:
{ inputs, lib, ... }:
let
  redact = import "${inputs.nix-agentic-tools}/lib/redact" { inherit lib; };
in {
  ai.claude.enable = true;
  ai.mcp-oauth.accounts.work = {
    clientId = redact.file clientIdFile;
    clientSecret = redact.file clientSecretFile;
    provider = {
      authorizeUrl = "https://identity.example.test/authorize";
      extraScopes = [ "offline:access" ];
      loginLifetimeDays = null;
      tokenUrl = "https://identity.example.test/token";
    };
    scopes = [ "data:read" ];
  };
  ai.mcpServers.data = {
    url = "https://mcp.example.test/mcp/data";
    proxy = { enable = true; oauthAccount = "work"; port = 19592; };
  };
}
```

The provider block is the account's authorization profile. Login requests the
union of account `scopes` and provider `extraScopes`. `loginLifetimeDays` is
null for no configured deadline, or a positive integer for a cap measured from
login that refresh never extends. A returned `refresh_token_expires_in` can
impose an earlier deadline; its absence adds no deadline. The provider must
issue a refresh token. `redirectUri` defaults to the registered callback above.

For Linux Home Manager, import the public module, sops-nix and the shared
module:

```nix
{ config, inputs, ... }: {
  imports = [
    inputs.nix-agentic-tools.homeManagerModules.default
    inputs.sops-nix.homeManagerModules.sops
    (import ./oauth.nix {
      clientIdFile = config.sops.secrets.oauth-client-id.path;
      clientSecretFile = config.sops.secrets.oauth-client-secret.path;
    })
  ];
  sops.defaultSopsFile = ./secrets.yaml;
  sops.secrets = { oauth-client-id = {}; oauth-client-secret = {}; };
}
```

Supply your usual identity, state version, sops key setup and encrypted YAML
containing those two credentials. For devenv, declare `nix-agentic-tools` in
`devenv.yaml`, then use two **already provisioned**, distinct runtime sops
files:

```nix
{ inputs, ... }: {
  imports = [
    inputs.nix-agentic-tools.devenvModules.nix-agentic-tools
    (import ./oauth.nix {
      clientIdFile = "/run/secrets/oauth-client-id";
      clientSecretFile = "/run/secrets/oauth-client-secret";
    })
  ];
}
```

Do not also auto-import that public module from `devenv.yaml`. devenv has no
upstream sops-nix module. If project tasks decrypt the files, register their
ordering through
[`ai.activationOrder.secretProviders`](../../ai-module/docs/contract.md) before
client materialization and service startup. Never evaluate secret contents or
put tokens in client headers. Trailing credential newlines are stripped; empty
or embedded-newline credentials are refused.

## Operate

Run `mcp-oauth login work`, `mcp-oauth status work`, or
`mcp-oauth refresh work`. The supervisor runs `mcp-oauth daemon work` for
ongoing refresh. Only explicit login opens a browser. Single-account
login/status skip selection; multiple accounts use gum with current status
labels: `ready`, `refresh required`, or `login required`, plus expiry details;
unreadable or invalid state shows `unavailable`. Status reports
`login expires in N days` or `no known login expiry` when neither deadline is
known. Explicit names bypass selection; scripts should name an account.
Multi-account refresh/daemon commands require an explicit name. Cancellation
writes no state; refresh performs one exchange.

Home Manager manages user units `mcp-oauth-work` and `mcp-proxy-data`, with the
credential reader ordered after sops-nix. **`devenv up` starts the proxy and
refresher**; shell entry alone starts neither. Login seeds tokens but starts no
services. There is no activation refresh fallback. Credential changes feed the
existing service restart inputs; login, refresh and token writes never restart
services. Caddy rereads the token file on every request; unavailable tokens deny
forwarding.

Each backend pins its own manifest and state root:
`<xdg.stateHome>/mcp-oauth/hm/work` or `<devenv.state>/mcp-oauth/devenv/work`.
Log in independently in each backend. A project declaring accounts never exposes
Home Manager accounts; zero accounts installs no wrapper. Environment variables
cannot change these roots. Raw package `--manifest` is a private generated
interface; wrappers reject overrides.

Recovery notifications give an absolute command such as
`/nix/store/<hash>-mcp-oauth/bin/mcp-oauth login work`. Run the **entire emitted
command**, even from another backend's shell. The daemon backs off on transient
errors and waits for new login after rejection or expiry. It warns within **7
days of the effective login expiry**: the earlier of the configured login
deadline and the known refresh-token expiry, using whichever exists. With
neither bound there is no expiry warning. Access-token expiry alone does not
trigger this warning. The durable warning marker survives refresh and resets on
new login. Notification failure is reported safely; a crash after recording a
warning may lose delivery.

## Durability and platform limits

Private state (directory 0700, files 0600) is authoritative and protected by a
stable lock. State becomes durable before the access-token projection; reconcile
repairs a missing, stale or malformed projection from validated state. Rejection
becomes durable before withdrawal. **A crash before durable rejection can
republish the old token**; upstream must reject it. Remote exchange and local
publication cannot be atomic; a crash after remote rotation can require login.
Local users reaching the loopback port can exercise the account's authority.

The package supports Linux (`xdg-open`, `notify-send`) and macOS (`open`,
`osascript`), with gum on both. The Home Manager supervisor integration
described here is Linux systemd; package availability does not provide a macOS
user-service backend. devenv services require its running process supervisor.
Automated checks use synthetic credentials/providers; live consent, sops
decryption, desktop delivery and supervisor startup remain deployment
validation. Provider expiry/revocation may interrupt established streams.

## Mount an owner profile

An owner with named instances can mount the shared credential/scope options and
account lowering. For example, its common module defines a fixed profile:

```nix
{ config, lib, ... }:
let
  oauth = (import ../../mcp-oauth/lib/mount.nix { inherit lib; }).mkOAuthMount {
    owner = "records";
    profile = {
      authorizeUrl = "https://identity.example.test/authorize";
      extraScopes = [ "offline:access" ];
      loginLifetimeDays = null;
      name = "records";
      scopes = [ "data:read" ];
      tokenUrl = "https://identity.example.test/token";
    };
  };
in {
  imports = [ oauth.module ];
  options.ai.records.instances = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options.enable = lib.mkEnableOption "records instance";
    });
  };
  options.ai.records.mcpServers = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule (import ../../../lib/ai/mcpServer/commonSchema.nix));
    readOnly = true;
    description = "Generated server entries for consumers to assign to ai.mcpServers.";
  };
  config.ai.records.mcpServers = lib.mapAttrs' (instance: _:
    lib.nameValuePair "records-${instance}" {
      url = "https://mcp.example.test/records";
      proxy = {
        enable = true;
        oauthAccount = oauth.accountName instance;
        # The owner must allocate distinct proxy ports for its instances.
        port = 19600;
      };
    }) (lib.filterAttrs (_: value: value.enable) config.ai.records.instances);
}
```

Consumers select the generated entries separately:

```nix
{ config, ... }: {
  ai.mcpServers = {
    inherit (config.ai.records.mcpServers) records-work;
  };
}
```

The server example has one instance; owners supporting several must allocate
ports for each. Consumers set only instance enablement and `oauth.clientId`,
`oauth.clientSecret`, and optionally `oauth.scopes`. The credential files must
be distinct. Profile scopes provide the mounted default; low-level account
scopes remain required. The callback retains the internal default.

The helper returns `module` and `accountName`; the latter is an owner-only proxy
reference. Internal IDs are `<owner>-<instance>`. Owners must use distinct names
whose derived account IDs do not overlap. Enabled instances lower to one account
and one ordinary refresher each; disabled instances need no credentials and
produce no account. The profile name installs only `records-login [instance]`.
Without an instance it uses the existing status picker restricted to that
owner's enabled instances. Labels show instance names while state and daemon
identity retain the internal account ID. The generic commands remain available.
