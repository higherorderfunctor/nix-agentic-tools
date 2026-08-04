let
  baseDescription = "Code search agent for exploring any codebase. Use for finding code by intent, locating implementations, understanding how something works, or discovering related code.";
  description = "${baseDescription} Prefer over Grep/Glob/Read for any semantic or exploratory question.";
  instructions = ../agent-instructions.md;
  instruction = {text = instructions;};
in {
  inherit instruction;

  # Kiro 2.16.0 validates agent files through TWO independent parsers, and
  # only one of them tolerates a missing `name` — so this field is not
  # optional in practice:
  #   * Rust CLI (kiro-cli-chat) — JSON-only, and `name` is REQUIRED. Without
  #     it the CLI rejects the whole file with "missing field name" on EVERY
  #     invocation, so the agent never loads on that surface at all.
  #   * Node/ACP bundle (acp-server.js) — `name` is `.optional()`, documented
  #     as "explicit agent name that overrides filename-based ID", so that
  #     path silently falls back to the filename stem and works either way.
  # Setting it satisfies the strict parser and changes nothing for the lenient
  # one, because the value equals the `agents.semble-search` attr key that
  # `modules/common.nix` writes the file under — the filename-derived id and
  # this explicit override resolve to the SAME id. Keep the two in sync;
  # `checks/module-eval.nix` binds them together.
  kiroAgent = builtins.toJSON {
    description = "${baseDescription} Prefer over shell/read tools for any semantic or exploratory question.";
    name = "semble-search";
    prompt = builtins.readFile instructions;
    tools = ["shell" "read"];
  };

  kiroInstruction = instruction // {name = "semble";};

  semanticAgent = {
    inherit description instructions;
    tools = ["Bash" "Read"];
  };
}
