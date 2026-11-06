# cspell:ignore vwalways
# Generic shell-wrapper helpers: bash blocks that let a wrapper inject launch
# flags into "$@" without breaking the CLI it wraps. Binary-agnostic; the first
# consumer is packages/kiro-cli.
#
# Three failure modes, each measured against a real CLI before the block that
# handles it was written.
#
#  1. WRONG POSITION — the one that actually bites. A GLOBAL option belongs
#     BEFORE the subcommand; appended after one, clap parses it against the
#     SUBCOMMAND's parser and rejects it outright:
#
#       kiro-cli mcp list --tui   ->  error: unexpected argument '--tui' found
#       kiro-cli --tui mcp list   ->  works
#
#     Nothing about `mcp` rejects `--tui`; the flag was merely in the wrong
#     place. `position = "prepend"` is therefore the right default for any
#     option the CLI declares at top level, and there is no `position` default
#     here on purpose — picking one is exactly the decision that was got wrong.
#
#  2. DOUBLING — an UNCONDITIONAL inject doubles a flag the caller already
#     passed and clap aborts with "the argument '--tui' cannot be used multiple
#     times". Each flag is injected only when absent as an EXACT argv token. The
#     exact-token match (a per-arg `case`, not a substring scan of "$*") means a
#     prompt like `chat "explain --tui"` never suppresses the real flag.
#     Given the CLI's short options (`anyOptionBlock`), a single-dash token is
#     also read as a cluster, `-vw` being `-v -w`.
#
#  3. WRONG SUBCOMMAND — a genuinely per-subcommand option (as opposed to a
#     global one that was merely misplaced) must not reach subcommands that do
#     not declare it. `gateOnSubcommand` resolves the invocation's subcommand
#     into `nat_sub` and runs the injection only where it is accepted.
{lib}: let
  # Flag -> shell var name: "--tui" -> "nat_seen_tui", "--v3" -> "nat_seen_v3".
  flagVar = f: "nat_seen_" + builtins.replaceStrings ["-" "="] ["_" "_"] (lib.removePrefix "--" f);

  # A `case` alternation of shell-literal patterns: ["chat" "acp"] -> "chat|acp".
  #
  # `escapeShellArg` quotes only when it has to — it returns a bare word for
  # anything matching `[[:alnum:],._+:@%/-]+`, so the common cases here (`chat`,
  # `--agent`) come out UNQUOTED and the emitted bash reads `''|chat)`, not
  # `''|'chat')`. That is still glob-safe, but not because the quoting is
  # unconditional: the elision class contains no glob metacharacter, so a value
  # bash could read as a pattern (`*`, `?`, `[`) always falls outside it and is
  # quoted. `bareInvocation` is the empty string, which it renders as `''`.
  altPattern = lib.concatMapStringsSep "|" lib.escapeShellArg;

  # Indent every non-blank line by two spaces, so a nested block stays readable
  # in the generated script.
  indentBlock = block:
    lib.concatMapStringsSep "\n" (
      line:
        if line == ""
        then ""
        else "  " + line
    ) (lib.splitString "\n" block);

  # Sets `nat_sub` to the invocation's subcommand — the first argv token that is
  # neither an option nor an option's value — or to "" when there is none.
  #
  # `valueFlags` are the wrapped CLI's top-level options that consume the NEXT
  # argv token (kiro-cli's `--agent <AGENT>`, `--resume-id <SESSION_ID>`). Their
  # value has to be skipped or `kiro-cli --agent acp` reads as the `acp`
  # subcommand. The `--opt=value` form needs no entry: it is one token and falls
  # through the `-*` arm.
  #
  # `nat_skip` is 1 afterwards when the last token was a value option still
  # waiting for its value.
  #
  # A literal `--` stops the scan with `nat_sub="--"`, which no real subcommand
  # matches, so every gate declines rather than guessing.
  subcommandBlock = valueFlags:
    lib.concatStringsSep "\n" (
      [
        # Plain (not indented) Nix strings throughout: `''…''` strips the common
        # leading whitespace, which would flatten this block's indentation.
        "nat_sub=\"\""
        "nat_skip=0"
        "for nat_arg in \"$@\"; do"
        "  if [ \"$nat_skip\" = 1 ]; then nat_skip=0; continue; fi"
        "  case \"$nat_arg\" in"
        "    --) nat_sub=\"--\"; break ;;"
      ]
      ++ lib.optional (valueFlags != []) "    ${altPattern valueFlags}) nat_skip=1 ;;"
      ++ [
        "    -*) ;;"
        "    *) nat_sub=\"$nat_arg\"; break ;;"
        "  esac"
        "done"
      ]
    );

  # The `case` patterns matching one option's long spellings in argv: `flag`
  # and its `aliases`, as `--name` or `--name=value`.
  longPatterns = {
    flag,
    aliases ? [],
    ...
  }:
    lib.concatMap (name: [(lib.escapeShellArg name) "${lib.escapeShellArg name}=*"]) ([flag] ++ aliases);

  # The `case` patterns matching one option in argv: `longPatterns`, and the
  # short name as `-x`, plus the attached form (`-x` directly followed by its
  # value) when the option takes a value. A short option inside a cluster
  # (`-vw`) is not matched; `anyOptionBlock` reads clusters when it is given
  # the CLI's `shorts`.
  optionPatterns = {
    short ? null,
    takesValue ? true,
    ...
  } @ option:
    longPatterns option
    ++ lib.optional (short != null) (lib.escapeShellArg short + lib.optionalString takesValue "*");

  # The shell that reads one token as a cluster of short options, clap's way: the
  # characters after the single dash are short options read left to right; a
  # character taking a value ends the cluster, the rest of the token (when
  # there is any) being its value and otherwise the next token (`nat_value` is
  # then 1). `matched` are the characters that set `var`; `shorts` maps every
  # short character the CLI declares to whether it takes a value. A character
  # in neither ends the scan of the token: nothing is guessed about it.
  clusterArm = {
    matched,
    shorts,
    var,
  }: let
    table = shorts // lib.mapAttrs (_: option: option.takesValue or true) matched;
    arm = char: takesValue: let
      commands =
        lib.optional (matched ? ${char}) "${var}=1"
        ++ lib.optional takesValue "if [ -z \"$nat_rest\" ]; then nat_value=1; fi; break";
    in
      "          ${lib.escapeShellArg char}) "
      + lib.optionalString (commands != []) (lib.concatStringsSep "; " commands + " ")
      + ";;";
  in
    lib.concatStringsSep "\n" (
      [
        "    -?*)"
        "      nat_rest=\"\${nat_arg#-}\""
        "      while [ -n \"$nat_rest\" ]; do"
        "        nat_short=\"\${nat_rest:0:1}\""
        "        nat_rest=\"\${nat_rest:1}\""
        "        case \"$nat_short\" in"
      ]
      ++ lib.mapAttrsToList arm table
      ++ [
        "          *) break ;;"
        "        esac"
        "      done ;;"
      ]
    );

  # Sets shell variable `var` to 1 when any of `options` (records for
  # `optionPatterns`) occurs before any literal `--`, else 0. Only presence is
  # read, never the value: the caller decides whether to inject, and the wrapped
  # CLI resolves what the caller asked for. A token past `--` is a positional
  # the wrapped CLI will not honour, so neither does this; an exact match keeps
  # a prompt that merely mentions the option from counting.
  #
  # `shorts` (null: not read) is the CLI's table of short options for the
  # subcommand scanned, `{<char> = takesValue;}` without the dash, as measured
  # from its `--help`. Given, a single-dash token is read as a cluster
  # (`clusterArm`) and the options' short names are matched there, so `-vw`,
  # `-vwalways` and `-wv` are each read as clap reads them; a value-taking short
  # leaves the next token unread as its value. Without it the short names are
  # matched as whole tokens only (`optionPatterns`).
  anyOptionBlock = {
    options,
    var,
    shorts ? null,
  }:
    lib.concatStringsSep "\n" (
      if shorts == null
      then [
        "${var}=0"
        "for nat_arg in \"$@\"; do"
        "  case \"$nat_arg\" in"
        "    --) break ;;"
        "    ${lib.concatStringsSep "|" (lib.concatMap optionPatterns options)}) ${var}=1 ;;"
        "  esac"
        "done"
      ]
      else [
        "${var}=0"
        "nat_value=0"
        "for nat_arg in \"$@\"; do"
        "  if [ \"$nat_value\" = 1 ]; then nat_value=0; continue; fi"
        "  case \"$nat_arg\" in"
        "    --) break ;;"
        "    ${lib.concatStringsSep "|" (lib.concatMap longPatterns options)}) ${var}=1 ;;"
        "    --*) ;;"
        (clusterArm {
          inherit shorts var;
          matched = lib.listToAttrs (map (option: lib.nameValuePair (lib.removePrefix "-" option.short) option) (lib.filter (option: (option.short or null) != null) options));
        })
        "  esac"
        "done"
      ]
    );

  # `anyOptionBlock` for one option: `{flag, aliases?, short?, takesValue?, var}`,
  # with the optional `shorts` of `anyOptionBlock`.
  optionPresenceBlock = {
    var,
    shorts ? null,
    ...
  } @ option:
    anyOptionBlock {
      inherit shorts var;
      options = [(removeAttrs option ["shorts" "var"])];
    };

  # Adds the argv word `token` of each option that the caller has not already
  # passed (see `optionPatterns` for the spellings, `anyOptionBlock` for
  # `shorts`), just before an end-of-options `--` when argv has one — a token
  # past it is a positional — and last otherwise. `options` are
  # `optionPatterns` records plus `token`; injected words keep the list's
  # order. An empty list yields "".
  injectOptionsWith = {shorts ? null}: options:
    if options == []
    then ""
    else
      lib.concatStringsSep "\n" (
        ["nat_inject=()"]
        ++ lib.concatMap (option: [
          (optionPresenceBlock (removeAttrs option ["token"]
            // {
              inherit shorts;
              var = flagVar option.flag;
            }))
          "if [ \"\$${flagVar option.flag}\" = 0 ]; then nat_inject+=(${lib.escapeShellArg option.token}); fi"
        ])
        options
        ++ [
          "if [ \"\${#nat_inject[@]}\" -gt 0 ]; then"
          "  nat_argv=()"
          "  nat_placed=0"
          "  for nat_arg in \"$@\"; do"
          "    if [ \"$nat_placed\" = 0 ] && [ \"$nat_arg\" = -- ]; then nat_argv+=(\"\${nat_inject[@]}\"); nat_placed=1; fi"
          "    nat_argv+=(\"$nat_arg\")"
          "  done"
          "  if [ \"$nat_placed\" = 0 ]; then nat_argv+=(\"\${nat_inject[@]}\"); fi"
          "  set -- \"\${nat_argv[@]}\""
          "fi"
        ]
      );

  # flags    : boolean flag strings, e.g. [ "--tui" "--v3" ].
  # position : "prepend" for a CLI-global option (before any subcommand);
  #            "append" for one the target subcommand itself declares.
  #
  # Returns a bash snippet (or "" for the empty list) that injects each flag
  # that is not already present, preserving `flags` order in the result.
  # Prepending walks the list in reverse, since each `set --` pushes onto the
  # front: for [ "--tui" "--v3" ] that yields `--tui --v3 "$@"`.
  idempotentFlagBlock = {
    flags,
    position,
  }:
    lib.throwIf (!builtins.elem position ["append" "prepend"])
    "idempotentFlagBlock: `position` must be \"append\" or \"prepend\", got ${builtins.toJSON position}."
    (
      if flags == []
      then ""
      else
        lib.concatStringsSep "\n" (
          (map (f: "${flagVar f}=0") flags)
          ++ ["for nat_arg in \"$@\"; do" "  case \"$nat_arg\" in"]
          ++ (map (f: "    ${lib.escapeShellArg f}) ${flagVar f}=1 ;;") flags)
          ++ ["  esac" "done"]
          ++ (map (
              f:
                if position == "prepend"
                then "if [ \"\$${flagVar f}\" = 0 ]; then set -- ${lib.escapeShellArg f} \"$@\"; fi"
                else "if [ \"\$${flagVar f}\" = 0 ]; then set -- \"$@\" ${lib.escapeShellArg f}; fi"
            )
            (
              if position == "prepend"
              then lib.reverseList flags
              else flags
            ))
        )
    );
