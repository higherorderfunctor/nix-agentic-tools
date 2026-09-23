## Kiro workflows: three gates, all of them silent

> **Last verified:** 2026-09-22 — the shipped TUI source still excludes
> `chat.enableWorkflows` from the workspace settings allowlist.

`ai.kiro.unlockedRolloutFeatures = ["workflows"]` is necessary and **not**
sufficient. Three independent conditions must hold, none of them errors or logs
when it fails, and each has already cost a debugging session:

| #   | Gate                                    | Set by                                 | Failure look                   |
| --- | --------------------------------------- | -------------------------------------- | ------------------------------ |
| 1   | rollout manifest says the feature is on | the byte patch (`mkKiroRolloutPatch`)  | `/workflow` absent             |
| 2   | engine is `kas`                         | `ai.kiro.v3 = true`                    | `/workflow` absent             |
| 3   | `chat.enableWorkflows` is true          | the GLOBAL `~/.kiro/settings/cli.json` | commands present, TOOLS absent |

Gates 1 and 2 already have assertions in `mkKiro.nix`. Gate 3 is implied with
gate 1 on the Home Manager backend and cannot be satisfied from devenv at all —
see below.

### Gate 3 is the one that looks like an upstream removal

Numbering note, because the two counts in play are easy to conflate: there are
THREE gates in the table, and gate 3 is the setting. Separately, the CLIENT's
own check went from one condition to two in 2.19.0 — that second condition is
what gate 3 reads. "Second condition" and "third gate" are the same fact counted
in different frames.

Up to 2.18.1 the client's check was one condition:

```js
workflowsEnabled = Lr.isEnabled("workflows");
```

From **2.19.0** it is two, and the second defaults to false:

```js
function Ah() {
  let e = Ht("workflows");
  return { available: e, enabled: e && wi(pn.CHAT_ENABLE_WORKFLOWS, !1) };
}
// pn.CHAT_ENABLE_WORKFLOWS === "chat.enableWorkflows"
```

Measured by counting the gate expression `CHAT_ENABLE_WORKFLOWS,!1)` in each
store binary's embedded JS: **0 in 2.18.0 and 2.18.1, 2 in every measured
release from 2.19.0 on** (2.19.0, 2.19.1, 2.19.2, 2.20.1, 2.20.2, 2.21.0,
2.21.1).

The failure presents as the feature having been withdrawn. `Ah().enabled` false
means `get workflowExtension(){ if(!this.workflowsEnabled) return }` never
constructs the extension, so the client sends
`settings.workflows = {enabled:false}` (and `goal` with it), and in the KAS
engine `createWorkflowCommandSource` registers no workflow tools. The agent then
reports that `run_workflow` is not in its toolset — which reads exactly like
upstream deleting the tool. **Check the setting before re-deriving anything
about the patch.**

Two consequences worth knowing when verifying a fix:

- The setting is read at START. Restart kiro; do not expect a running session to
  pick it up.
- KAS persists `workflowsEnabled` per session, explicitly "so a reloaded session
  keeps its choice". Prefer a fresh session over resuming one created while the
  setting was off, or the fix will look like it did not take.

### Gate 3 is GLOBAL-only, which is why devenv refuses it

Since **2.21.1** — and not before; every earlier release measured (2.18.1,
2.19.0, 2.19.2, 2.20.2, 2.21.0) has no such code and no `[cli-settings]`
workspace warning at all — the TUI merges a project-local
`.kiro/settings/cli.json` over the global one through an allowlist:

```js
function vr() {
  let e = dA(); // global ~/.kiro/settings/cli.json
  try {
    let n = Qq(Eq()); // workspace .kiro/settings/cli.json
    for (let [t, a] of Object.entries(n)) if (Cq.has(t)) e[t] = a; // <- allowlist
  } catch (n) {
    ee.warn("[cli-settings] failed to read workspace cli.json:", n);
  }
  return e;
}
```

`chat.enableWorkflows` is **not** in that allowlist, so a project-local write of
it is read, filtered out, and dropped without a warning. The two backends
therefore honor different key sets, because they write different files:

- **Home Manager** writes the GLOBAL file. Every key works. Unlocking
  `workflows` implies `nativeSettings.chat.enableWorkflows = mkDefault true`
  (`workflowsSettingImplication`), so gates 1 and 3 cannot drift apart, and an
  explicit value still wins.
- **devenv** writes the PROJECT-LOCAL file. Only allowlisted keys work, so
  `mkDevenvWorkspaceSettingsAssertions` REFUSES anything else at eval rather
  than emitting a file that looks applied. The implication is deliberately not
  contributed there — it would write a discarded key and trip that very
  assertion on a config nobody wrote.

Do not "restore parity" by adding the implication to devenv. The asymmetry is
the correct lowering of one option onto two different native scopes; the option
DECLARATION is shared, which is where parity actually lives.

### The allowlist is extracted from the workspace merge

`packages/kiro-cli/extracted.json` carries `workspaceOverridableSettings`,
produced by `kiroSettingsExtractScript` in
`packages/kiro-cli/lib/packaging.nix`. It is extracted rather than curated for
the same reason `rolloutFeatures` is: the set IS the contract.

The extractor materializes the shipped TUI source in a Nix build sandbox and
uses its JavaScript AST to find the registry and candidate allowlist by their
contents, not by minified variable names. It also requires the workspace merge
function to consult that same set. A missing or ambiguous registry is fatal.
When both the set and merge are absent, the extractor returns `[]`, matching
releases before 2.21.1 that had no workspace override. If only one is absent, it
fails; silently treating an unreadable allowlist as empty would reject settings
Kiro actually honors. The validated registry and set expressions and the
selected merge helper are evaluated in an isolated VM with inert loaders. This
resolves symbolic members through the bundle's own registry and verifies which
keys the merge actually copies. `module-kiro-workspace-allowlist-from-sidecar`
checks for `chat.defaultModel` specifically because it appears symbolically in
the set.

That test also asserts `chat.enableWorkflows` is ABSENT from the allowlist. If
upstream adds it, the test failing is the signal to relax the devenv guidance
above — not a defect to route around.
