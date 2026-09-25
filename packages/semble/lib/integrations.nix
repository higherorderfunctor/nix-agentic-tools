let
  baseDescription = "Code search agent for exploring any codebase. Use for finding code by intent, locating implementations, understanding how something works, or discovering related code.";
  cliInstructions = ../cli-instructions.md;
  mcpInstructions = ../mcp-agent-instructions.md;

  mcpTools = {
    find_related = ["content" "file_path" "line" "repo"];
    search = ["content" "max_snippet_lines" "query" "repo" "top_k"];
  };
  claudeMcpTools = map (tool: "mcp__semble__${tool}") (builtins.attrNames mcpTools);
  mkTextSource = value:
    if builtins.isPath value
    then {source = value;}
    else {text = value;};

  # ── Model routing ──────────────────────────────────────────────
  # `routing` is `{ models; defaultContent; }` from the resolved program
  # config. Routing guidance appears only when an enabled model exists or the
  # default content is not upstream's `code`, so a vanilla setup keeps the
  # packaged instructions byte for byte.
  toList = value:
    if builtins.isList value
    then value
    else [value];
  sortStrings = builtins.sort builtins.lessThan;
  # Matches customization.nix: "all" routes like the three categories.
  expand = content:
    if builtins.elem "all" content
    then ["code" "config" "docs"]
    else sortStrings content;
  shownContent = content: builtins.concatStringsSep " " (sortStrings (toList content));
  enabledModels = routing: builtins.filter (entry: entry.enable or true) (routing.models or []);
  defaultContentOf = routing: toList (routing.defaultContent or ["code"]);
  routes = routing:
    enabledModels routing
    != []
    || expand (defaultContentOf routing) != ["code"];
  withoutPeriod = text: let
    trimmed = builtins.match "(.*)\\.$" text;
  in
    if trimmed == null
    then text
    else builtins.head trimmed;

  routingBlock = command: routing: let
    models = enabledModels routing;
    defaultContent = defaultContentOf routing;
    modelLine = entry: let
      plain =
        if expand (toList entry.content) == expand defaultContent
        then " (plain `${command} search`)"
        else "";
      description =
        if (entry.description or null) == null
        then ""
        else ": ${entry.description}";
    in "- `--content ${shownContent entry.content}`${plain}${description}";
  in
    builtins.concatStringsSep "\n" (
      [
        "Plain `${command} search` in this setup searches `${shownContent defaultContent}`. `--content` replaces that set for one call."
      ]
      ++ (
        if models == []
        then []
        else
          [
            ""
            "Each content set below has its own embedding model, used when the call's set matches exactly:"
            ""
          ]
          ++ map modelLine models
          ++ [
            ""
            "Any other set uses the default model, and the CLI prints a warning. Pass `${command} find-related` the same `--content` as the search that returned its location."
          ]
      )
      ++ ["" ""]
    );

  # Mentions the configured models so delegation can match questions about
  # their content, prose included.
  agentDescription = routing: let
    models = enabledModels routing;
    item = entry:
      "--content ${shownContent entry.content}"
      + (
        if (entry.description or null) == null
        then ""
        else " (${withoutPeriod entry.description})"
      );
  in
    if models == []
    then baseDescription
    else "${baseDescription} This setup has dedicated embedding models for ${builtins.concatStringsSep "; " (map item models)}.";

  mkCliRecords = command: routing: let
    routed = routes routing;
    packaged =
      if command == "semble"
      then builtins.readFile cliInstructions
      else
        builtins.replaceStrings
        ["semble search" "semble find-related"]
        ["${command} search" "${command} find-related"]
        (builtins.readFile cliInstructions);
    renderedInstructions =
      if command == "semble" && !routed
      then cliInstructions
      else if routed
      then routingBlock command routing + packaged
      else packaged;
    description = agentDescription routing;
  in {
    rule =
      if command == "semble" && !routed
      then {source = cliInstructions;}
      else {text = renderedInstructions;};
    kiroAgent = {
      inherit description;
      prompt = mkTextSource renderedInstructions;
      tools = ["shell" "read"];
    };
    semanticAgent = {
      inherit description;
      instructions = mkTextSource renderedInstructions;
      tools = ["Bash" "Read"];
    };
  };

  mkMcpRecords = routing: let
    description = agentDescription routing;
  in {
    kiroAgent = {
      inherit description;
      prompt = mkTextSource mcpInstructions;
      tools = ["@semble"];
    };
    semanticAgent = {
      inherit description;
      instructions = mkTextSource mcpInstructions;
      tools = claudeMcpTools;
    };
  };

  cli = mkCliRecords "semble" {};
  mcp = mkMcpRecords {};
in
  cli
  // {
    inherit cli mcp mcpTools;
    forCommand = command: mkCliRecords command {};
    # `routing` is `{ models; defaultContent; }`; see the routing notes above.
    forCli = {
      command ? "semble",
      routing ? {},
    }:
      mkCliRecords command routing;
    forMcp = mkMcpRecords;
  }
