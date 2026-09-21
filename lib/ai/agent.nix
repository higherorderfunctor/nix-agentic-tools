{lib}: let
  aiTypes = import ./types.nix {inherit lib;};
  resolveText = value:
    if builtins.isPath value
    then builtins.readFile value
    else value;

  mkSemanticAgentType = codexType:
    lib.types.submodule {
      options = {
        codex = lib.mkOption {
          type = codexType;
          default = {};
          description = "Codex-native TOML settings layered onto the generated standalone agent file.";
        };
        description = lib.mkOption {
          type = lib.types.str;
          description = "Human-facing guidance for selecting the agent.";
        };
        instructions = lib.mkOption {
          type = aiTypes.textSource {
            description = "core instructions defining the agent's behavior";
          };
          description = "Core instructions defining the agent's behavior.";
        };
        tools = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.str);
          default = null;
          description = "Optional Claude/Copilot tool allowlist; Codex has no equivalent agent field.";
        };
      };
    };

  semanticAgentType = mkSemanticAgentType lib.types.attrs;

  isSemantic = value: builtins.isAttrs value && value ? description && value ? instructions;

  renderMarkdown = {
    includeName,
    name,
    value,
  }:
    if !isSemantic value
    then value
    else ''
      ---
      ${lib.optionalString includeName "name: ${builtins.toJSON name}\n"}description: ${builtins.toJSON value.description}
      ${lib.optionalString ((value.tools or null) != null && value.tools != []) "tools: ${lib.concatStringsSep ", " value.tools}\n"}---

      ${value.instructions.text}
    '';

  renderCodex = name: value:
    value.codex
    // {
      inherit (value) description;
      developer_instructions = value.instructions.text;
      inherit name;
    };
in {
  inherit isSemantic mkSemanticAgentType renderCodex semanticAgentType;

  agentType = lib.types.either (lib.types.either lib.types.lines lib.types.path) semanticAgentType;

  renderClaude = name: value:
    renderMarkdown {
      includeName = true;
      inherit name value;
    };

  renderCopilot = name: value:
    if !isSemantic value && builtins.isPath value
    then resolveText value
    else
      renderMarkdown {
        includeName = false;
        inherit name value;
      };
}
