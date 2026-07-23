# Generic shell-wrapper helper: a bash block that idempotently appends boolean
# flags to "$@" — each flag added only if not already present as an EXACT argv
# token. Binary-agnostic; reusable by any wrapper that must inject launch flags
# without doubling one a caller already passed.
#
# Motivating case (first consumer, packages/kiro-cli): a launcher wrapper injects
# `--tui`/`--v3` so the CLI starts in the v3 TUI. An UNCONDITIONAL append doubles
# the flag when a caller already passes it (docs, probes, reproducers) and clap
# aborts with "the argument '--tui' cannot be used multiple times". The exact-token
# match (a per-arg `case`, not a substring scan of "$*") means a prompt like
# `chat "explain --tui"` never suppresses the real flag.
{lib}: let
  # Flag -> shell var name: "--tui" -> "nat_seen_tui", "--v3" -> "nat_seen_v3".
  flagVar = f: "nat_seen_" + builtins.replaceStrings ["-" "="] ["_" "_"] (lib.removePrefix "--" f);
in {
  # flags : list of boolean flag strings (e.g. [ "--tui" "--v3" ]).
  # Returns a bash snippet (or "" for the empty list) that, run with the wrapper's
  # positional params, appends each missing flag to "$@" via `set --`.
  idempotentFlagBlock = flags:
    if flags == []
    then ""
    else
      lib.concatStringsSep "\n" (
        (map (f: "${flagVar f}=0") flags)
        ++ ["for nat_arg in \"$@\"; do" "  case \"$nat_arg\" in"]
        ++ (map (f: "    ${lib.escapeShellArg f}) ${flagVar f}=1 ;;") flags)
        ++ ["  esac" "done"]
        ++ (map (f: "if [ \"\$${flagVar f}\" = 0 ]; then set -- \"$@\" ${lib.escapeShellArg f}; fi") flags)
      );
}
