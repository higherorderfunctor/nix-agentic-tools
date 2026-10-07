# Human-reviewed disposition for every upstream Semble integration artifact.
# Hashes deliberately do not regenerate with the snapshot: a grouped package
# update must stop in CI until a reviewer decides whether each local derivative
# remains correct.
# All derivatives adopt 0.6.0's multi-repository guidance, resolve result labels,
# and allow verification and search refinement instead of upstream's search bans.
{
  mcpSurface = {
    disposition = "The MCP-backed agent prompt uses both Semble 0.6.0 tools, scalar or list repo inputs, and the per-call content selector. It preserves labeled paths for related searches and permits search refinement and caller verification. Complete descriptions and schemas are snapshotted; this projection records tool and argument names.";
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
      reviewedHash = "be2a43c6733d0f6b325610fc209dd03813f57ec7736c758ed0879e7fa0f5b47e";
    };
    "codex.toml" = {
      disposition = "semanticAgent lowers the shared fields to Codex TOML and deliberately omits the unsupported tools field.";
      reviewedHash = "9fee1f7778464ce2ef37512a26f35f91f4132eda42c3ff09336d1f40be050780";
    };
    "copilot.md" = {
      disposition = "semanticAgent uses the same Bash/Read restriction and reviewed CLI guidance as Claude.";
      reviewedHash = "be2a43c6733d0f6b325610fc209dd03813f57ec7736c758ed0879e7fa0f5b47e";
    };
    "kiro.md" = {
      disposition = "kiroAgent preserves Kiro's native shell/read restriction while sharing the reviewed CLI guidance.";
      reviewedHash = "8d786760c1899b17ec2206bcca2292b65653de2d965772545bec83c5b4337f60";
    };
  };
}
