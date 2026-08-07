# Integrity guard for the heron_brook reminder step in .github/workflows/ci.yml
# (the ~90-day re-check for ai.claude.delegationClamp, which is opt-in).
#
# That step is gated on `if: github.head_ref == 'update/<key>'`. The branch is
# generated as `update/<key>` from the attribute key in config.update.targets,
# and the PR title from the same `$name` (dev/scripts/update-pkg.sh). Rename the
# key without fixing ci.yml and the gate stops matching: the reminder would
# never fire again, and nothing would say so. That is the one failure this
# mitigation's own docs call worse than no reminder at all.
#
# So the name is read BACK OUT of ci.yml rather than duplicated here — a third
# copy would just be a third thing to drift. A rename that updates both ci.yml
# and config/update-targets.nix passes with no edit to this file; a rename that
# updates only one of them fails.
#
# Eval-only: readFile plus an attrset lookup. No IFD, no derivation built, and
# emphatically no ~275 MB claude-code binary — the version-equality tripwire
# that used to live here went red on EVERY claude-code release and was right on
# none of them.
#
# Fails at EVALUATION rather than in a builder, so it costs nothing to run and
# reports before anything is built. Scoped to this attribute, so the rest of
# `nix flake check` still evaluates and reports normally.
#
# Delete this file together with ai.claude.delegationClamp and the ci.yml step.
{
  lib,
  pkgs,
  self,
}: let
  ciFile = ../.github/workflows/ci.yml;
  ciLines = lib.splitString "\n" (builtins.readFile ciFile);

  # Match on BOTH tokens: `head_ref ==` alone could pick up an unrelated future
  # step, and `update/` alone appears in prose comments above.
  #
  # Collect ALL matches and require exactly one, rather than taking the first.
  # A `findFirst` here would silently start validating a DIFFERENT step the day
  # someone adds another `head_ref == 'update/…'` gate earlier in the file —
  # the heron_brook gate could then be renamed with this guard still green,
  # which is the precise failure it exists to prevent. Same exactly-one
  # discipline vu.mkClaudeExtract applies to its enum greps.
  gates =
    builtins.filter
    (line: lib.hasInfix "head_ref ==" line && lib.hasInfix "update/" line)
    ciLines;
  gateCount = builtins.length gates;

  captured =
    if gateCount != 1
    then null
    else builtins.match ".*'update/([A-Za-z0-9._-]+)'.*" (builtins.head gates);
in {
  claude-heron-brook =
    if gateCount > 1
    then
      throw ''
        heron_brook guard: ${toString gateCount} steps in
        .github/workflows/ci.yml carry a `head_ref == 'update/…'` gate:

        ${lib.concatStringsSep "\n" gates}

        This guard can no longer tell which one belongs to the heron_brook
        reminder. Narrow the matcher in checks/claude-heron-brook.nix so it
        selects that step specifically.
      ''
    else if gateCount == 0
    then
      throw ''
        heron_brook guard: no `head_ref == 'update/…'` gate found in
        .github/workflows/ci.yml.

        The heron_brook reminder step was deleted or moved. If the mitigation
        was removed on purpose, delete checks/claude-heron-brook.nix and
        ai.claude.delegationClamp along with it. If the step merely moved,
        this guard needs re-pointing at its new home.
      ''
    else if captured == null
    then
      throw ''
        heron_brook guard: found the ci.yml gate but could not parse a branch
        name out of it:

          ${builtins.head gates}

        Expected `head_ref == 'update/<key>'`. Restore that shape, or update
        the matcher in checks/claude-heron-brook.nix.
      ''
    else if !(self.updateTargets ? ${builtins.head captured})
    then
      throw ''
        heron_brook guard: ci.yml gates the reminder on
        `update/${builtins.head captured}`, but no such update target exists in
        config.update.targets.

        The bot never opens that branch, so the ~90-day reminder for
        ai.claude.delegationClamp will never fire again. Point the `if:` in
        .github/workflows/ci.yml at the current target key.
      ''
    else
      pkgs.runCommandLocal "claude-heron-brook-check" {} ''
        echo "ok — ci.yml gates the heron_brook reminder on an update target that exists" > $out
      '';
}
