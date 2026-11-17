# chrome-devtools-mcp

The owner packages Google's `chrome-devtools-mcp` npm artifact as a pinned,
prebuilt ESM bundle run by Node.js 22 over the MCP stdio transport. The current
release has no runtime npm dependencies, so Nix installs only the shipped
output; it does not run npm or download a browser while building.

The package deliberately does not wrap a browser into its closure. With
`--executable-path` unset, upstream looks for an installed stable Chrome channel
and fails when one is absent. Supply `--executable-path`, `--browser-url`, or
`--ws-endpoint` explicitly to choose another installed browser or an
already-running browser. No browser is started merely by the MCP startup check
or the stdio initialization handshake; upstream launches or connects only when a
tool call needs one.
