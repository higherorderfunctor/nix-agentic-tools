let
  baseDescription = "Code search agent for exploring any codebase. Use for finding code by intent, locating implementations, understanding how something works, or discovering related code.";
  description = "${baseDescription} Prefer over Grep/Glob/Read for any semantic or exploratory question.";
  instructions = ../agent-instructions.md;
  instruction = {text = instructions;};
in {
  inherit instruction;

  kiroAgent = builtins.toJSON {
    description = "${baseDescription} Prefer over shell/read tools for any semantic or exploratory question.";
    prompt = builtins.readFile instructions;
    tools = ["shell" "read"];
  };

  kiroInstruction = instruction // {name = "semble";};

  semanticAgent = {
    inherit description instructions;
    tools = ["Bash" "Read"];
  };
}
