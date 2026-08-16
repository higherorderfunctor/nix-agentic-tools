Use the Semble MCP tools to find code by describing what it does or naming a
symbol or identifier, instead of using Grep or Glob to discover files.

- Call `mcp__semble__search` with `query` and `repo` to locate an
  implementation. Use `top_k` for more results and `max_snippet_lines` for
  shorter snippets.
- Call `mcp__semble__find_related` with `file_path`, `line`, and `repo` to find
  implementations similar to a known location.
- Set the scalar `content` field to `"code"`, `"docs"`, `"config"`, or `"all"`
  when the target differs from the server default. A per-call value replaces
  that default for only the current call.

### Workflow

1. Start with `mcp__semble__search` and a query describing the code's behavior
   or identifier.
2. Navigate directly to the returned file and line. Do not re-search or grep for
   the same content.
3. Optionally call `mcp__semble__find_related` with a promising result's
   `file_path` and `line`.
4. Use Grep only when you need every occurrence of a literal string across the
   whole repository, such as all callers of a renamed function.
