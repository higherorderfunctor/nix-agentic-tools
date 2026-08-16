# Human-reviewed disposition for every upstream Semble integration artifact.
# Hashes deliberately do not regenerate with the snapshot: an llm-agents input
# bump must stop in CI until a reviewer decides whether each local derivative
# remains correct.
{
  mcpSurface = {
    disposition = "The MCP-backed agent prompt uses both Semble 0.5.5 tools and their per-call content selector; the complete tools/list descriptions and schemas are snapshotted, while this projection records the prompt's reviewed dependencies.";
    reviewedTools = {
      find_related = {
        arguments = ["content" "file_path" "line" "max_snippet_lines" "repo" "top_k"];
        required = ["file_path" "line" "repo"];
      };
      search = {
        arguments = ["content" "max_snippet_lines" "query" "repo" "top_k"];
        required = ["query" "repo"];
      };
    };
  };
  templates = {
    "claude.md" = {
      disposition = "semanticAgent preserves the Bash/Read restriction and reviewed CLI guidance without the uvx fallback.";
      reviewedHash = "73d4f7009c684a3b41417970c7da90b3b7cce93874d7bc3847a31965e8d02acf";
    };
    "codex.toml" = {
      disposition = "semanticAgent lowers the shared fields to Codex TOML and deliberately omits the unsupported tools field.";
      reviewedHash = "75221d3f2a61a29617a077f1168670fb9268815e2f8f43412405e2cf543d5a77";
    };
    "copilot.md" = {
      disposition = "semanticAgent uses the same Bash/Read restriction and reviewed CLI guidance as Claude.";
      reviewedHash = "73d4f7009c684a3b41417970c7da90b3b7cce93874d7bc3847a31965e8d02acf";
    };
    "kiro.md" = {
      disposition = "kiroAgent preserves Kiro's native shell/read restriction while sharing the reviewed CLI guidance.";
      reviewedHash = "f20e08221381e887a075ab54e4ab60a33cee2a9dfa83f58597f0ea11e9582fe8";
    };
  };
}
