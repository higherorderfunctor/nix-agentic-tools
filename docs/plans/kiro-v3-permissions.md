# Kiro V3 permissions — mirror Kiro surface + translate under v3

> Status: IMPLEMENTED (permissions). Agents/hooks HELD (greenfield
> breadcrumbs left in `mkKiro.nix`). Branch: refactor/ai-factory-architecture.
> Date: 2026-06-18 (impl 2026-06-19).
>
> Landed: `permissions` option + `mkPermissionRules` translator + write to
> `<configDir>/settings/permissions.yaml` (real YAML via `pkgs.formats.yaml`)
> in `packages/kiro-cli/lib/mkKiro.nix`; 3 eval tests in
> `checks/module-eval.nix`. `trustedMcpTools`/`--trust-tools` untouched (no
> deprecation). Verified: real YAML output correct (`@srv`→`srv/*`,
> `@srv/tool` 1:1, `subagent` rule, `use_aws` dropped w/ warn); tests green;
> no regression. Committed fb7bf1a / 69caa9b / dbef5f6.
>
> VALIDATED on consumer activation 2026-06-22: `~/.kiro/settings/permissions.yaml`
> generated (HM symlink; ~180 rules incl. enumerated github/gitlab read tools
>
> - `subagent`; `use_aws` absent); launcher `kiro-cli-wrapped` carries
>   `--tui --v3`; a live V3 session ran all six `@openmemory` tools with ZERO
>   approval prompts. Full chain confirmed working end-to-end.

## User decisions

- New `permissions` option **mirrors Kiro's `permissions.yaml` schema 1:1**.
- **When v3 is active, translate `trustedMcpTools` → permission rules.**
- **Do NOT deprecate `trustedMcpTools`/`--trust-tools`** — v2 is still
  available; both mechanisms coexist.

## Target file

`~/.kiro/settings/permissions.yaml` (global, user scope).

- Slots into the wrapper's existing `<configDir>/settings/` writers
  (`mcp.json`, `lsp.json`, `cli.json`). `configDir` default `.kiro` →
  `~/.kiro/settings/permissions.yaml`, which is exactly Kiro's global path.
- **HM-only**, like `trustedMcpTools`. Rationale: Kiro reads permissions
  ONLY from `~/.kiro/settings/permissions.yaml` (global) or
  `~/.kiro/workspace-roots/<hash>/permissions.yaml` — never project
  `.kiro/` (anti-injection: "a cloned repo cannot inject permission
  rules"). So devenv's project-relative `.kiro/` can't deliver it.
- Static write (not the cli.json activation-merge): "Always allow" is
  session-scoped in 2.8.1 and does NOT mutate permissions.yaml, so the
  file is purely declarative — no runtime-merge needed.

## Option surface (mirrors Kiro)

```nix
permissions = lib.mkOption {
  type = lib.types.listOf (lib.types.submodule {
    options = {
      capability = mkOption {        # soft-enum (forward-compatible)
        type = either (enum [
          "fs_read" "fs_write" "filesystem" "shell" "web_fetch"
          "web_search" "mcp" "subagent" "skill" "diagnostics"
          "context" "all" "builtin"
        ]) str;
      };
      effect  = mkOption { type = enum ["allow" "deny" "ask"]; };
      match   = mkOption { type = listOf str; default = []; };
      exclude = mkOption { type = listOf str; default = []; };
    };
  });
  default = [];
};
```

Rendered as `{ rules = <list>; }` → `permissions.yaml` via
`(pkgs.formats.yaml {}).generate`. Capability `match`/`exclude` use
Kiro's `server/tool` glob form (`*` only; no `**`/`?`).

## Translation (only when `hasV3 = cfg.v3 || cfg.tui`)

Map each `trustedMcpTools` entry, 1:1 (preserve the deny-by-omission
posture — no wildcard collapsing):

| `trustedMcpTools` entry | → rule                                                        |
| ----------------------- | ------------------------------------------------------------- |
| `@srv` (no slash)       | `mcp` match `srv/*`                                           |
| `@srv/tool`             | `mcp` match `srv/tool`                                        |
| `subagent`              | `{capability: subagent, effect: allow}`                       |
| `use_aws`               | **dropped** (aws_tool removed in v3) — `lib.warn` lists drops |
| other bare token        | dropped + warned                                              |

All `@…` entries collapse into ONE `{capability: mcp, effect: allow,
match: [...]}` rule. Final `rules = cfg.permissions ++ translatedRules`.
Shared helper (`mkPermissionRules cfg`) in the module `let` so HM uses it
(DRY); devenv is a no-op for permissions (see HM-only rationale).

## v2 path untouched

`trustedMcpTools` still appends `--trust-tools` on `kiro-cli-chat`
exactly as today. No deprecation. Coexistence is harmless: each engine
reads its own mechanism (v3 ignores the flag; v2 ignores the file).
(Pre-existing, out of scope: the `--trust-tools` wrapping targets
`kiro-cli-chat` whose top-level parser rejects it — only `kiro-cli chat
--trust-tools` accepts it. Not touched here per "don't change v2.")

## Tests (checks/module-eval.nix)

- `permissions` set → `permissions.yaml` rendered with those rules.
- `trustedMcpTools` + `tui/v3` → file contains translated `mcp` +
  `subagent` rules; `use_aws` absent.
- `trustedMcpTools` with neither v3 nor tui → no permissions.yaml.

## Consumer (nixos-config) — no required change

`trustedMcpTools` auto-translates under their `tui = true` (→ v3). They
may later author native `permissions` (e.g. wildcards) or drop the dead
`use_aws`. Nothing forced.

## Agents / hooks — HELD (decided 2026-06-19)

Permissions warranted action because it had BOTH a typed v2 surface
(`trustedMcpTools`) AND a broken mechanism (`--trust-tools`). Agents and
hooks have NEITHER:

- Current support is **untyped passthrough** — `agents`/`hooks` =
  `attrsOf (either lines path)` writing raw JSON to
  `.kiro/{agents,hooks}/<name>.json`; `agentsDir`/`hooksDir` symlink an
  external dir. No typed schema is modeled → nothing to translate.
- v3 does NOT break the mechanism: agents still read from
  `.kiro/agents/*.json` (also `.md`); hooks still read from
  `.kiro/hooks/*.json` and v2 embedded hooks "still work during
  transition". Only the JSON _content_ schema changed, which the
  passthrough doesn't model.
- Consumer (nixos-config) uses neither → zero impact.

Decision: **HOLD.** "Handle like permissions" would be net-new typed
modeling of Kiro's v3 agent/hook schemas (decoupled from the v3 break),
not a translation. Backlog, not this change.

## Open follow-up (not this change)

`autoApprove` per-server in `mcp.json` (new v3 MCP field) is a possible
simpler alternative co-located with `mcpServers`; schema unconfirmed.
Probe later.
