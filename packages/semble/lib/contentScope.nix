{lib}: let
  categories = ["all" "code" "config" "docs"];
  normalize = lib.sort (a: b: a < b);
in rec {
  inherit categories normalize;

  type = lib.types.coercedTo (lib.types.enum categories) lib.singleton (lib.types.listOf (lib.types.enum categories));
  default = ["code"];

  description = ''
    Default file-content categories for the Semble MCP server. A scalar is
    coerced to a one-element list, and several categories may be combined.
    `all` must appear alone. The native default, `["code"]`, emits no argv.

    Semble 0.5.5 also accepts a scalar `content` value on each MCP tool call;
    that per-call value replaces this server default for the call.
  '';

  errors = content:
    lib.optional (content == [])
    "Semble `mcp.content` must contain at least one category."
    ++ lib.optional (lib.length content != lib.length (lib.unique content))
    "Semble `mcp.content` must not contain duplicate categories."
    ++ lib.optional (lib.elem "all" content && lib.length content > 1)
    ''Semble `mcp.content` must not combine "all" with another category.'';

  toArgs = content: let
    normalized = normalize content;
  in
    lib.optionals (normalized != default) (["--content"] ++ normalized);
}
