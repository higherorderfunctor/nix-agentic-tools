# slack-mcp

Slack's official MCP server is remote: Slack runs it at
`https://mcp.slack.com/mcp` (Streamable HTTP), so there is no package to build
and no `services.mcp-servers` daemon. This owner pins Slack's MCP server
documentation, extracts the endpoint and the tool-to-scope table from it, and
declares a typed `settings` module, so the server is an ordinary `ai.mcpServers`
entry keyed `slack-mcp`.

## Quick start

```nix
{ inputs, ... }: let
  inherit (inputs.nix-agentic-tools.lib) redact;
in {
  # Kiro resolves the header from the launcher environment at start.
  ai.kiro.mcpServers.slack-mcp.settings.token =
    redact.file "/run/user/1000/secrets/slack-user-token";
}
```

The entry key must be `slack-mcp`: it names the owner whose module types
`settings`. `settings.token` is required and must be a redact reference
(`redact.file` or `redact.command`); a plain string is refused without printing
it. It is sent as `Authorization: Bearer <token>`.

To use it from every runtime, run it through the local proxy instead. The proxy
daemon holds the header and each runtime gets a credential-free loopback entry:

```nix
ai.mcpServers.slack-mcp = {
  settings.token = redact.file "/run/user/1000/secrets/slack-user-token";
  proxy = {
    enable = true;
    port = 9503;
  };
};
```

Every other field of the common http shape is accepted: `url` overrides the
extracted endpoint (a plain string or a redact reference), and `timeout`,
`headers` and `codex` pass through. Without `proxy.enable`, a runtime other than
Kiro refuses the entry, because it would have to write the token reference into
its config.

## The token

Create an internal app in your workspace (no admin needed for an app only you
install), turn on the MCP server under the app's Agents & AI Apps settings, add
the user scopes for the tools you want, and install it. The install yields an
`xoxp-` user token; store it in your secret manager and point `token` at the
decrypted file.

Before wiring it in, check that Slack accepts the token as a bearer (the token
is read from the file, never placed in argv):

```bash
printf 'Authorization: Bearer %s\n' "$(cat /run/user/1000/secrets/slack-user-token)" |
  curl -sS -i -X POST https://mcp.slack.com/mcp -H @- \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

`200` with an `Mcp-Session-Id` header means yes; `401` means no.

## What the agent can do with it

- Writes are attributed to you, not to the app: a message the agent sends is a
  message you sent.
- A user token sees nothing you cannot see, and everything you can, within the
  scopes the app was granted.
- The risks are prompt injection from content the agent reads combined with
  write tools, no undo for sent messages, a non-expiring token in the proxy
  daemon's or Kiro launcher's environment, and DM and email scopes.
- Leave `im:*`, `mpim:*`, `search:read.im`, `search:read.mpim` and
  `users:read.email` off the app unless a tool you allow needs them.
