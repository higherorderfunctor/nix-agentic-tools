## Managed MCP Service Bind-Address Contract

> **Last verified:** 2026-09-01 (commit pending — the native-declaration table
> drops to a single row: `openmemory-mcp` was retired, and with it the only
> `honorsHost = true` backed by a patch this repo authored rather than an
> upstream primitive. The shape is kept in prose because it is legitimate but
> only as durable as the patch). Prior: 2026-08-05 (commit pending — native HTTP
> modes must now declare whether they honor `service.host`; unsupported modes
> reject every concrete address, and Context7 joins the centrally covered
> `mcp-proxy` bridges because its native HTTP path cannot honor the option).

`services.mcp-servers.servers.<name>.service.host` is a security control, not
descriptive metadata. An address is valid only when it reaches the process that
opens the listener. A module that accepts and discards it is broken even when
the upstream binary currently happens to default to loopback.

The contract lives in `lib/ai/mcpServer/serviceSchema.nix` and
`mkServiceModule.nix`:

- `meta.modes.http = "bridge"` honors the option centrally. The shared
  `mcp-proxy` command always receives `--host` explicitly.
- Every native HTTP mode must declare `meta.honorsServiceHost = true` or
  `false`. Omitting the declaration is an evaluation error. This makes a
  bridge-to-native switch stop for a fresh audit instead of silently inheriting
  the bridge's guarantee.
- `true` is valid only when `settingsToEnv` or `settingsToArgs` carries the
  value to a real upstream bind primitive. If upstream exposes no such
  primitive, plumbing Nix alone proves nothing.
- `false` gives the public option a null default and rejects every concrete
  address, including `"127.0.0.1"`. Its applied internal fallback remains
  loopback so client URL generation and generic config shims keep their stable
  shape; it is not a claim about the listener.

The native declarations currently are:

| Server      | Honors host | Mechanism        |
| ----------- | ----------- | ---------------- |
| `nixos-mcp` | yes         | `MCP_NIXOS_HOST` |

There was a second row until 2026-09-01: `openmemory-mcp`, which honored host
through an `OM_HOST` this repo PATCHED INTO upstream. It is worth remembering as
the shape rather than the instance — a `true` declaration backed by our own
source patch is legitimate under the rule above (the patch created a real
upstream bind primitive), but it makes the declaration only as durable as the
patch. That package was retired when upstream rewrote itself; upstream had by
then adopted a loopback default of its own accord.

Context7 deliberately uses bridge mode: its stdio transport works, while its
native HTTP transport requires Upstash Redis and exposes no bind-address knob.
The proxy therefore fixes both the bind contract and the native mode's standing
crash loop without patching upstream.

Module-level coverage and binary-level exposure are different counts. Ten
modules use bridge mode and are safe because the proxy owns the listener; some
of their stdio binaries would bind every interface if switched directly to
native HTTP. Never infer host support by searching for `service.host` references
alone: classify `meta.modes.http` first.

Behavioral checks must cover all four transitions: bridge accepts an override
without per-server metadata, audited native support accepts one, unaudited
native mode fails, and audited unsupported native mode rejects one. A real
server marked unsupported also needs a module-eval rejection test so its
metadata cannot drift from the factory-only fixtures.
