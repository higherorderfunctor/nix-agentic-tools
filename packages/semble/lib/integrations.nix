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
  # `models` is the resolved `cli.models` set. Routing guidance appears only
  # when a key other than `default` is enabled or `default` is disabled, so a
  # vanilla setup keeps the packaged instructions byte for byte.
  toList = value:
    if builtins.isList value
    then value
    else [value];
  expandContent = content:
    if builtins.elem "all" content
    then ["code" "config" "docs"]
    else content;
  contentOf = models: key: toList (models.${key}.content or ["code"]);
  enabledKeys = models:
    builtins.filter (key: models.${key}.enable or true) (builtins.attrNames models);
  routes = models:
    builtins.attrNames models
    != []
    && enabledKeys models != ["default"];

  routingBlock = command: models: let
    keys = enabledKeys models;
    ordered =
      builtins.filter (key: key == "default") keys
      ++ builtins.filter (key: key != "default") keys;
    invocation = key:
      if key == "default"
      then "${command} search"
      else "${command} --model ${key} search";
    description = key: let
      value = models.${key}.description or null;
    in
      if value == null
      then "Semble's built-in code model."
      else value;
    modelLine = key: "- `${invocation key}` (content: ${builtins.concatStringsSep " " (contentOf models key)}): ${description key}";
    defaultContent = expandContent (contentOf models "default");
    extraContent = key:
      builtins.filter (category: !(builtins.elem category defaultContent))
      (expandContent (contentOf models key));
    precedenceLine = key: let
      categories = extraContent key;
    in
      if key == "default" || categories == []
      then []
      else [
        "- Prefer `--model ${key}` over ${builtins.concatStringsSep " or " (map (category: "`--content ${category}`") categories)}."
      ];
    defaultDisabled = !(models.default.enable or true);
  in
    builtins.concatStringsSep "\n" (
      [
        "This setup has several Semble embedding models. Pick one per search by what you are looking for:"
        ""
      ]
      ++ map modelLine ordered
      ++ [
        ""
        "`--model` goes before the subcommand or after its arguments, like `--content`. It selects the model and that model's content; `--content` replaces the content for the call."
        ""
      ]
      ++ (
        if defaultDisabled
        then ["- Always pass `--model`: plain `${command} search` has no default model here."]
        else []
      )
      ++ builtins.concatMap precedenceLine ordered
      ++ [
        "- Pass the same `--model` (and `--content`) to `${command} find-related` as the search that returned its location."
        ""
        ""
      ]
    );

  mkCliRecords = command: models: let
    routed = routes models;
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
      then routingBlock command models + packaged
      else packaged;
  in {
    rule =
      if command == "semble" && !routed
      then {source = cliInstructions;}
      else {text = renderedInstructions;};
    kiroAgent = {
      description = baseDescription;
      prompt = mkTextSource renderedInstructions;
      tools = ["shell" "read"];
    };
    semanticAgent = {
      description = baseDescription;
      instructions = mkTextSource renderedInstructions;
      tools = ["Bash" "Read"];
    };
  };

  cli = mkCliRecords "semble" {};
  mcp = {
    kiroAgent = {
      description = baseDescription;
      prompt = mkTextSource mcpInstructions;
      tools = ["@semble"];
    };
    semanticAgent = {
      description = baseDescription;
      instructions = mkTextSource mcpInstructions;
      tools = claudeMcpTools;
    };
  };
in
  cli
  // {
    inherit cli mcp mcpTools;
    forCommand = command: mkCliRecords command {};
    # `models` is a resolved `cli.models` set; see the routing notes above.
    forCli = {
      command ? "semble",
      models ? {},
    }:
      mkCliRecords command models;
  }
