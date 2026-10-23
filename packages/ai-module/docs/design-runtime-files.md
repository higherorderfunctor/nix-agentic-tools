# Runtime file overrides

> **Last verified:** 2026-10-22 — split from DESIGN.md without changing the
> generic file, activation or service contracts.

### Layer 1: runtime file overrides

`runtimeModule { name; enabled; shared ? []; }` declares `ai.<name>.files`, an
`attrsOf fileEntry`, default `{}`. `name` is the stable runtime identifier;
`enabled` is the owning module's existing boolean. These are constructor inputs,
not another runtime enable option. The helper also declares
`ai.<name>.activation` (layer 3) and the internal `ai.<name>.legacyLedgers`
(`listOf { codec = enum ["dir" "json"]; ledger; path; }`), both forwarded
outside the `enabled` gate into `ai.activation` and the internal root
`ai.legacyLedgers`, so a disabled owner still runs its `runWhenDisabled`
commands and drains its old ledgers. Each forwarded command gets
`enable = mkDefault enabled` at the forwarded priority; a producer that sets
`enable` overrides it. Keys listed in `shared` forward without a claim in
`ai.claims.path`, which leaves their composer the single claimant. Runtime
factories and non-AI owners import the helper. Semble exposes it on both
backends; glab and mcp-services expose it on Home Manager; beads, git and
git-branchless expose it on devenv. These lifecycle namespaces remain visible in
option docs, with explicit backend presence checks outside shared API parity.
Shared skills, rules and other surfaces produce entries here; their rendering
stays above this layer.

Keys are **backend-root-relative final paths**, just like layer 2. There is no
implicit prefix added by forwarding. A runtime producer computes its configured
prefix once, before declaring paths; user overrides use the same final path.

| Runtime | Typical producer prefixes; exceptions remain explicit                                  |
| ------- | -------------------------------------------------------------------------------------- |
| Claude  | `.claude/`; `.claude.json` and project `.mcp.json` are separate paths.                 |
| Codex   | `.codex/`; skills use `.agents/skills/`; project context may be root `AGENTS.md`.      |
| Copilot | `.github/` for project instructions.                                                   |
| Kimchi  | Configured harness, configuration and MCP directories; project `.kimchi/`.             |
| Kiro    | Configured settings and `.kiro/` directories; project context may be root `AGENTS.md`. |

Claude's `.claude.json` is Home Manager only. Its producer disables the staged
`rw` entry when the unpin map is empty, leaving the engine to retire old keys
without adopting an unrelated document. The mode command runs while Claude is
enabled, including with an empty map, after `materialized`. Engine state is
saved atomically while files remain owned and deleted otherwise; repeat
activation preserves ownership contents rather than the state file's timestamp.

These examples are not hard-coded prefix policy in the base. A producer must
make an absolute home configuration path relative to `home.homeDirectory`; paths
outside the active root are refused by the file contract.

| Definition              | Priority and enable behavior                                                                                                                                                                                                                                                           |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Generated surface       | Default text/source and method use `mkDefault`; structured defaults apply per leaf so a consumer leaf preserves siblings. A deliberately whole-entry default remains whole-entry, as with compiled context.                                                                            |
| Runtime override        | Ordinary definitions override defaults; `mkForce` works normally. Select the winning content alternative before evaluating a discarded source. Disabled entries require no content.                                                                                                    |
| Layer 1 → 2             | Forward surviving module definitions with their priority wrappers, not a merged value reintroduced at ordinary priority. Reuse the file entry type. Forward nothing from a disabled runtime; do not publish a false tombstone that disables another producer.                          |
| Direct layer-2 override | Uses ordinary Nix priorities against forwarded definitions. Equal-priority incompatible scalar/content alternatives fail; equal structured leaves merge. There is no hidden runtime precedence over `ai.files`.                                                                        |
| Shared destination      | Distinct live runtime owners cannot independently claim one path. Shared `AGENTS.md` composition/arbitration stays upstream and emits exactly one layer-2 entry, retaining agreeing claims, replacement and suppression semantics. Ordinary cross-runtime collisions name both owners. |

Forwarding uses the module system's alias primitive
`lib.modules.mkAliasAndWrapDefsWithPriority lib.id`, under `lib.mkIf enabled`.
Priority wrappers inside the map (per entry, per field, per value leaf) travel
with the definitions. The wrapper re-applies the runtime option's own highest
priority, so an option-wide `mkDefault` map still loses to an ordinary layer-2
definition; plain `lib.mkAliasDefinitions` strips it and turns that case into an
equal-priority conflict. Forwarded definitions report the helper module's
location, not the producer's; no fixture needs the producer location, so no
custom forwarder exists. The helper sets `_file` to its own path, so every
forwarded root definition reports `lib/runtime.nix`, which the root-definition
guard exempts (see [Repository guards](design-activation.md#repository-guards)).
Content selection examines only the highest-priority defined alternative, so a
discarded source is never evaluated.

The helper also records each declared key, including one with `enable = false`,
in the internal `ai.claims.path.<path>` list; a disabled entry would otherwise
override another runtime's entry unseen. The claims registry fails with
`ai.claims.path.<path>: claimed by <a> and <b>` when a path has two runtime
claims. Overlapping (ancestor/descendant) paths from distinct runtimes fail
through the expanded-destination overlap check, which names the paths, not the
owners.
