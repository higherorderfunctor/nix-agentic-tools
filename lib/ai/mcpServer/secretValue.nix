# Typed shape for an MCP http `headers.<name>` or `url` value that may be
# either a plaintext string (baked into the world-readable store) or a
# runtime SOPS/agenix credential kept out of it.
#
# HEADERS AND URL TAKE DIFFERENT DELIVERY PATHS, because Kiro (verified
# against 2.13.0) env-substitutes header values but NOT the `url` field:
#
#   * header → rendered as a `${env:VAR}` placeholder that Kiro itself
#     expands at launch, from a var the wrapper exported (wrapPackage.nix).
#   * url    → Kiro would emit the placeholder literally, so WE substitute
#     it at activation instead: `envsubst` assembles a real, private
#     mcp.json with an explicit var list, leaving header placeholders
#     intact. See `mkMcpJsonScript` / `ai.kiro.mcpWriteMode` in mkKiro.nix.
#
# Either way the secret VALUE never enters the store — only its file path.
#
# Mirrors the file/helper credential union used by packaged MCP servers
# (see `mkCredentialsOption` in lib/mcp.nix) and adds `prefix`/`suffix`
# (e.g. a literal "Bearer ") plus an optional explicit env-var name.
#
# The file XOR helper mutex (and the "exactly one set" rule) is NOT
# encoded in the type — a submodule cannot assert cleanly without a full
# module eval. It is enforced by an `if/throw` at render/collect time,
# matching the gitlab-mcp `instanceUrl` ⊕ `apiUrl` precedent.
#
# Rendering + env-var derivation + the wrapper export live in the shared
# `lib.ai` helpers so the placeholder written into mcp.json and the var
# the launcher exports are derived identically. Credential values are
# delivered for Kiro only (ai.kiro.mcpServers); other ecosystems throw.
lib: let
  inherit (lib) mkOption types;

  credential = types.submodule {
    options = {
      file = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path to a file containing the raw secret value, read at
          runtime and never baked into the store. Works with sops-nix,
          agenix, or any tool that decrypts a secret to a file.
          Mutually exclusive with `helper`.
        '';
      };
      helper = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Absolute path to an executable that prints the raw secret value
          on stdout, run at launch. Mutually exclusive with `file`.
        '';
      };
      prefix = mkOption {
        type = types.str;
        default = "";
        description = ''
          Literal text placed before the injected secret in the rendered
          value, e.g. `"Bearer "` for an `Authorization` header.
        '';
      };
      suffix = mkOption {
        type = types.str;
        default = "";
        description = "Literal text placed after the injected secret in the rendered value.";
      };
      var = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Explicit environment-variable name to inject through. When
          null, a deterministic name is derived from the server and
          field name (see `deriveMcpEnvVar` in lib/mcp.nix).
        '';
      };
    };
  };
in
  types.either types.str credential
