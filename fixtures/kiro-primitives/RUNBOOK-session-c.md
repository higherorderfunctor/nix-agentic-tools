# Runbook — Session C: limits

Mode **F**, operator-driven. Preconditions as in `RUNBOOK-session-a.md`.

This is the short session. One fixture, and it is the one limit question that no
amount of reading the bundle resolved — because the answer depends on what the
host composes at dispatch time, not on a branch anyone can point at.

## Fixture 14 — do subagents get MCP servers?

Three answers are in circulation and they cannot all be right: a subagent gets
**its own** declared servers, it inherits the **parent's**, or it gets **none**.
The distinction is not academic. Each subagent loading MCP servers from its own
config multiplies their memory per subagent, and that — not throughput — is what
sets the concurrency ceiling for any fan-out design. A drain that keeps its
workers lean depends on knowing which of the three holds.

### Setup, before launching

```bash
cd fixtures/kiro-primitives
eval "$(./harness/scratch-up.sh)"
mkdir -p "$KIRO_FIXTURE_HOME/.kiro/agents"
cp agents/profiles/*.md agents/profiles/*.json "$KIRO_FIXTURE_HOME/.kiro/agents/"
./scripts/lint-probes.sh "$KIRO_FIXTURE_HOME/.kiro/agents" "$KIRO_FIXTURE_HOME/.kiro/hooks"
```

Author two worker profiles that differ in exactly one respect: one **declares an
MCP server**, one **declares none**. Give the root session a server of its own,
so all three cells are distinguishable.

Keep the server trivial and local — this measures wiring, not capability.

### Take the process baseline first

```bash
pgrep -af 'mcp' | tee /tmp/mcp-before.txt | wc -l
```

**Also record the pre-existing engines**, because this machine has been observed
carrying an orphaned engine from an older bundle. A count that assumes a clean
machine is a count that will mislead you:

```bash
pgrep -af 'acp-server.js' | tee /tmp/engines-before.txt
```

### Run

```bash
(cd "$KIRO_FIXTURE_WORKSPACE" && env HOME="$KIRO_FIXTURE_HOME" \
   kiro-cli --v3 --tui)
```

Dispatch each worker and ask each to **list its available tools**. Then:

```bash
pgrep -af 'mcp' > /tmp/mcp-after.txt
diff /tmp/mcp-before.txt /tmp/mcp-after.txt
```

### Reading the result

| Observation                                                         | Conclusion                                             |
| ------------------------------------------------------------------- | ------------------------------------------------------ |
| The declaring worker lists its server's tools, the other lists none | Subagents get **their own** — memory scales per worker |
| Both list the root's server's tools                                 | They **inherit the parent's**                          |
| Neither lists any MCP tool                                          | Subagents get **none**                                 |
| New MCP child processes appear per dispatched worker                | Corroborates "their own", and prices it                |

**Report the tool listing and the process delta together.** Either alone is
weak: a worker can be told about tools it cannot reach, and a process can exist
without being wired to that worker. Agreement between the two is the evidence;
disagreement is itself the finding, and a more interesting one.

**Every count needs its denominator here.** "Zero new MCP processes" means
nothing without "and N were running before, and the root's server is among them"
— otherwise absent and never-started are indistinguishable.

### Tear down

```bash
./harness/scratch-down.sh --keep-logs
pgrep -af 'acp-server.js' | diff /tmp/engines-before.txt - || \
  echo 'NOTE: engine process set changed - check for a leaked engine before the next session'
```

---

## What is deliberately NOT in this session

**The compaction tombstone.** Reproducing it means driving a sub-execution past
its context threshold, and the compaction that follows truncates the **parent
session's** stored history. That is a destructive test for a finding already
carried by a code read plus an upstream issue with patches attached, so it stays
a recorded negative rather than a fixture. The design consequence — workers must
be short and recycled, never long-lived — is already baked into the drain, whose
every iteration is a fresh step and therefore a fresh agent session.

**Per-subagent timeouts, budgets or concurrency keys.** The settings surface has
none; that absence is already recorded with its positive controls, and a live
session cannot strengthen it.
