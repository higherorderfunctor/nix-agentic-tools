let
  baseDescription = "Code search agent for exploring any codebase. Use for finding code by intent, locating implementations, understanding how something works, or discovering related code.";
  cliInstructions = ../cli-instructions.md;
  mcpInstructions = ../mcp-agent-instructions.md;

  mcpTools = {
    find_related = ["content" "file_path" "line" "repo"];
    search = ["content" "max_snippet_lines" "query" "repo" "top_k"];
  };
  claudeMcpTools = map (tool: "mcp__semble__${tool}") (builtins.attrNames mcpTools);

  mkCliRecords = command: let
    renderedInstructions =
      if command == "semble"
      then cliInstructions
      else
        builtins.replaceStrings
        ["semble search" "semble find-related"]
        ["${command} search" "${command} find-related"]
        (builtins.readFile cliInstructions);
  in {
    rule =
      if command == "semble"
      then {source = cliInstructions;}
      else {text = renderedInstructions;};
    kiroAgent = {
      description = "${baseDescription} Prefer over shell/read tools for any semantic or exploratory question.";
      prompt = renderedInstructions;
      tools = ["shell" "read"];
    };
    semanticAgent = {
      description = "${baseDescription} Prefer over Grep/Glob/Read for any semantic or exploratory question.";
      instructions = renderedInstructions;
      tools = ["Bash" "Read"];
    };
  };

  cli = mkCliRecords "semble";
  mcp = {
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
in
  cli
  // {
    inherit cli mcp mcpTools;
    forCommand = mkCliRecords;
  }
