# slack-mcp

Slack's official MCP server is remote: Slack runs it at
`https://mcp.slack.com/mcp` (Streamable HTTP), so there is no package to build
and no `services.mcp-servers` daemon. This owner pins Slack's MCP server
documentation, extracts the endpoint and the tool-to-scope table from it, and
declares a typed `settings` module, so the server is an ordinary `ai.mcpServers`
entry keyed `slack-mcp`. The same table drives the manifest for your Slack app.

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
    port = 9600;
  };
};
```

Every other field of the common http shape is accepted: `url` overrides the
extracted endpoint (a plain string or a redact reference), and `timeout`,
`headers` and `codex` pass through. Without `proxy.enable`, a runtime other than
Kiro refuses the entry, because it would have to write the token reference into
its config.

## Which scopes the app requests

`settings.manifest` selects the scopes your Slack app asks for, keyed by the
tool rows of Slack's documented scope table (`Search messages/channels`,
`Send message`, `Search users`, and so on; the extracted list is in
`packages/slack-mcp/extracted/extracted.json`):

```nix
# Every read row, no write row, and no direct-message history or search.
ai.mcpServers.slack-mcp.settings.manifest.omitScopes =
  ["im:history" "mpim:history" "search:read.im" "search:read.mpim"];
```

- `reads` are the rows with no `:write` scope; every one is selected by default.
  `writes` are the rows with a `:write` scope (Send message, Canvas
  create/update, and so on); none is selected until you name it. A row the docs
  do not name, or a write row under `reads`, is refused at evaluation.
- `omitScopes` removes scopes a selected row would otherwise request. A scope
  the docs do not name is refused. The row's tools still run, but see less.

Neither field changes the rendered entry: the token's scopes are the limit Slack
enforces. Which tools a runtime runs without asking is a client concern of the
pool, keyed by the tool ids the server reports (see the `tools/list` probe
below): set the generic `ai.mcpServers.<name>.toolPolicy` on the entry, which
every MCP server has.

## The app manifest

`lib.ai.mcpServers.slackManifest` derives the manifest for your Slack app from
the same `settings`. `name` labels the app and its bot stub; `description` (140
characters at most) is shown in the app directory and on the consent screen, and
defaults to a sentence naming the write rows the selection grants. It renders: a
bot user stub with `users:read`, the sorted union of the selected rows' user
scopes less `omitScopes`, PKCE and the MCP toggle on, and org deploy off. It
holds no url, token or client id. Two helpers print it without installing
anything.

In the flake that holds your Home Manager configuration:

```nix
apps.x86_64-linux.slack-mcp-manifest = let
  inherit (inputs.nix-agentic-tools.lib) ai;
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  inherit (self.homeConfigurations.me.config.ai.mcpServers.slack-mcp) settings;
in
  ai.mkManifestApp pkgs (ai.mcpServers.slackManifest {inherit pkgs settings;});
```

Then `nix run .#slack-mcp-manifest > manifest.yaml`. In a devenv project:

```nix
tasks."slack-mcp:manifest" = let
  inherit (inputs.nix-agentic-tools.lib) ai;
  inherit (config.ai.mcpServers.slack-mcp) settings;
in
  ai.mkManifestTask pkgs (ai.mcpServers.slackManifest {inherit pkgs settings;});
```

Then `devenv tasks run --show-output slack-mcp:manifest`. devenv captures a
task's stdout and prints `{}` without that flag; with it the YAML appears in the
run log, indented by two spaces. Inside this repository a gitignored
`devenv.local.nix` can declare the same task by importing
`packages/slack-mcp/lib/manifest.nix` and `lib/redact` directly.

## The token

Create an internal app in your workspace from the manifest (no admin needed for
an app only you install) and install it. The install yields an `xoxp-` user
token; store it in your secret manager and point `token` at the decrypted file.

Before wiring it in, check that Slack accepts the token as a bearer. The token
is read from the file, never placed in argv:

```bash
bearer() { printf 'Authorization: Bearer %s\n' "$(cat /run/user/1000/secrets/slack-user-token)"; }
mcp() {
  bearer | curl -sS -X POST https://mcp.slack.com/mcp -H @- \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' "$@"
}
mcp -i -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

`200` with an `Mcp-Session-Id` header means yes; `401` means no. To list the
tool ids the server reports, pass that session id on:

```bash
session=<Mcp-Session-Id from above>
mcp -H "Mcp-Session-Id: $session" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
mcp -H "Mcp-Session-Id: $session" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

## What the agent can do with it

- Writes are attributed to you, not to the app: a message the agent sends is a
  message you sent.
- A user token sees nothing you cannot see, and everything you can, within the
  scopes the app was granted.
- The risks are prompt injection from content the agent reads combined with
  write tools, no undo for sent messages, a non-expiring token in the proxy
  daemon's or Kiro launcher's environment, and DM and email scopes.
- Leave `im:*`, `mpim:*`, `search:read.im`, `search:read.mpim` and
  `users:read.email` off the app unless a row you need requests them: put them
  in `omitScopes`, or leave the rows that need them out of `reads` and `writes`.
