# Human-reviewed disposition for every upstream Semble integration artifact.
# Hashes deliberately do not regenerate with the snapshot: an llm-agents input
# bump must stop in CI until a reviewer decides whether each local derivative
# remains correct.
{
  instructions = {
    disposition = "The module intentionally ships CLI guidance; the MCP server contributes its tool guidance at session start.";
    reviewedHash = "9320c3e867f2c3bd7c79357d0ad99c236c2dc7d020a5e1c3554b9f16256c2a80";
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
