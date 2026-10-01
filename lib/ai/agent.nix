{lib}: let
  aiTypes = import ./types.nix {inherit lib;};
  frontmatter = import ../frontmatter.nix {inherit lib;};

  # The normalized agent record `ai.agents.<name>` takes, and the normalized
  # arm of every `ai.<runtime>.agents.<name>`. It carries no runtime-native
  # field: a runtime's own settings belong on its typed
  # `ai.<runtime>.native.agents.<name>` record, which the runtime's
  # transformer lowers this record into.
  #
  # A bare submodule also admits a path, as a module file to import, so a
  # root `ai.agents.<name> = ./agent.md` would be parsed as Nix and fail with
  # a syntax error that `builtins.tryEval` cannot catch. A path is turned into
  # a thrown message instead; a string already fails the submodule type check.
  semanticAgentRecord = lib.types.submodule {
    options = {
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
        description = "Optional Claude/Copilot tool allowlist. Runtimes without a matching field or with a different tool vocabulary do not lower it: Codex, Kimchi and Kiro drop it with a warning. Codex has no equivalent field; for Kimchi and Kiro the warning names the native form (native Markdown at `ai.kimchi.agents.<name>`, or `ai.kiro.native.agents.<name>.tools`).";
      };
    };
  };
  semanticAgentType =
    lib.types.coercedTo lib.types.path (path:
      throw "An agent given as the path ${toString path} is a native file, which a normalized agent record cannot hold. Put it on ai.<runtime>.agents.<name> or in ai.<runtime>.agentsDir, or write a { description, instructions } record.")
    semanticAgentRecord
    // {inherit (semanticAgentRecord) description descriptionClass;};

  isSemantic = value: builtins.isAttrs value && value ? description && value ? instructions;

  # Home Manager's `lib.hm.strings.isPathLike`, used to choose `source` over
  # `text`: a path, a string under the store, or a derivation. Deciding any
  # other way lands a store-path string such as a flake input's
  # `"${src}/agent.md"` as a file containing that path.
  isPathLike = value:
    builtins.isPath value
    || (builtins.isString value && lib.hasPrefix "${builtins.storeDir}/" value)
    || lib.isDerivation value;

  # A rendered agent as file content: a path-like value is copied as a
  # `source`, anything else is the file's `text`.
  fileContent = rendered:
    if isPathLike rendered
    then {source = rendered;}
    else {text = rendered;};

  frontmatterFields = includeName: name: value:
    lib.optionalAttrs includeName {inherit name;}
    // {inherit (value) description;}
    // lib.optionalAttrs ((value.tools or null) != null && value.tools != []) {
      tools = lib.concatStringsSep ", " value.tools;
    };

  renderMarkdown = {
    includeName,
    name,
    value,
  }:
    if !isSemantic value
    then value
    else
      (frontmatter.render {
        data = frontmatterFields includeName name value;
        body = value.instructions.text + "\n";
      }).text;

  renderFile = includeName: name: value:
    if isSemantic value
    then
      frontmatter.content (frontmatter.render {
        data = frontmatterFields includeName name value;
        body = value.instructions.text + "\n";
      })
    else fileContent value;

  # A text source that crossed the pool boundary carries one arm, so its
  # text is either inline or the source file's bytes.
  instructionsText = instructions:
    if aiTypes.textSourceUsesSource instructions
    then builtins.readFile instructions.source
    else instructions.text;

  # Transformers: one normalized record (instructions with one text-source
  # arm) to the runtime's native agent record. Neither sets `name`: the
  # native side is its only source, defaulting it to the attribute key.
  renderCodex = _: value: {
    inherit (value) description;
    developer_instructions = instructionsText value.instructions;
  };

  # Kiro's `prompt` is a text source itself, so the one-arm record passes
  # through. `tools` is not lowered: Kiro takes capability tags, not the
  # Claude/Copilot tool names this record carries.
  renderKiro = _: value: {
    inherit (value) description;
    prompt = value.instructions;
  };
in {
  inherit fileContent isPathLike isSemantic renderCodex renderFile renderKiro semanticAgentType;

  # A per-runtime `ai.<runtime>.agents.<name>` entry: the normalized record,
  # or a raw native file (text or path) in that runtime's own format.
  agentType = lib.types.either (lib.types.either lib.types.lines lib.types.path) semanticAgentType;

  renderClaude = name: value:
    renderMarkdown {
      includeName = true;
      inherit name value;
    };

  # Kimchi names an agent by its filename and reads no `name:` key
  # (src/extensions/agents/personas/custom-agents.ts:52). A non-semantic value
  # is returned unchanged, so a path stays a path for the caller to deliver.
  renderKimchi = name: value:
    renderMarkdown {
      includeName = false;
      inherit name value;
    };

  # A file entry is read, not rendered: `isPathLike` rather than
  # `builtins.isPath`, so a store-path string (a flake input's
  # `"${src}/agent.md"`, or any entry of an `agentsDir` given as a string)
  # delivers the file's contents instead of its path as the body.
  renderCopilot = name: value:
    if !isSemantic value && isPathLike value
    then builtins.readFile value
    else
      renderMarkdown {
        includeName = false;
        inherit name value;
      };
}
