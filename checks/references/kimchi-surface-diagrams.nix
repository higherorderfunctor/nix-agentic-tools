# Drift gate for the Kimchi surface reference's two diagrams.
#
# `dev/references/kimchi-surface/kimchi-server-surface.md` is hand-edited;
# the two SVGs beside it are rendered from its GFM tables and are never
# edited by hand. Nothing stops an author editing the markdown and
# committing without re-rendering, and the failure is invisible in review:
# a stale SVG is a valid image of a reference that no longer exists, and
# the diff of a 37KB generated SVG is not something a reviewer reads.
#
# So this re-renders both from the tracked markdown and fails on any byte
# difference. Same shape and same reasoning as
# checks/instructions/instructions-drift.nix — read that file's header for
# why a drift gate belongs in `nix flake check` rather than in a prek hook.
#
# WHAT THIS CHECK DOES NOT COVER, because it structurally cannot: a section
# whose table header is REWORDED stops matching the capability matrix and
# leaves the render entirely. Re-rendering then yields a committed pair and
# a regenerated pair that agree with each other while both omit the
# section, so this check passes on a diagram that lost a whole group. That
# guard lives in `dominant` in the generator instead — see its docstring,
# which carries the measured numbers.
#
# The generator is pure-stdlib Python, so `pkgs.python3` with no
# environment is the whole dependency. The invocation arguments come from
# ../../dev/references/kimchi-surface/renders.nix, shared with the
# `generate:references:kimchi-surface` devenv task; that file explains why
# they are not written out here.
{pkgs, ...}: let
  inherit (pkgs) lib;

  # One path literal for the whole reference directory, so the markdown and
  # both committed SVGs arrive in the sandbox together and are compared
  # against the same tree they were rendered from.
  reference = ../../dev/references/kimchi-surface;
  script = ../../dev/skills/kimchi-surface-scan/scripts/surface-tables.py;

  renders = import ../../dev/references/kimchi-surface/renders.nix {inherit lib;};

  # Byte counts alone are not a diagnosis — a one-character substitution
  # drifts at identical length, which reads as a false alarm. The first
  # few diff lines are what says WHAT moved, and an SVG's lines are one
  # element each, so a dozen of them is a usable excerpt rather than a
  # wall. `2>&1` for the same reason instructions-drift.nix does it: a
  # diff-level error would otherwise reach the real stderr and leave the
  # printed excerpt blank.
  compareOne = spec: ''
    if ! "$diff" -u "${reference}/${spec.out}" "rendered/${spec.out}" \
      >"$tmp/${spec.out}.diff" 2>&1; then
      failed=1
      echo "" >&2
      echo "DRIFT: dev/references/kimchi-surface/${spec.out}" >&2
      echo "  committed $("$wc" -c < "${reference}/${spec.out}") bytes," \
        "re-rendered $("$wc" -c < "rendered/${spec.out}") bytes" >&2
      "$sed" -n '1,12p' "$tmp/${spec.out}.diff" >&2
    fi
  '';
in {
  checks.kimchi-surface-diagrams = pkgs.runCommandLocal "kimchi-surface-diagrams-check" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    diff="${pkgs.diffutils}/bin/diff"
    sed="${pkgs.gnused}/bin/sed"
    wc="${pkgs.coreutils}/bin/wc"
    tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
    ${pkgs.coreutils}/bin/mkdir -p rendered
    failed=0

    ${renders.invocations {
      python3 = "${pkgs.python3}/bin/python3";
      script = "${script}";
      markdown = "${reference}/kimchi-server-surface.md";
      outDir = "rendered";
    }}

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_: compareOne) renders.renders)}

    if [ "$failed" -ne 0 ]; then
      echo "" >&2
      echo "The committed diagrams do not match the reference markdown." >&2
      echo "Regenerate and 'git add' the results:" >&2
      echo "  devenv tasks run --mode before generate:references:kimchi-surface" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$out"
    ${pkgs.coreutils}/bin/touch "$out/ok"
  '';
}
