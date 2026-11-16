# chrome-devtools-mcp

The owner packages Google's `chrome-devtools-mcp` npm artifact as a pinned,
prebuilt ESM bundle run by Node.js 22 over the MCP stdio transport. The current
release has no runtime npm dependencies, so Nix installs only the shipped
output; it does not run npm or download a browser while building.

The package deliberately does not wrap a browser into its closure, and the
settings refuse to evaluate until one is chosen: `executablePath` to launch a
browser, or `browserUrl`, `wsEndpoint` or `autoConnect` to connect to a running
Chrome. Without one, upstream would look for Google Chrome at fixed system paths
such as `/opt/google/chrome` and fail on the first tool call where it is absent,
as on NixOS. Upstream officially supports Google Chrome and Chrome for Testing;
other Chromium builds may work but are not guaranteed.

No browser starts with the server or its MCP handshake. The first tool call that
needs a page launches or connects one. By default the profile in
`$HOME/.cache/chrome-devtools-mcp/chrome-profile` persists between runs;
`userDataDir` moves it and `isolated = true` uses a temporary one.

## Configure the server

The entry key must be `chrome-devtools-mcp`: it names the owner whose module
types `settings`. Each set option renders as `--<flag>=<value>`; an unset option
renders nothing, so upstream's own default applies.

```nix
ai.mcpServers.chrome-devtools-mcp.settings = {
  executablePath = "${pkgs.chromium}/bin/chromium";
  userDataDir = "/var/lib/example/chrome-devtools-profile";
  usageStatistics = false;
  performanceCrux = false;
  redactNetworkHeaders = true;
  screenshotMaxWidth = 1600;
  workspace = ["/srv/example/project"];
};
```

The settings are generated from upstream's option table in
`extracted/extracted.json`, so every upstream option is available except the
hidden ones `lib/extracted.nix` excludes with a reason. Upstream's
`filesystemRoot` is exposed as `workspace`. An unknown enum value, an
out-of-range number, or an empty list is refused at evaluation.

Leave `screenshotFormat` unset to keep upstream's lossless PNG. Image tokens
scale with pixel dimensions, not encoded bytes, so `screenshotMaxWidth` and
`screenshotMaxHeight` reduce context while JPEG and WebP only reduce transfer
size, at the cost of compression artifacts in small text.

To share one browser between runtimes, run the server behind the local bridge
instead (Home Manager):

```nix
services.mcp-servers.servers.chrome-devtools-mcp = {
  enable = true;
  settings = {...};
};
```
