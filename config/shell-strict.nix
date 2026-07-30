# Shared shell-hardening settings for `pkgs.writeShellApplication` call sites
# and the prek `shellcheck` hook.
#
# Six consumers across five importing files: devenv.nix wires BOTH the
# reject-default-branch-commit wrapper and the prek `shellcheck` hook, plus
# flake.nix, lib/validate-at-stop.nix, packages/claude-code/lib/delegationClamp.nix
# and packages/mcp-services/modules/homeManager/default.nix. Single source of
# truth rather than six copies (DRY) — when adding a call site, add it here.
{
  # Everything the repo's strict-mode header expresses that `set -o` can name.
  # writeShellApplication renders one `set -o <name>` line per entry, ABOVE its
  # own generated `export PATH="…:$PATH"`, which is why the flags belong here
  # rather than only in `text`: with `nounset` in force, a PATH-less invocation
  # fails loudly instead of producing a trailing-colon PATH, which bash reads as
  # the current directory. That is not hypothetical for this repo — Claude
  # Code's MCP `env` field REPLACES the process environment rather than merging
  # it, so wrappers spawned that way can genuinely have no PATH.
  bashOptions = [
    "errexit"
    "errtrace"
    "functrace"
    "nounset"
    "pipefail"
  ];

  # The rest of the header. `inherit_errexit` is a `shopt`, NOT a `set -o`
  # name, so `bashOptions` structurally cannot carry it — this goes at the top
  # of `text`. bashOptions alone never satisfies the standard.
  shoptHeader = "shopt -s inherit_errexit 2>/dev/null || :";

  # Opt-in shellcheck checks enabled repo-wide.
  #
  # VERIFIED clean when adopted (2026-07-30): zero findings across all 24
  # tracked `*.sh` files and every rendered writeShellApplication wrapper. This
  # is a regression gate, not a cleanup task — a new entry must be clean on the
  # whole corpus before it lands.
  #
  # Deliberately NOT enabled:
  #   --enable=all               nixpkgs' OWN generated `export PATH="…:$PATH"`
  #                              trips SC2250, so `all` can never pass at any
  #                              site setting runtimeInputs. Proved with a
  #                              wrapper whose entire body is `true`.
  #   require-variable-braces    (SC2250) same reason — permanently off-limits.
  #   require-double-brackets    (SC2292) 20 findings today; a cleanup PR.
  #   check-unassigned-uppercase (SC2154) false-positives on $MCP_PORT, which
  #                              the systemd unit injects and shellcheck cannot
  #                              see. Do NOT "fix" by defaulting MCP_PORT —
  #                              that masks a genuinely missing Environment=.
  #   check-extra-masked-returns (SC2312) / check-set-e-suppressed (SC2310)
  #                              7 findings in lib/validate-at-stop.sh.
  #
  # `deprecate-which` is the one with real Nix teeth: a `which` missing from
  # runtimeInputs is a runtime failure, not a style nit.
  shellcheckFlags = [
    "--enable=add-default-case,avoid-negated-conditions,avoid-nullary-conditions,deprecate-which,quote-safe-variables,useless-use-of-cat"
  ];
}
