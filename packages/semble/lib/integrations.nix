let
  baseDescription = "Code search agent for exploring any codebase. Use for finding code by intent, locating implementations, understanding how something works, or discovering related code.";
  description = "${baseDescription} Prefer over Grep/Glob/Read for any semantic or exploratory question.";
  instructions = ../agent-instructions.md;
  rule = {source = instructions;};
in {
  inherit rule;

  # A TYPED `ai.kiro.agents` record (see `kiroAgentRecord` in
  # packages/kiro-cli/lib/mkKiro.nix) — no longer pre-rendered JSON.
  #
  # `name` is deliberately absent. The typed option defaults it to the
  # attribute key the record is written under, which is the single source of
  # truth for both the filename and the id Kiro registers, so the two can no
  # longer disagree. That default is also what makes the field impossible to
  # omit: Kiro's Rust CLI REQUIRES `name` and rejects an agent file without it
  # on every invocation, while the Node/ACP parser treats it as optional and
  # falls back to the filename — which is why the omission was invisible from
  # the IDE side until it surfaced as CLI noise.
  #
  # `prompt` stays a Nix path; the option coerces it with `readFile`, so the
  # instructions are inlined rather than referenced as a store path.
  kiroAgent = {
    description = "${baseDescription} Prefer over shell/read tools for any semantic or exploratory question.";
    prompt = instructions;
    tools = ["shell" "read"];
  };

  semanticAgent = {
    inherit description instructions;
    tools = ["Bash" "Read"];
  };
}
