# Static integration records. Deliberately takes NO arguments: it is exported
# as `lib.ai.semble` through the package barrel, so turning it into a function
# would break every consumer that reads `nat.lib.ai.semble.semanticAgent`.
# Anything that depends on configuration (the MCP server command, its content
# argv, agent-scoped `mcpServers`) is assembled in `modules/common.nix`, which
# has the evaluated config; everything here is a constant.
let
  baseDescription = "Code search agent for exploring any codebase. Use for finding code by intent, locating implementations, understanding how something works, or discovering related code.";

  # TWO SOURCE FILES, not one parameterized renderer, and the reason is that
  # they are different artifacts rather than two renderings of one.
  # `cli-instructions.md` is ALSO the always-loaded global instruction body
  # (`instruction.text` below), consumed by shell-capable root sessions;
  # `mcp-agent-instructions.md` is only ever a named agent's prompt. They share
  # two tool-agnostic sentences out of roughly forty lines, and even those
  # differ in tool noun (`grep` versus `Grep`). Extracting that would be the
  # premature abstraction the coding standard warns about, and it would couple
  # two texts whose audiences and lifecycles are meant to diverge.
  #
  # Both stay Nix PATHS. `lib/ai/agent.nix`'s `instructions` and Kiro's
  # `prompt` accept a string equally well, but a committed path keeps the
  # content out of the module graph and readable in place.
  cliInstructions = ../cli-instructions.md;
  mcpInstructions = ../mcp-agent-instructions.md;

  instruction = {text = cliInstructions;};

  # The upstream tool surface `mcp-agent-instructions.md` names. This is the
  # local dependency on Semble's MCP tools that `checks/semble-templates.nix`
  # gates: if upstream renames a tool or drops an argument used here, the
  # prompt is teaching a call that no longer exists. Sorted, and kept beside
  # the prompt so the two are edited together.
  mcpTools = {
    find_related = ["file_path" "line" "repo"];
    search = ["max_snippet_lines" "query" "repo" "top_k"];
  };

  # Claude and Copilot restrict an agent by TOOL NAME, in MCP's
  # `mcp__<server>__<tool>` spelling. The server is named `semble`.
  claudeMcpTools = map (tool: "mcp__semble__${tool}") (builtins.attrNames mcpTools);

  cli = {
    kiroAgent = {
      description = "${baseDescription} Prefer over shell/read tools for any semantic or exploratory question.";
      prompt = cliInstructions;
      tools = ["shell" "read"];
    };

    semanticAgent = {
      description = "${baseDescription} Prefer over Grep/Glob/Read for any semantic or exploratory question.";
      instructions = cliInstructions;
      tools = ["Bash" "Read"];
    };
  };

  mcp = {
    # Kiro's `tools` takes capability TAGS, not tool ids, and `@<server>` is
    # the tag for one MCP server's tools. Pairing it with `includeMcpJson =
    # false` (Kiro's own default) is what keeps an agent-scoped server from
    # being joined by the global pool; `modules/common.nix` sets that side.
    kiroAgent = {
      description = "${baseDescription} Prefer over shell/read tools for any semantic or exploratory question.";
      prompt = mcpInstructions;
      tools = ["@semble"];
    };

    semanticAgent = {
      description = "${baseDescription} Prefer over Grep/Glob/Read for any semantic or exploratory question.";
      instructions = mcpInstructions;
      tools = claudeMcpTools;
    };
  };
in {
  inherit cli instruction mcp mcpTools;

  # `semble.subagent.interface` is an enum whose values are exactly `cli` and
  # `mcp`, so the module selects a record set by indexing rather than branching.
  kiroInstruction = instruction // {name = "semble";};

  # The CLI records were the only ones before the interface split, and they are
  # what `lib.ai.semble.semanticAgent` / `.kiroAgent` name in published
  # examples. Aliased rather than duplicated so there is one definition.
  #
  # `kiroAgent.name` is deliberately absent. The typed `ai.kiro.agents` option
  # defaults it to the attribute key the record is written under, which is the
  # single source of truth for both the filename and the id Kiro registers, so
  # the two can no longer disagree. That default is also what makes the field
  # impossible to omit: Kiro's Rust CLI REQUIRES `name` and rejects an agent
  # file without it on every invocation, while the Node/ACP parser treats it as
  # optional and falls back to the filename — which is why the omission was
  # invisible from the IDE side until it surfaced as CLI noise.
  inherit (cli) kiroAgent semanticAgent;
}
