# Webex MCP

Each enabled `ai.webex-mcp.instances.<name>` generates both Webex meeting and
messaging MCP server entries in `ai.webex-mcp.mcpServers`, with one credential
set and one login. Assign those entries to `ai.mcpServers` and enable your
ordinary AI client; there are no meeting/messaging instance switches.

Register `http://localhost:8080/callback` with your confidential Webex OAuth
integration, and provision two distinct sops secrets. Save this shared consumer
module as `webex.nix`:

```nix
{ clientIdFile, clientSecretFile }:
{ config, inputs, lib, ... }:
let
  redact = import "${inputs.nix-agentic-tools}/lib/redact" { inherit lib; };
in {
  ai.claude.enable = true;
  ai.mcpServers = {
    inherit (config.ai.webex-mcp.mcpServers)
      webex-mcp-work-meeting
      webex-mcp-work-messaging;
  };
  ai.webex-mcp.instances.work = {
    enable = true;
    oauth = {
      clientId = redact.file clientIdFile;
      clientSecret = redact.file clientSecretFile;
    };
  };
}
```

For Home Manager, import the public backend and sops-nix modules:

```nix
{ config, inputs, ... }: {
  imports = [
    inputs.nix-agentic-tools.homeManagerModules.default
    inputs.sops-nix.homeManagerModules.sops
    (import ./webex.nix {
      clientIdFile = config.sops.secrets.webex-client-id.path;
      clientSecretFile = config.sops.secrets.webex-client-secret.path;
    })
  ];
  sops.defaultSopsFile = ./secrets.yaml;
  sops.secrets = { webex-client-id = {}; webex-client-secret = {}; };
}
```

Supply your usual Home Manager identity, state version and sops key setup. For
devenv, use already provisioned sops files (there is no upstream devenv sops-nix
module):

```nix
{ inputs, ... }: {
  imports = [
    inputs.nix-agentic-tools.devenvModules.nix-agentic-tools
    (import ./webex.nix {
      clientIdFile = "/run/secrets/webex-client-id";
      clientSecretFile = "/run/secrets/webex-client-secret";
    })
  ];
}
```

Declare the input in `devenv.yaml` without also auto-importing its module. Pass
`inputs` through the module arguments in either backend. Both examples use the
shared consumer module to assign the generated entries to `ai.mcpServers`.

Run `webex-login work`, or `webex-login` for the instance picker. This one login
authorizes both endpoints: `https://mcp.webexapis.com/mcp/webex-meeting` and
`https://mcp.webexapis.com/mcp/webex-messaging`. The default scopes are:

- `meeting:participants_read`
- `meeting:schedules_read`
- `meeting:summaries_read`
- `meeting:transcripts_read`
- `spark:mcp`
- `spark:memberships_read`
- `spark:messages_read`
- `spark:people_read`
- `spark:rooms_read`

Set `oauth.scopes` to override that list. The fixed profile additionally
requests `spark:kms` and caps login lifetime at 90 days; these are configured
owner data, not measurements of live consent or token lifetime.

For multiple isolated instances, add another instance with its own two secret
files, for example `ai.webex-mcp.instances.personal`, alongside `work`, and
assign its generated entries to `ai.mcpServers` too. Each has separate
credentials, state and refresher. The owner allocates local proxy ports in
sorted enabled-instance order, starting at 19592/19593 and increasing by two.
Adding or removing an earlier instance can renumber later local URLs; all client
configurations are regenerated together. Existing global port claims report
conflicts. Empty and disabled instances emit no accounts, commands, daemons or
servers.

See [MCP OAuth operations](../../mcp-oauth/docs/README.md#operate) for backend
state, service startup, recovery and durability. Home Manager and devenv logins
are independent; automated checks do not perform live consent.
