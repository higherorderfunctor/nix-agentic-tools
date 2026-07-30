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

  # Captures the VALUE a caller passed for `flag` into shell variable `var`, or
  # leaves it empty when the flag is absent. Both spellings are handled —
  # `--flag value` (two tokens) and `--flag=value` (one) — and the LAST
  # occurrence wins, matching how a CLI that tolerates repetition resolves it.
  #
  # This exists because some injections depend on what the caller ASKED for, not
  # only on what the Nix config baked in. kiro's `--agent-engine` is the case:
  # a caller's engine overrides an injected `--v3`, so whether a second flag
  # conflicts can only be resolved from the actual argv, at runtime.
  # A literal `--` ends the scan, matching `subcommandBlock` and ordinary CLI
  # semantics: past it, a token that merely LOOKS like the flag is a positional
  # and the wrapped CLI will not honour it, so neither should this. The
  # `nat_val_next` check runs first, so a `--` that is genuinely the flag's own
  # VALUE is still consumed as one rather than ending the scan.
  optionValueBlock = {
    flag,
    var,
  }:
    lib.concatStringsSep "\n" [
      "${var}=\"\""
      "nat_val_next=0"
      "for nat_arg in \"$@\"; do"
      "  if [ \"$nat_val_next\" = 1 ]; then ${var}=\"$nat_arg\"; nat_val_next=0; continue; fi"
      "  case \"$nat_arg\" in"
      "    --) break ;;"
      "    ${lib.escapeShellArg flag}) nat_val_next=1 ;;"
      "    ${lib.escapeShellArg flag}=*) ${var}=\"\${nat_arg#${flag}=}\" ;;"
      "  esac"
      "done"
    ];

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
  inherit idempotentFlagBlock optionValueBlock subcommandBlock;

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
