# The content-category contract, shared by the convenience module
# (`modules/options.nix`) and the direct `mkSemble` helper so the two cannot
# disagree about which values are legal or how they lower to argv. Both used to
# carry a byte-identical `enum` declaration and a byte-identical argv line.
#
# UPSTREAM SHAPE. Semble's server flag is `--content` declared with argparse
# `nargs="+"`, `choices = code docs config all`, `default = ["code"]`
# (`semble/cli.py`, `_add_content_args`). It therefore takes a LIST of
# categories, not one — `semble-mcp --content code docs` is valid and indexes
# both. A scalar option was strictly NARROWER than upstream, so the two-category
# index was unreachable from Nix. The option is a list; a scalar is still
# accepted and coerced, so every pre-existing `content = "docs"` evaluates
# identically.
#
# WHAT THE VALUE MEANS depends on the pinned Semble, and both readings are
# served by the same argv:
#   * 0.5.4 (pinned today) — a hard scope. The MCP tools take no per-call
#     content argument, so the startup set is all the server can ever search.
#   * 0.5.5+ — the server's `default_content`. The tools gained a per-call
#     `content` argument resolved against it (`semble/mcp.py`,
#     `_resolve_content_selection`), so this becomes what a caller gets when it
#     does not ask for something else.
{lib}: let
  categories = ["all" "code" "config" "docs"];

  # Sorted so two spellings of the same set emit one canonical argv. Upstream
  # normalises the set anyway when it computes its cache key
  # (`_IndexCache._compute_cache_key` walks `ContentType` in declaration
  # order), so ordering never reaches the index — it only reaches the diff.
  normalize = content: lib.sort (a: b: a < b) content;
in rec {
  inherit categories normalize;

  type = lib.types.coercedTo (lib.types.enum categories) lib.singleton (lib.types.listOf (lib.types.enum categories));

  default = ["code"];

  description = ''
    File-content categories indexed by the Semble MCP server, as a list.
    Accepts `all`, `code`, `config`, and `docs`; a bare string is coerced to a
    one-element list, so `content = "docs"` and `content = ["docs"]` are the
    same configuration.

    Several categories may be combined (`["code" "docs"]`) because upstream's
    `--content` flag takes `nargs="+"`. `["all"]` is equivalent to listing every
    category and may not be combined with one. The default `["code"]` is
    Semble's own default and emits no command-line argument.

    On Semble 0.5.4 this is a hard scope — the MCP tools cannot select content
    per call. On 0.5.5 and later it is the server's default, which a caller may
    override per call.
  '';

  # Returns a list of human-readable reasons the value is unusable, empty when
  # it is fine. Callers lower this differently BECAUSE THEY MUST: the module
  # path turns it into `assertions` (whose messages are testable), while
  # `mkSemble` has to `throw`. An `assertions` block is silently discarded on
  # the helper path — `lib/mcp.nix`'s `evalSettings` and
  # `lib/ai/mcpServer/mkMcpServer.nix` both return `eval.config` and nothing
  # ever walks it. That footgun is recorded at
  # `packages/gitlab-mcp/modules/mcp-server.nix:323-324`.
  #
  # Each rule is grounded in what upstream actually does with the value, not in
  # a preference. The instance-topology rationale this validation was first
  # sketched with — redundant long-lived processes, model loads and indexes —
  # does not apply: there is one server either way.
  errors = content:
    lib.optional (content == []) ''
      `content` is empty. Semble's `--content` flag is declared `nargs="+"`, so
      an empty list emits a bare `--content` and the server exits non-zero at
      startup with "expected at least one argument". List at least one of
      ${lib.concatStringsSep ", " categories}.
    ''
    ++ lib.optional (lib.length content != lib.length (lib.unique content)) ''
      `content` repeats a category. Upstream normalises duplicates away when it
      computes its index cache key, so a repeat changes nothing about what is
      indexed and only makes the emitted argv non-canonical. List each category
      at most once.
    ''
    ++ lib.optional (lib.elem "all" content && lib.length content > 1) ''
      `content` combines "all" with a specific category. Upstream collapses any
      list containing "all" to every category, so the specific entry is silently
      ignored and the configuration claims a narrower index than it gets. Use
      ["all"] on its own, or list the categories you actually want.
    '';

  # `code` alone is Semble's native default, so it emits nothing rather than a
  # redundant argument. Everything else emits ONE `--content` followed by every
  # value, which is what `nargs="+"` consumes — NOT one flag per value.
  toArgs = content: let
    normalized = normalize content;
  in
    lib.optionals (normalized != default) (["--content"] ++ normalized);
}
