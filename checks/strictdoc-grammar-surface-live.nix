# checks/strictdoc-grammar-surface-live.nix -- acceptance item 3 of
# SLICE-GRAMMAR-FROM-NIX (packages/strictdoc-grammar/docs/implementation-brief.md):
# "The DSL evaluates and cannot weaken the types."
#
# WHY THIS EXISTS, AND WHAT IT CAUGHT. The generated option surface is the whole
# deliverable, and until this check the entire suite passed WITHOUT IT. MEASURED
# on the committed tree: rendering `values.nix` and `fixtures/foreign.nix`
# through `emit.grammar` directly -- bypassing `lib/check.nix` and therefore the
# types altogether -- produces bytes IDENTICAL to `docs/sdoc/grammar.sgra` and
# `fixtures/foreign.sgra`. So ./strictdoc-grammar-model-equal.nix and
# ./strictdoc-grammar-foreign-roundtrip.nix stay green with the type check
# deleted; ./strictdoc-grammar-negative-fixtures.nix only ever exercises
# `lib/emit.nix`'s own duplicate assertions; and
# ./strictdoc-grammar-surface-current.nix diffs the generated FILES without ever
# applying them to a value. Four green checks, and not one of them could tell a
# live surface from an inert one.
#
# The gate is therefore a DIFFERENTIAL, not a rejection count. Every case below
# must be rejected by `grammar.render` (types, then emitter). The ones marked
# `surfaceOnly` must ALSO be ACCEPTED by `grammar.emit.grammar` (emitter alone),
# because the emitter reads named keys with `or` defaults and is blind to them:
#   - an extra key it never reads (`choices` on a `String` field, a stray key on
#     the element or in a field body) is simply not rendered;
#   - a value outside a vocabulary (`VIEW_STYLE`, the `TAG` charset) is
#     interpolated verbatim into a file strictdoc then refuses;
#   - an OMITTED `required` becomes `REQUIRED: False` via `or false` -- a
#     silently wrong file rather than an error.
# For those, "rejected" can only have come from the types. A case that both
# arms reject proves nothing about the surface and is FAILED as such, which is
# what stops this check decaying into a second copy of the negative fixtures.
#
# The three cases the brief names as MEASURED -- `raw` with choices on a string
# kind, two kinds at once, an unknown kind -- are all kept, even though the
# emitter independently rejects the last two, because the acceptance list names
# them. They are simply not the ones carrying the differential.
#
# POSITIVE CONTROLS, since every case is of the form "this was rejected":
#   - the valid element must render through the type check (else the surface
#     rejects everything and proves nothing);
#   - the same element must render through the emitter alone (else the bypass
#     arm is broken and every `surfaceOnly` verdict is unreadable);
#   - at least one `surfaceOnly` case must exist (else the differential is gone
#     and the check has quietly become a rejection count again).
#
# It all runs in NIX EVALUATION -- `tryEval` over a forced render -- so the
# derivation body only reads the verdicts off and picks an exit code.
{
  lib,
  pkgs,
  self,
}: let
  grammarDir = "${self}/packages/strictdoc-grammar";

  grammar = import "${grammarDir}/lib" {inherit lib;};

  # Plain data against the NORMALIZED element shape, like the `.nix` negative
  # fixtures and for the same reason: a weakening must not be expressible
  # through the DSL for this to mean anything, so it is written underneath it.
  # `title` sits INSIDE the chosen alternative -- each `GrammarElementField*`
  # rule carries its own TITLE production.
  validField = {
    string = {
      title = "UID";
      required = true;
    };
  };

  base = {
    tag = "NOTE";
    prefix = "NOTE-";
    fields = [validField];
  };

  withFields = fields: base // {inherit fields;};

  # Force the whole render: `render` returns a string, so taking its length
  # evaluates the type check and every assertion the emitter carries.
  accepts = renderer: value:
    (builtins.tryEval (builtins.stringLength (renderer [value]))).success;

  # Types, then emitter.
  checked = accepts grammar.render;
  # Emitter ONLY -- `lib/check.nix` bypassed. This is the bypass the header
  # describes, made into a probe.
  emitted = accepts grammar.emit.grammar;

  cases = [
    {
      name = "choices-on-a-string-kind";
      surfaceOnly = true;
      value = withFields [
        {
          string = {
            title = "UID";
            required = true;
            choices = ["alpha" "beta"];
          };
        }
      ];
    }
    {
      name = "an-unknown-key-on-the-element";
      surfaceOnly = true;
      value = base // {bogusProperty = true;};
    }
    {
      name = "an-unknown-key-in-a-field-body";
      surfaceOnly = true;
      value = withFields [
        {
          string = {
            title = "UID";
            required = true;
            bogusKey = 1;
          };
        }
      ];
    }
    {
      name = "a-view-style-outside-the-vocabulary";
      surfaceOnly = true;
      value = base // {viewStyle = "Bogus";};
    }
    {
      name = "a-tag-outside-the-tag-charset";
      surfaceOnly = true;
      value = base // {tag = "note";};
    }
    {
      # `REQUIRED` is mandatory on every field in the grammar and the surface
      # gives it no default, so this is the emitter's most dangerous blind spot:
      # `or false` renders `REQUIRED: False` and the file parses.
      name = "a-field-with-required-omitted";
      surfaceOnly = true;
      value = withFields [{string = {title = "UID";};}];
    }
    {
      name = "two-kinds-on-one-field";
      surfaceOnly = false;
      value = withFields [
        {
          string = {
            title = "UID";
            required = true;
          };
          tag = {
            title = "LABELS";
            required = false;
          };
        }
      ];
    }
    {
      name = "an-unknown-field-kind";
      surfaceOnly = false;
      value = withFields [
        {
          bogusKind = {
            title = "UID";
            required = true;
          };
        }
      ];
    }
    {
      # The File relation has no REVERSE_ROLE production at all (MEASURED).
      name = "a-file-relation-carrying-a-reverse-role";
      surfaceOnly = false;
      value =
        base
        // {
          relations = [
            {
              file = {
                role = "Verifies";
                reverseRole = "Verified_By";
              };
            }
          ];
        };
    }
  ];

  verdict = case: let
    byTypes = checked case.value;
    byEmitter = emitted case.value;
  in
    if byTypes
    then "FAIL ${case.name}: ACCEPTED -- the option surface does not reject it"
    else if case.surfaceOnly && !byEmitter
    then "FAIL ${case.name}: rejected, but the EMITTER rejects it too -- it carries no evidence that the types are live"
    else if case.surfaceOnly
    then "ok   ${case.name}: rejected by the types (the emitter alone ACCEPTS it)"
    else "ok   ${case.name}: rejected";

  controls =
    [
      (
        if checked base
        then "ok   control: the valid element renders through the type check"
        else "FAIL control: the VALID element was REJECTED by the type check -- the surface rejects everything and proves nothing"
      )
      (
        if emitted base
        then "ok   control: the valid element renders through the emitter alone"
        else "FAIL control: the valid element failed the EMITTER-ONLY arm -- the bypass probe is broken, so every surface-only verdict below is unreadable"
      )
    ]
    ++ (
      let
        differential = lib.count (case: case.surfaceOnly) cases;
      in
        lib.singleton (
          if differential > 0
          then "ok   control: ${toString differential} case(s) the emitter alone accepts -- the differential is intact"
          else "FAIL control: no surfaceOnly case remains -- this check has decayed into a rejection count"
        )
    );

  report = pkgs.writeText "strictdoc-grammar-surface-live.txt" (
    lib.concatStringsSep "\n" (
      ["== positive controls =="]
      ++ controls
      ++ ["== weakened values, which must not type-check =="]
      ++ map verdict cases
    )
    + "\n"
  );
in
  pkgs.runCommand "strictdoc-grammar-surface-live" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    cat ${report}

    if grep -q '^FAIL' ${report}; then
      echo "" >&2
      echo "the generated option surface is NOT doing the work:" >&2
      grep '^FAIL' ${report} >&2
      exit 1
    fi

    echo "generated grammar surface: live" | tee "$out"
  ''