in {
  inherit anyOptionBlock idempotentFlagBlock injectOptionsWith optionPresenceBlock subcommandBlock;

  # `injectOptionsWith` with no `shorts`: short names matched as whole tokens.
  injectOptionsBlock = injectOptionsWith {};

  # The `subcommands` entry standing for an invocation that carries NO
  # subcommand — `kiro-cli` on its own. Named rather than written as a bare ""
  # so a gate covering the bare launch says so at the call site.
  bareInvocation = "";

  # Wraps `body` so it runs only when the invocation's subcommand is one of
  # `subcommands` (include `bareInvocation` to cover the bare launch). Emits the
  # `nat_sub` detection itself, so a caller passes `valueFlags` rather than
  # sequencing two blocks by hand. An empty `body` yields "" — no gate is
  # emitted for an injection that has nothing to inject.
  gateOnSubcommand = {
    subcommands,
    valueFlags ? [],
  }: body:
    lib.throwIf (subcommands == [])
    "gateOnSubcommand: `subcommands` must be non-empty — an empty gate can never fire, which silently drops the injection."
    (
      if body == ""
      then ""
      else
        lib.concatStringsSep "\n" [
          (subcommandBlock valueFlags)
          "case \"$nat_sub\" in"
          "  ${altPattern subcommands})"
          (indentBlock (indentBlock body))
          "    ;;"
          "esac"
        ]
    );
}
