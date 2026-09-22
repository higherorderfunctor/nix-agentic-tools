# Integrity guard for the heron_brook reminder step in .github/workflows/ci.yml
# (the ~90-day re-check for ai.claude.delegationClampMitigation, which is opt-in).
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
# Delete this file together with ai.claude.delegationClampMitigation and the ci.yml step.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = let
    ciFile = ../../../.github/workflows/ci.yml;
    ciLines = lib.splitString "\n" (builtins.readFile ciFile);

    # SCOPED TO THE STEP, not to the file. This used to collect every
    # `head_ref == 'update/…'` line in ci.yml and require exactly one. That was
    # right while the heron_brook reminder was the only such gate, and it went red
    # the moment a second tripwire step (oxlint's @napi-rs/cli necessity check)
    # added its own — correctly, since the old matcher genuinely could no longer
    # tell them apart.
    #
    # The narrowing must NOT be "match `update/claude-code`". The branch name is
    # read back OUT of ci.yml precisely so a rename that updates
    # config.update.targets but not ci.yml fails here; hardcoding it would make
    # this guard a third copy of the name and defeat its only purpose.
    #
    # So anchor on the step's own `- name:` line and read the gate from WITHIN
    # that step's line range. `findFirst` after the anchor would not be enough
    # either: if the heron_brook step lost its `if:`, the next step's gate would
    # be picked up and validated in its place. Bounding at the next `- name:` at
    # step indentation makes that case report zero gates and throw.
    stepName = "- name: Heron-brook mitigation review tripwire";
    stepIndent = "      - name: ";

    indexed = lib.imap0 (i: line: {inherit i line;}) ciLines;
    nameHits = builtins.filter (x: lib.hasInfix stepName x.line) indexed;
    nameCount = builtins.length nameHits;

    stepStart =
      if nameCount == 1
      then (builtins.head nameHits).i
      else -1;
    laterStepStarts =
      builtins.filter
      (x: x.i > stepStart && lib.hasPrefix stepIndent x.line)
      indexed;
    stepEnd =
      if laterStepStarts == []
      then builtins.length ciLines
      else (builtins.head laterStepStarts).i;

    # Match on BOTH tokens: `head_ref ==` alone could pick up an unrelated line,
    # and `update/` alone appears in the prose comment above the step.
    gates =
      if nameCount != 1
      then []
      else
        map (x: x.line) (builtins.filter
          (x:
            x.i
            > stepStart
            && x.i < stepEnd
            && lib.hasInfix "head_ref ==" x.line
            && lib.hasInfix "update/" x.line)
          indexed);
    gateCount = builtins.length gates;

    captured =
      if gateCount != 1
      then null
      else builtins.match ".*'update/([A-Za-z0-9._-]+)'.*" (builtins.head gates);
  in {
    claude-heron-brook =
      if nameCount != 1
      then
        throw ''
          heron_brook guard: expected exactly one ci.yml step named
          "${stepName}", found ${toString nameCount}.

          This guard anchors on that step name to find the reminder's `if:` gate.
          If the step was renamed, update `stepName` in
          packages/claude-code/checks/claude-heron-brook.nix to match. If it was deleted on purpose,
          delete this file and ai.claude.delegationClampMitigation with it.
        ''
      else if gateCount > 1
      then
        throw ''
          heron_brook guard: ${toString gateCount} steps in
          .github/workflows/ci.yml carry a `head_ref == 'update/…'` gate:

          ${lib.concatStringsSep "\n" gates}

          This guard can no longer tell which one belongs to the heron_brook
          reminder. Narrow the matcher in packages/claude-code/checks/claude-heron-brook.nix so it
          selects that step specifically.
        ''
      else if gateCount == 0
      then
        throw ''
          heron_brook guard: no `head_ref == 'update/…'` gate found in
          .github/workflows/ci.yml.

          The step named "${stepName}" exists, but carries no such gate between
          its `- name:` line and the next step.

          Without the gate the reminder fires on every PR, or never — either way
          it no longer tracks the update branch. Restore
          `if: github.head_ref == 'update/<key>'` on that step. If the mitigation
          was removed on purpose, delete packages/claude-code/checks/claude-heron-brook.nix and
          ai.claude.delegationClampMitigation along with it.
        ''
      else if captured == null
      then
        throw ''
          heron_brook guard: found the ci.yml gate but could not parse a branch
          name out of it:

            ${builtins.head gates}

          Expected `head_ref == 'update/<key>'`. Restore that shape, or update
          the matcher in packages/claude-code/checks/claude-heron-brook.nix.
        ''
      else if !(self.updateTargets ? ${builtins.head captured})
      then
        throw ''
          heron_brook guard: ci.yml gates the reminder on
          `update/${builtins.head captured}`, but no such update target exists in
          config.update.targets.

          The bot never opens that branch, so the ~90-day reminder for
          ai.claude.delegationClampMitigation will never fire again. Point the `if:` in
          .github/workflows/ci.yml at the current target key.
        ''
      else
        pkgs.runCommandLocal "claude-heron-brook-check" {} ''
          echo "ok — ci.yml gates the heron_brook reminder on an update target that exists" > $out
        '';
  };
}
