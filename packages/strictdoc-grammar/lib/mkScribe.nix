# The dev-shell entry points for the scribe programs: the writer itself
# (SLICE-SDOC-CLI), the resident daemon and its client
# (docs/plans/scribe-daemon/). One builder, three instantiations — they differ
# only in which script under dev/scripts/ they exec.
#
# ── Why the script is NOT baked into the store ───────────────────────────────
#
# The CLI is dev-only tooling that lives beside the corpus it writes, in the
# same tree, on the same long-lived branch. Copying it into a derivation would
# mean a rebuild between editing the tool and running it, and — worse — a
# `scribe` resolved from the PRIMARY checkout's shell would carry that checkout's
# copy of the script into every linked worktree, which is precisely the skew
# the one-graph layout exists to avoid. So this wrapper carries the
# INTERPRETER, which does need Nix, and resolves the SCRIPT at run time.
#
# ── How the root is found ────────────────────────────────────────────────────
#
# By walking up from the caller's cwd for `strictdoc_config.py`, which is the
# same marker the CLI itself uses to find the project root, and there is
# exactly one — at the repository root, so every document lands in one graph.
# Deliberately NOT `$DEVENV_ROOT`: under the sandbox-stack topology devenv is
# entered in the primary checkout only, so DEVENV_ROOT names a tree the agent
# is not working in.
#
# ── The interpreter ──────────────────────────────────────────────────────────
#
# `runner` is ../lib/mkExtract.nix's output: strictdoc's OWN virtual
# environment, importable, taking an entry point as argv[1]. Reused rather than
# re-derived — the shebang-reading indirection that reaches that venv is
# explained in that file's header and is not worth having in two places. The
# `ast_grep_py` splice it also carries is inert here.
{
  lib,
  pkgs,
  runner,
  # Which program this instantiation is. `script` is resolved at RUN time,
  # relative to the project root the wrapper walks up to — see above.
  name ? "scribe",
  script ? "dev/scripts/sdoc_cli.py",
  description ? "Grammar-derived writer for this repository's .sdoc design graph",
}:
pkgs.writeShellApplication {
  inherit name;

  # `nounset` has to be armed ABOVE writeShellApplication's own generated
  # `export PATH=...`, which is what putting these here rather than in `text`
  # buys: a PATH-less invocation fails loudly instead of yielding a
  # trailing-colon PATH, which bash reads as the current directory.
  bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];

  runtimeInputs = [pkgs.coreutils];

  text = ''
    shopt -s inherit_errexit 2>/dev/null || :

    root=$PWD
    while [ ! -f "$root/strictdoc_config.py" ]; do
      parent=$(dirname "$root")
      if [ "$parent" = "$root" ]; then
        echo "${name}: no strictdoc_config.py in $PWD or any parent -- run" \
             "inside the repository" >&2
        exit 1
      fi
      root=$parent
    done

    script=$root/${script}
    if [ ! -f "$script" ]; then
      echo "${name}: $script is missing; this wrapper carries the interpreter," \
           "not the script" >&2
      exit 1
    fi

    exec ${lib.getExe runner} "$script" "$@"
  '';

  meta = {
    inherit description;
    mainProgram = name;
    license = lib.licenses.unlicense;
    platforms = lib.platforms.unix;
  };
}
