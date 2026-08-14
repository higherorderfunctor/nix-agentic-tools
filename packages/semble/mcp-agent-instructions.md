Use `mcp__semble__search` to find code by describing what it does or naming a
symbol or identifier, instead of Grep or Glob. Pass the project root as `repo`;
an `https://` git URL works for a remote repository.

The index is built on the first call and cached, so repeat queries are fast.

Which content categories this server searches is fixed when it starts, so there
is nothing to select per call.

Use `mcp__semble__find_related` to discover code similar to a known location.
Pass the `file_path` and `line` from a prior result together with the same
`repo`.

### Workflow

1. Call `mcp__semble__search` with a query describing what the code does or its
   name. Write queries as function or class names, or as descriptions of
   behaviour — not as error messages.
2. Navigate directly to the returned file and line. Read only the function or
   class at that location. Do not re-search for the same content.
3. Raise `top_k` to widen the result set. Set `max_snippet_lines` higher, or to
   null for the whole chunk, when a snippet does not carry enough context to
   confirm the location.
4. Optionally call `mcp__semble__find_related` with a promising result's
   `file_path` and `line` to discover related implementations.
5. Use Grep only when you need every occurrence of a literal string across the
   whole repository, such as all callers of a renamed function.
