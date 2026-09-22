# THE TWO SVG INVOCATIONS, STATED ONCE.
#
# `kimchi-server-surface.md` is the source of truth for the CONTENT; this
# file is the source of truth for HOW it is projected. Three surfaces want
# the same title/subtitle/cols/widths and there is no lossless way to derive
# one from another, so they are stated here and read from here:
#
#   - checks/references/kimchi-surface-diagrams.nix — re-renders and diffs
#     the committed SVGs.
#   - dev/tasks/generate.nix — the `generate:references:kimchi-surface`
#     task a human or agent actually runs to update them.
#   - dev/skills/kimchi-surface-scan/SKILL.md — which deliberately does NOT
#     restate the values. It names the task and points here.
#
# Writing them as prose in the skill and again in the check is the exact
# duplication the repo's CLAUDE.md forbids, and it fails in a specific way:
# the check would keep passing against arguments nobody runs, while the
# documented command produced a different image.
#
# `invocation` rather than a bare attrset of strings because the two
# consumers are both bash. Handing them a finished, shell-quoted command
# line means the ARGUMENT SPELLING (`--cols` vs `--columns`, comma-joined
# vs repeated) is single-source too, not just the values.
{lib}: rec {
  # `subtitle` is the version that was scanned, and it is the field that
  # moves on a Kimchi bump. Bump it HERE — a command line typed with a
  # different --subtitle produces an SVG the drift check then rejects.
  #
  # `widths` are per-column character counts, deliberately not round: they
  # come from each column's length DISTRIBUTION rather than its maximum.
  # The arithmetic, and why fitting to a total budget starves the one
  # column that needs the room, is in the `--widths` comment in
  # dev/skills/kimchi-surface-scan/scripts/surface-tables.py.
  renders = {
    capabilities = {
      out = "kimchi-capabilities.svg";
      title = "Kimchi CLI — server-side capabilities";
      subtitle = "kimchi 1.1.30";
      cols = "0,1,2";
      widths = "46,90,80";
    };
    endpoints = {
      out = "kimchi-endpoints.svg";
      title = "Kimchi CLI — endpoints and repointing";
      subtitle = "kimchi 1.1.30";
      cols = "0,3,4,5";
      widths = "40,82,30,63";
    };
  };

  # One render's command line. `python3`, `script` and `markdown` are
  # whatever the caller can reach — store paths inside the check, working
  # tree paths inside the devenv task — and `outDir` is where the SVG lands.
  invocation = {
    python3,
    script,
    markdown,
    outDir,
  }: spec:
    lib.escapeShellArgs [
      python3
      script
      "svg"
      markdown
      "${outDir}/${spec.out}"
      "--title"
      spec.title
      "--subtitle"
      spec.subtitle
      "--cols"
      spec.cols
      "--widths"
      spec.widths
    ];

  # Every render's command line, newline-joined, ready to splice into a
  # bash body. Both consumers render ALL of them; neither picks a subset,
  # so the iteration lives here too.
  invocations = args:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (_: invocation args) renders
    );
}
