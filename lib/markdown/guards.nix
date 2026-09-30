# The three file guards, defined ONCE: tableCells, splitCodeSpans and
# parseCompare. `lib/generated.nix` runs them over every generated tree with
# the `ai.generated.guards` wording through `mkGuards`; `consumer` is the
# public `lib.ai.guards pkgs`: the same executables and a check builder for
# files a consumer authors themselves.
#
# `pkgs` must carry this flake's overlay wherever tableCells runs: it uses the
# overlay's rumdl and markdownlint-cli2 (see ./table-cells.nix for why not
# nixpkgs').
{lib}: let
  reason = {
    parseCompare = "Parsed JSON, TOML or YAML changed, or Markdown frontmatter bytes changed; a reader could see different configuration.";
    splitCodeSpans = "An inline code span crosses a newline; CommonMark inserts a space that can corrupt a path or identifier.";
    tableCells = "A Markdown table has inconsistent cell counts; an unescaped pipe can change or break its rendered columns.";
  };

  # generated-guard.py with the interpreter it needs. The generated-file
  # builder runs its split and attach actions; parseCompare runs `compare`.
  generatedGuard = pkgs: "${pkgs.python3.withPackages (ps: [ps.pyyaml])}/bin/python3 ${../generated-guard.py}";

  # `mkGuards pkgs context`: the three executables. Each passes the tool's
  # exit code through and ends a finding (exit 1) with the standard
  # diagnostic — what failed, why, and three ways out — worded for the
  # caller that runs it.
  mkGuards = pkgs: context: let
    strictShellApplication = import ../strict-shell-application.nix pkgs;
    tableCells = import ./table-cells.nix {inherit pkgs;};
    program = {
      parseCompare = {
        name = "ai-guard-parse-compare";
        run = ''${generatedGuard pkgs} compare "$@"'';
      };
      splitCodeSpans = {
        name = "ai-guard-split-code-spans";
        run = ''${pkgs.python3}/bin/python3 ${./split-code-spans.py} "$@"'';
      };
      tableCells = {
        name = "ai-guard-table-cells";
        run = ''${lib.getExe tableCells.package} "$@"'';
      };
    };
  in
    lib.mapAttrs (guard: {
      name,
      run,
    }:
      strictShellApplication {
        inherit name;
        text = ''
          rc=0
          ${run} || rc=$?
          if [ "$rc" -eq 1 ]; then
            printf '%s\n' >&2 ${lib.escapeShellArgs [
            "${context.title} ${guard} failed."
            reason.${guard}
            "Choose one of three options:"
            "  1. ${context.fix}"
            "  2. ${context.disable guard}"
            "  3. ${context.optOut}"
            context.see
          ]}
          fi
          exit "$rc"
        '';
      })
    program;

  # `consumer pkgs`, exported as `lib.ai.guards`: the three programs worded
  # for files outside any generated tree, and `check`.
  consumer = pkgs: let
    programs = mkGuards pkgs {
      title = "Guard";
      fix = "Fix the file, or the formatter that changed it.";
      # check never runs parseCompare, so it has no check setting to name.
      disable = guard:
        if guard == "parseCompare"
        then "Disable parseCompare: stop running this program."
        else "Disable ${guard}: set guards.${guard} = false in the check, or stop running this program.";
      optOut = "Leave this file out of the guarded file set.";
      see = "See the nix-agentic-tools README: Using the guards on your own files.";
    };
  in {
    inherit (programs) parseCompare splitCodeSpans tableCells;

    # `check {src, guards ? {}}`: a derivation that runs splitCodeSpans and
    # tableCells over every `*.md` under `src`. parseCompare is not offered
    # here: it compares two versions of one file, and a source tree holds one.
    check = {
      src,
      guards ? {},
    }: let
      enabled = {
        splitCodeSpans = true;
        tableCells = true;
      };
      selected = lib.filterAttrs (guard: on: guards.${guard} or on) enabled;
    in
      assert lib.assertMsg (lib.subtractLists (lib.attrNames enabled) (lib.attrNames guards) == [])
      "lib.ai.guards check: guards may name splitCodeSpans or tableCells. parseCompare compares two versions of a file; run its program on BEFORE and AFTER instead.";
        pkgs.runCommand "ai-guards" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          cd ${src}
          ${pkgs.findutils}/bin/find . -type f -name '*.md' -print0 \
            | ${pkgs.coreutils}/bin/sort -z > "$TMPDIR/files"
          mapfile -d "" -t files < "$TMPDIR/files"
          ${lib.concatMapStrings (guard: ''
            ${lib.getExe programs.${guard}} "''${files[@]}"
          '') (lib.attrNames selected)}
          ${pkgs.coreutils}/bin/touch "$out"
        '';
  };
in {
  inherit consumer generatedGuard mkGuards;
}
