
> ## Documentation Index
>
> Fetch the complete documentation index at: <https://kiro.dev/llms.txt>
> Use this file to discover all available pages before exploring further.

# CLI 3.0 (Early Access)

> CLI 3.0 is built on the Kiro Agent Server -- one engine powering IDE, CLI, and Web. Try it with kiro-cli --v3.

**ℹ️ Info:** An early release of Kiro CLI v3 is now available. Try it out with: `kiro-cli --v3`. V3 runs alongside your existing 2.x install -- your current setup is unchanged until you opt in.

## A single engine for all Kiro surfaces

CLI 3.0 is built on the same unified agent harness that powers the Kiro IDE and Kiro Web. Every improvement to the engine (new tools, better planning, smarter tool selection) now ships to all clients simultaneously.

## What's new in 3.0

**Spec-driven development** -- the Spec agent brings structured development to the terminal. Define requirements, generate designs, execute task plans with checkpoints. Use `/spec new <name>` to start. [Learn more →](https://kiro.dev/docs/cli/v3/specs.md)

**Capability-based permissions** -- declare structured policies in `permissions.yaml` for fine-grained, auditable control. One rule can allow or deny an entire category of operations across all tools. [Learn more →](https://kiro.dev/docs/cli/v3/permissions.md)

**Enhanced hooks** -- standalone `.kiro/hooks/*.json` files with two action types (shell commands and agent prompts), new triggers, and a versioned schema. [Learn more →](https://kiro.dev/docs/cli/v3/hooks.md)

**Enhanced agent config** -- tag-based tool selection, unified permissions block, Markdown format, inline MCP servers. [Learn more →](https://kiro.dev/docs/cli/v3/agent-config.md)

## Breaking changes

| Area | What changed |
|------|-------------|
| **Permissions** | `--trust-all-tools` and `/tools trust` replaced by `permissions.yaml` |
| **Hooks** | Embedded hooks moved to standalone `.kiro/hooks/*.json`, PascalCase triggers |
| **Agent config** | `toolsSettings` replaced by `permissions` field, tool IDs replaced by tags |
| **aws_tool** | Removed -- use MCP servers instead |
| **Session format** | v3 format not backward-compatible -- back up `~/.kiro/sessions/` |
| **Supervised mode** | Removed -- use `permissions.yaml` |

## Get started

Try the v3 engine: `kiro-cli --v3`.

- [Permissions](https://kiro.dev/docs/cli/v3/permissions.md) -- capability-based permission model
- [Hooks](https://kiro.dev/docs/cli/v3/hooks.md) -- standalone hooks with new triggers
- [Agent config](https://kiro.dev/docs/cli/v3/agent-config.md) -- tags, permissions block, Markdown format
- [Specs](https://kiro.dev/docs/cli/v3/specs.md) -- spec-driven development in the terminal
- [Feature comparison](https://kiro.dev/docs/cli/v3/feature-overview.md) -- full v2 → v3 feature status table

**ℹ️ Info:** To convert your existing V2 agent configurations to the universal V2+V3 format, run `/upgrade-agent` inside a V3 session. See the [migration guide](https://kiro.dev/docs/cli/v3/upgrade-agent.md) for details.

## Known gaps

| Gap | Detail |
|-----|--------|
| **AL2 not supported** | CLI 3.0 does not run on Amazon Linux 2. Use CLI 2.x if your environment requires AL2. |
| **Classic mode not supported** | The legacy non-TUI mode (`kiro-cli chat` without the TUI) does not support the v3 engine. Use the TUI. |
| **Session resume** | V3 sessions cannot be resumed in V2. If you switch back to the V2 engine, previously created V3 sessions will not be available. |

## Learn more

- `kiro-cli diagnostic` -- validates your environment
- [Hooks documentation](https://kiro.dev/docs/cli/hooks.md) -- full hooks reference
- [MCP configuration](https://kiro.dev/docs/cli/mcp/configuration.md) -- MCP server setup
- [Steering](https://kiro.dev/docs/cli/steering.md) -- steering document details

> ## Documentation Index
>
> Fetch the complete documentation index at: <https://kiro.dev/llms.txt>
> Use this file to discover all available pages before exploring further.

# Specs in CLI

> Spec-driven development in the terminal -- plan before you code with structured requirements, designs, and task execution.

## Overview

Specs bring structured, plan-then-execute development to the CLI. The Spec agent is a built-in agent that runs alongside your custom agents on the unified engine. Switch to it when you want the agent to think through requirements and design before writing code, then execute an implementation plan with verification between each task.

Because Spec is a standard agent, your permissions, hooks, and MCP servers all apply to it the same way they apply to any other agent.

## Using specs

The `/spec` slash command manages spec workflows:

| Command | What it does |
|---------|-------------|
| `/spec` | List existing specs in the workspace and select one |
| `/spec new <name>` | Start a new spec -- the agent asks what the spec should cover, then switches to Spec mode and begins requirements |
| `/spec <name>` | Resume an existing spec where you left off |
| `/spec run <name>` | Execute all tasks in a spec's implementation plan autonomously |

When you run `/spec new` or `/spec <name>`, the CLI switches to the Spec agent. When execution completes or you manually switch back, the agent returns to your previous mode.

### Quick example

```
> /spec new auth-middleware

Starting spec: "auth-middleware"

What should this spec cover? Describe it in a sentence or two.

> JWT-based auth middleware for Express routes with role-based access control

Spec agent activated. Let me analyze your request and produce requirements...

[Agent produces requirements.md with acceptance criteria]

> Looks good, proceed to design.

[Agent produces design.md with architecture decisions]

> Execute the tasks.

[Agent works through tasks.md sequentially, verifying between steps]
```

### Description step

When you run `/spec new <name>`, the CLI prompts you to describe what the spec should cover before drafting requirements. The agent uses your description as the ground truth instead of guessing from the spec name alone.

- Type your description and press Enter to proceed
- Press Esc to cancel the description step (spec mode stays active)
- Type a slash command to run it and keep the step armed for later

## How specs work

1. **Requirements** -- the agent analyzes your request and produces structured acceptance criteria
2. **Design** -- technical design with architecture decisions and component breakdown
3. **Tasks** -- an ordered implementation plan with dependency tracking
4. **Execution** -- tasks run sequentially with verification between steps

Each phase produces a file in `.kiro/specs/<name>/`:

```text
.kiro/specs/my-feature/
  requirements.md
  design.md
  tasks.md
```

You can review and edit these files between phases. The agent respects your changes.

## Running tasks

`/spec run <name>` validates that `tasks.md` exists, then triggers autonomous execution. The agent works through each task without further prompts, streaming progress as it goes. You can interrupt at any point.

## Spec types

When you run `/spec new`, the agent asks what kind of spec you want:

- **Build a Feature** -- structured requirements, design, and implementation tasks
- **Fix a Bug** -- investigation, root cause analysis, and fix
- **Quick Spec** -- lightweight planning without full requirements formalization

## Portability

Specs are stored in `.kiro/specs/` which is shared across all Kiro surfaces. Start a spec in the CLI, continue it in the IDE. The file format is identical.

## Learn more

For the full specs reference, see the IDE documentation:

- [Feature Specs](https://kiro.dev/docs/specs/feature-specs.md) -- requirements-first and design-first workflows
- [Bugfix Specs](https://kiro.dev/docs/specs/bugfix-specs.md) -- bug investigation and fix workflows

> ## Documentation Index
>
> Fetch the complete documentation index at: <https://kiro.dev/llms.txt>
> Use this file to discover all available pages before exploring further.

# Permissions

> Capability-based permissions model for fine-grained control over what the agent can do in CLI 3.0.

## Overview

Permissions give you declarative, auditable control over what the agent can do. Write one rule to allow `npm *` commands, and it applies everywhere -- no more pressing "y" on every shell invocation. Write one deny rule for `.env` files, and all read tools respect it simultaneously. Rules are portable across Kiro IDE and CLI because the same engine enforces them on both surfaces.

## Rule structure

Each rule has four fields:

| Field | Description | Required |
|-------|-------------|----------|
| `capability` | The operation type being controlled | Yes |
| `match` | Glob patterns the resource must match | No (defaults to all) |
| `exclude` | Glob patterns that exempt a resource from the rule | No |
| `effect` | `deny`, `ask`, or `allow` | Yes |

Effects resolve by restrictiveness: **deny > ask > allow**. A more permissive rule can never override a more restrictive one, regardless of which scope it comes from.

## Where rules live

| Scope | Location | Allowed effects |
|-------|----------|-----------------|
| User | `~/.kiro/settings/permissions.yaml` | deny, ask, allow |
| Workspace | `~/.kiro/workspace-roots/<hash>/permissions.yaml` | deny, ask, allow |

Workspace permissions are stored **per-user outside the repository** at `~/.kiro/workspace-roots/<hash(workspaceRoot)>/`. A cloned repo cannot inject permission rules. Trust is something you configure on your own machine.

## Example configuration

Create `~/.kiro/settings/permissions.yaml`:

```yaml
rules:
  - capability: shell
    effect: allow
    match:
      - git *
      - npm *
      - npx *
  - capability: fs_write
    effect: allow
    match:
      - src/**
      - tests/**
  - capability: fs_read
    effect: allow
  - capability: mcp
    effect: allow
    match:
      - my-server/*
```

For CI pipelines that need full tool access:

```yaml
rules:
  - capability: all
    effect: allow
```

## Default behavior

Without any configuration, the default agent policy allows:

- `fs_read` on `./**` -- read any file in the workspace
- `shell` for common read-only git commands (`git status`, `git log`, `git diff`, `git branch`, etc.)
- `shell` for system info commands (`pwd`, `whoami`, `uname`, etc.)
- Utility tools (diagnostics, knowledge, etc.)

The Kiro scope (hardcoded, cannot be overridden) enforces:

- **Always denied:** Writes to `~/.kiro/settings/`, `.kiro/settings/`, and `~/.kiro/workspace-roots/` (prevents the agent from modifying its own permission files)
- **Always asks:** Writes to `.git/**`, `.kiro/agents/**`, `.kiro/hooks/**`, `.kiroignore`

Everything else prompts for approval. Creating a `permissions.yaml` adds to these defaults.

## Available capabilities

| Capability | What it controls |
|-----------|-----------------|
| `fs_read` | Reading files, listing directories, searching |
| `fs_write` | Writing, editing, deleting files |
| `filesystem` | Shorthand for `fs_read` + `fs_write` |
| `shell` | Executing commands |
| `web_fetch` | Fetching URLs |
| `web_search` | Web search |
| `mcp` | MCP server tool calls (pattern: `server/tool`) |
| `subagent` | Subagent delegation |
| `skill` | Skills activation |
| `diagnostics` | Diagnostics tools |
| `context` | Context and steering tools |
| `all` | Every capability (meta) |
| `builtin` | All built-in tools (meta) |

## Pattern matching

Rules use glob patterns. The syntax differs by capability type:

**Filesystem patterns** (`fs_read`, `fs_write`):

- `*` matches within a single path component
- `**` matches across path separators
- `` brace expansion and `[abc]` character classes are supported
- Patterns without wildcards implicitly match children: `~/temp` matches `~/temp/child`

**Shell, web, MCP patterns:**

- `*` matches any sequence of characters
- `**`, `?`, and character classes are not supported

```yaml
rules:
  # Allow npm commands except npm publish
  - capability: shell
    effect: allow
    match:
      - "npm *"
    exclude:
      - "npm publish*"

  # Deny reads to secrets at any depth
  - capability: fs_read
    effect: deny
    match:
      - "**/.env"
      - "**/.env.*"
      - "secrets/**"
      - "**/*.pem"

  # Allow a specific MCP server
  - capability: mcp
    effect: allow
    match:
      - "corp-tools/*"
```

## Shell-specific behavior

Shell commands are parsed before pattern matching. Compound commands (using `;`, `&&`, `||`, `|`) are split and each sub-command is evaluated independently. This prevents a rule for `npm test *` from accidentally matching `npm test ; curl attacker.com`.

> ## Documentation Index
>
> Fetch the complete documentation index at: <https://kiro.dev/llms.txt>
> Use this file to discover all available pages before exploring further.

# Hooks

> Standalone hook files with new triggers and action types in CLI 3.0.

## Overview

Hooks in v3 are standalone files with a versioned schema, two action types (shell commands and agent prompts), and new lifecycle triggers for specs, file deletion, and manual invocation. You define them once in `.kiro/hooks/` and they apply across all agents in the workspace.

Existing embedded hooks in agent configs still work during the transition. Run `kiro-cli agent migrate` to auto-convert them to the new format.

## The new format

Each hooks file is a standalone `.kiro/hooks/<name>.json`:

```json
{
  "version": "v1",
  "hooks": [
    {
      "name": "lint-on-save",
      "trigger": "PostFileSave",
      "matcher": "\\.ts$",
      "action": { "type": "command", "command": "npm run lint" },
      "timeout": 30,
      "enabled": true
    },
    {
      "name": "remind-tests",
      "trigger": "PreToolUse",
      "matcher": "fs_write|str_replace",
      "action": { "type": "agent", "prompt": "Ensure tests are updated for this change" }
    }
  ]
}
```

**Two action types:**

- **Command** -- runs a shell command. Receives hook context as JSON on stdin. Exit code determines behavior (0 = success, 2 = block for PreToolUse/UserPromptSubmit).
- **Agent** -- appends a prompt string to the model context. No subprocess spawned. Use for lightweight steering and guardrails.

## Trigger reference

| Trigger | Fires when | Matcher matches | Can block? |
|---------|-----------|-----------------|:----------:|
| `SessionStart` | Session begins | -- | No |
| `Stop` | Session ends | -- | No |
| `PreToolUse` | Before tool executes | Tool name (regex) | Yes |
| `PostToolUse` | After tool executes | Tool name (regex) | No |
| `PreTaskExec` | Before a spec task starts | -- | Yes |
| `PostTaskExec` | After a spec task finishes | -- | No |
| `UserPromptSubmit` | User submits a prompt | -- | Yes |
| `PostFileCreate` | After a file is created | File path (regex) | No |
| `PostFileSave` | After a file is saved | File path (regex) | No |
| `PostFileDelete` | After a file is deleted | File path (regex) | No |
| `Manual` | User-triggered on demand | -- | No |

## Trigger name mapping (2.x to 3.0)

| Old trigger | New trigger | Notes |
|-------------|-------------|-------|
| `agentSpawn` | `SessionStart` | Fires when a new session begins |
| `userPromptSubmit` | `UserPromptSubmit` | Case change only |
| `preToolUse` | `PreToolUse` | Case change only |
| `postToolUse` | `PostToolUse` | Case change only |
| `fileEdited` | `PostFileSave` | Renamed for clarity |
| `fileCreated` | `PostFileCreate` | Renamed for clarity |
| `stop` | `Stop` | Case change only |

**New in 3.0:** `PreTaskExec`, `PostTaskExec`, `PostFileDelete`, `Manual`

## Matcher semantics

The `matcher` field is a regex pattern. What it matches depends on the trigger:

| Trigger | Matcher evaluates against |
|---------|--------------------------|
| `PostFileSave`, `PostFileCreate`, `PostFileDelete` | File path |
| `PreToolUse`, `PostToolUse` | Tool name |
| `UserPromptSubmit` | Prompt text |
| `SessionStart`, `Stop`, `PreTaskExec`, `PostTaskExec`, `Manual` | Not evaluated -- hook always fires |

Regex patterns from 2.x transfer directly. The `}` template variable is available in command actions for file-related triggers.

## Hook fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | Yes | -- | Identifier shown in telemetry |
| `description` | string | No | -- | Documentation only |
| `trigger` | string | Yes | -- | When the hook fires |
| `matcher` | regex string | No | always-match | Filters by tool name or file path |
| `action` | object | Yes | -- | `` or `` |
| `timeout` | integer (seconds) | No | 60 | 0 disables timeout. Ignored for agent actions |
| `enabled` | boolean | No | true | Set false to skip without deleting |

## Exit code behavior

For command actions:

| Exit code | Behavior |
|-----------|----------|
| `0` | Success. STDOUT added to context (SessionStart, UserPromptSubmit) or ignored (others) |
| `2` | Block execution (PreToolUse, UserPromptSubmit only). STDERR returned to LLM |
| Other | Warning shown to user. Tool execution proceeds |

## Next steps

- [Agent config](https://kiro.dev/docs/cli/v3/agent-config.md) -- agent profile format and tags
- [Permissions](https://kiro.dev/docs/cli/v3/permissions.md) -- capability-based permission model

> ## Documentation Index
>
> Fetch the complete documentation index at: <https://kiro.dev/llms.txt>
> Use this file to discover all available pages before exploring further.

# Agent config

> Tag-based tools, unified permissions, Markdown format, and new fields in CLI 3.0 agent profiles.

## Overview

Agent profiles in v3 are self-contained and portable. Write a Markdown file with your system prompt as the body, declare tool categories with tags, embed MCP servers and permissions inline, and share the file across your team via version control. When new tools ship under a category, your agent picks them up automatically.

## The Markdown format

Your system prompt becomes the document body. Configuration lives in YAML frontmatter:

```markdown
---
description: Backend development agent
model: claude-sonnet-4
tools: [read, write, shell, web]
mcpServers:
  postgres:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-postgres"]
    env:
      DATABASE_URL: "${DATABASE_URL}"
resources:
  - file://./ARCHITECTURE.md
  - skill://backend-patterns
permissions:
  rules:
    - capability: shell
      effect: allow
      match:
        - "npm *"
        - "node *"
welcomeMessage: "Ready to work on backend code."
---

You are a backend developer focused on Node.js and TypeScript.
Always use async/await. All database queries must be parameterized.
```

JSON format is equivalent. Use Markdown when your system prompt is long; JSON when generating configs programmatically.

## Tags

The `tools` field accepts category tags. Each tag groups related capabilities so you don't need to enumerate individual tools:

| Tag | What it includes |
|-----|-----------------|
| `read` | File reading, directory listing, searching |
| `write` | File writing, editing, deleting |
| `shell` | Command execution and process management |
| `web` | Web fetching |
| `subagent` | Subagent delegation |
| `knowledge` | Knowledge base tools |
| `todo_list` | Task tracking |
| `@mcp` | All MCP tools from mcp.json |
| `@builtin` | All built-in tools |
| `*` | Everything |

## Permissions in agent profiles

The `permissions` field provides capability-based rules:

```yaml
permissions:
  rules:
    - capability: builtin
      effect: allow
    - capability: shell
      effect: deny
      match:
        - "rm *"
        - "sudo *"
    - capability: filesystem
      effect: deny
      match:
        - ".env"
        - "secrets/**"
```

When no rule matches a tool call, the default is `ask`. Effects resolve as deny > ask > allow. For the full permissions model, see [Permissions →](https://kiro.dev/docs/cli/v3/permissions.md).

## MCP servers inline

Define MCP servers directly in the agent profile so it's fully self-contained:

```yaml
mcpServers:
  local-server:
    command: npx
    args: ["-y", "@org/mcp-server"]
    env:
      API_KEY: "${API_KEY}"
    requestTimeout: 180000
  remote-server:
    url: https://api.example.com/mcp
    headers:
      Authorization: "Bearer ${TOKEN}"
```

Environment variables use `$` syntax and expand at runtime. Stdio servers support `timeout` (connection handshake, default 60s) and `requestTimeout` (per-call, default 120s). HTTP servers support `headers` and `oauth` for authenticated endpoints.

## File locations

- `.kiro/agents/` -- workspace-level agents (shared via version control, loaded only if workspace is trusted)
- `~/.kiro/agents/` -- user-level agents (available across all projects)

Nested directories are supported. The agent name is the path relative to the agents directory without the extension: `~/.kiro/agents/team/planner.md` becomes `team/planner`.

## Upgrading older configs

If you have agents created before v3, the [`/upgrade-agent`](https://kiro.dev/docs/cli/v3/upgrade-agent.md) command converts them in place. It adds the new permission fields alongside your existing configuration and backs up originals before writing.

## Next steps

- [Permissions](https://kiro.dev/docs/cli/v3/permissions.md) -- full capability and scope reference
- [Hooks](https://kiro.dev/docs/cli/v3/hooks.md) -- standalone hooks format and trigger mapping

> ## Documentation Index
>
> Fetch the complete documentation index at: <https://kiro.dev/llms.txt>
> Use this file to discover all available pages before exploring further.

# Upgrading agent configs

> Migrate older agent configurations to the v3 format with tag-based tools and unified permissions

CLI 3.0 agent profiles use [tag-based tools and unified permissions](https://kiro.dev/docs/cli/v3/agent-config.md). If you have agents created before this format was introduced, the `/upgrade-agent` command converts them in place. It adds the new permission fields alongside your existing configuration and backs up originals before writing.

Run it once, pick which agents to upgrade, and you're done. You can run it any time you spot older fields like `toolsSettings` or `allowedTools` in your configs.

## Usage

```bash
# Scan agents and open the selection menu
/upgrade-agent

# Same as above (explicit subcommand)
/upgrade-agent run

# Review previously upgraded agents and any conversion warnings
/upgrade-agent diagnostics
```

The `run` subcommand (default) scans `.kiro/agents/` in your workspace and `~/.kiro/agents/` globally, then shows a selection menu grouped by scope. Only agents that need upgrading appear. Agents already in the latest format are hidden.

## What happens during upgrade

When you select a group of agents to upgrade:

1. Each original file is copied to `<filename>.json.bak` as a backup
2. New-format permission fields are added alongside your existing configuration
3. Your original settings (tool names, allowed commands, path restrictions) are preserved with equivalent rules in the new format
4. A confirmation alert shows how many agents were upgraded

If a backup file already exists, numbered suffixes are used (`.bak.1`, `.bak.2`, etc.).

### Reverting an upgrade

If you want to undo the upgrade, rename the `.json.bak` file back to `.json`:

```bash
mv .kiro/agents/my-agent.json.bak .kiro/agents/my-agent.json
```

## What gets converted

The upgrade translates your existing permission settings into the v3 format:

- **Tool names:** Old names (like `fs_read`, `execute_bash`) are mapped to v3 capability tags (like `read`, `shell`). Both are preserved for compatibility.
- **`toolsSettings`:** Per-tool allow/deny rules become `permissions.rules` entries with capability, match pattern, and effect.
- **`allowedTools`:** Trusted-tool entries become capability-level allow rules.
- **Regex patterns:** Regex patterns are translated to simple wildcard globs where possible. Complex patterns that can't be safely converted generate a warning.
- **`autoAllowReadonly`:** Converts to a read-only-shell policy.
- **Object-form hooks:** Converted to the array format the v3 schema requires.

All other fields (`name`, `description`, `model`, `prompt`, `resources`, `mcpServers`, `welcomeMessage`) pass through unchanged.

## Example

Here's a typical first run. You have 3 workspace agents and 1 global agent in older formats:

```bash
/upgrade-agent
```

**Selection menu:**

```text
V2 [3 agents]               Workspace    Upgrade to universal (V2 + V3) config
V2 [1 agent]                Global       Upgrade to universal (V2 + V3) config
```

Select "V2 [3 agents] - Workspace" to upgrade all 3 workspace-level agents. The "universal (V2 + V3)" label means the upgraded config retains your original fields for backward compatibility while adding newer permission rules.

**Post-upgrade alert:**

```text
Upgraded 3 agents (backed up to .json.bak)
```

## Reviewing diagnostics

Run diagnostics to check for conversion warnings, patterns that couldn't be perfectly translated:

```bash
/upgrade-agent diagnostics
```

```text
2 Universal agents

  my-agent     Workspace   ⚠ regex-shell-pattern: ^git\s
  strict-dev   Global      ⚠ deny-by-default-readonly
```

### Warning types

| Warning | Meaning | What to do |
|---------|---------|------------|
| `regex-shell-pattern` | A shell regex was approximated as a glob | Review the converted pattern in `permissions.rules` |
| `regex-web-pattern` | A URL regex was approximated as a glob | Review the converted URL pattern |
| `unconvertible-pattern` | A regex couldn't be safely converted | Manually add the rule to `permissions.rules` |
| `unmapped-allowed-tool` | A tool entry couldn't be mapped to a capability | Check if the tool has a new name or was removed |
| `deprecated-aws-tool` | `aws` / `use_aws` tool is deprecated | Remove the deprecated tool reference |
| `deny-by-default-readonly` | Conflicting deny-by-default and auto-allow-readonly settings | Review your permission intent and adjust manually |
| `file-prompt` | Absolute or `~/` file prompt paths may not resolve in all environments | Use relative paths instead |
| `unconvertible-hook` | A hook couldn't be converted to the new format | Recreate the hook using the supported trigger format |

## Agents that are skipped

The following are excluded from the scan:

- Backup files (`.bak`) are excluded from the scan
- Files that aren't valid agent configs (JSON files without `prompt`, `tools`, `hooks`, or permission fields) are ignored

## Troubleshooting

### No agents appear in the selection menu

All your agents are already in the latest format. Run `/upgrade-agent diagnostics` to review their current state.

### Warnings after upgrade

Some patterns can't be perfectly translated from regex to glob format. Run `/upgrade-agent diagnostics`, review the flagged agents, and manually edit the `permissions.rules` in the upgraded config if needed.

### Agent missing from the scan

Verify the file is valid JSON and contains at least a `prompt`, `tools`, or `hooks` field. Files that don't look like agent configurations are ignored.

## Related

- [Agent config](https://kiro.dev/docs/cli/v3/agent-config.md) for the v3 agent config format reference
- [Permissions](https://kiro.dev/docs/cli/v3/permissions.md) for the capability-based permission rules
- [Custom agents](https://kiro.dev/docs/cli/custom-agents.md) for creating and managing agents

> ## Documentation Index
>
> Fetch the complete documentation index at: <https://kiro.dev/llms.txt>
> Use this file to discover all available pages before exploring further.

# Feature comparison

> Feature-by-feature comparison between Kiro CLI 2.x and 3.0.

## Overview

Use this page to quickly assess which v3 changes affect your workflow.

## Feature status

| Feature | Status | Change from 2.x | Action needed |
|---------|:------:|-----------------|:-------------:|
| **Spec-driven development** | ✅ New | Built-in Spec agent | None |
| **Chat** | ✅ Available | Default chat mode | None |
| **Custom agents** | ⬆️ Enhanced | Tags replace tool lists; `toolsSettings` → `permissions` | [See docs →](https://kiro.dev/docs/cli/v3/agent-config.md) |
| **Steering** | ✅ Available | Front matter metadata added | None |
| **Hooks** | ⬆️ Enhanced | New JSON schema, standalone files, agent action type | [See docs →](https://kiro.dev/docs/cli/v3/hooks.md) |
| **Permissions** | ✅ New | Replaces trust flags | [See docs →](https://kiro.dev/docs/cli/v3/permissions.md) |
| **MCP servers** | ✅ Available | OAuth, disabledTools, autoApprove added | None |
| **Skills** | ✅ Available | Unchanged | None |
| **Trusted workspaces** | ✅ New | Workspace-level trust gating | None |
| **Code Intelligence** | ✅ Available | Client-vended LSP tool | None |
| **Knowledge** | ✅ Available | Semantic indexing | None |
| **aws_tool** | ❌ Removed | Use MCP servers | None |
| **Supervised mode** | ❌ Removed | Use permissions.yaml | [See docs →](https://kiro.dev/docs/cli/v3/permissions.md) |

## Tags reference

Tags in the `tools` field control which tools the agent can see:

| Tag | What it includes |
|-----|-----------------|
| `read` | File reading, directory listing, searching |
| `write` | File writing, editing, deleting |
| `shell` | Command execution and process management |
| `web` | Web fetching |
| `subagent` | Subagent delegation |
| `knowledge` | Knowledge base tools |
| `todo_list` | Task tracking |
| `@mcp` | All MCP server tools |
| `@builtin` | All built-in tools |
| `*` | Everything (no filtering) |

## Capabilities reference

Capabilities in the `permissions` field control what tools can do at invocation time:

| Capability | What it controls |
|-----------|-----------------|
| `fs_read` | Reading files, listing directories, searching |
| `fs_write` | Writing, editing, deleting files |
| `filesystem` | Shorthand for `fs_read` + `fs_write` |
| `shell` | Executing commands |
| `web_fetch` | Fetching URLs |
| `web_search` | Web search |
| `mcp` | MCP server tool calls (pattern: `server/tool`) |
| `subagent` | Subagent delegation |
| `skill` | Skills activation |
| `context` | Context and steering tools |
| `diagnostics` | Diagnostics tools |
| `builtin` | All built-in tools (meta) |
| `all` | Every capability (meta) |
