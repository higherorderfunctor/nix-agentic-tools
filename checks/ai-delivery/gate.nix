# Pure gate shared by the production contract and the deliberately broken
# module fixture. Evaluators return config; no test owns a second gate.
{lib}: {
  correspondenceErrors ? [],
  evaluators,
  policy,
}: let
  inspect = writer: let
    evaluate = declaration:
      evaluators.${writer.mode} (lib.mkMerge [
        {ai.${writer.ecosystem}.enable = true;}
        writer.probe.base
        declaration
      ]);
    full = evaluate writer.probe.nonEmpty;
    empty = evaluate writer.probe.empty;
    # The body TEXT, not a bool. Presence under both declarations is not
    # delivery: a writer with a constant body ignores its pool entirely and
    # passes both arms, which is why the third arm compares the two bodies.
    #
    # The body is read with hasAttrByPath + getAttrFromPath on the full path
    # rather than through an `or ""` accessor: "" has to be a verdict this
    # function reaches, never a default an accessor invented. An absent,
    # non-string or whitespace-only body is "" and fails the first two arms.
    #
    # A writer that declares `declarationIndependent` inverts the third arm
    # rather than escaping it — a retirement writer deletes what a PRIOR
    # generation recorded, so a body that varies with the current declaration
    # refutes the claim and is the error.
    bodyPath =
      writer.writerAttr
      ++ [
        (
          if writer.mode == "hm"
          then "text"
          else "exec"
        )
      ];
    body = config:
      if !(lib.hasAttrByPath bodyPath config)
      then ""
      else let
        text = lib.getAttrFromPath bodyPath config;
      in
        if builtins.isString text && builtins.match "[[:space:]]*" text == null
        then text
        else "";
    bodies = {
      empty = body empty;
      nonEmpty = body full;
    };
    label = "${policy.key writer}: ${lib.showOption writer.writerAttr}";
    # `exemption` cannot excuse THIS. An exemption is a countdown on a writer
    # the gate can see misbehave; absence under the non-empty declaration
    # means `writerAttr` resolves to nothing under either one, so there is no
    # observation to spend down, and a typo'd attribute name reads exactly
    # like a documented defect. A row that really has no writer says so with
    # `absentWriter`, whose own countdown runs the other way.
    absent = lib.optional (bodies.nonEmpty == "") "${label}: writer absent for NON-EMPTY declaration";
    # Excusable by `exemption`: the writer exists and behaved wrongly.
    excusable =
      lib.optional (bodies.empty == "") "${label}: writer absent for EMPTY declaration (removal would never run)"
      ++ lib.optionals (bodies.nonEmpty != "") (
        if writer ? declarationIndependent
        then
          lib.optional (bodies.nonEmpty != bodies.empty)
          "${label}: declared declaration-independent but its body varies with the declaration"
        else
          lib.optional (bodies.nonEmpty == bodies.empty)
          "${label}: writer body is IDENTICAL for NON-EMPTY and EMPTY declarations (the declaration is never read)"
      );
    failures = absent ++ excusable;
    # `config.assertions`, never `config.assertions or []`: an evaluator that
    # never declared the option is a broken harness, not a passing writer.
    assertionFailures = lib.concatMap (config:
      map (a: "${label}: ${a.message}")
      (lib.filter (a: !a.assertion) config.assertions)) [full empty];
  in {
    inherit failures label;
    errors =
      assertionFailures
      ++ (
        # An attested-absent writer has no body to judge, so every body
        # failure is recorded; the countdown is inverted instead — the row
        # errors the moment the attribute starts existing. An `exemption`
        # keeps answering for the two behavioral arms only.
        if writer ? absentWriter
        then []
        else if writer ? exemption
        then absent
        else failures
      )
      ++ lib.optional (writer ? absentWriter && absent == []) "${label}: absentWriter record is stale; the declared attribute now exists"
      ++ lib.optional (writer ? exemption && failures == []) "${label}: exemption is stale; writer now survives both declarations";
    exempted =
      if writer ? absentWriter || writer ? exemption
      then failures
      else [];
  };
  results = map inspect policy.imperativeWriters;
  # Generated writer names make the first arm a name-agreement tautology for
  # derived rows. Empty-declaration survival and body variation still measure
  # behavior; live correspondence remains independent of committed row data.
  errors = correspondenceErrors ++ lib.concatMap (result: result.errors) results;
in {
  inherit errors results;
  checked = builtins.length results;
  passed = assert lib.assertMsg (results != []) "ai-delivery: no imperative writers were checked";
  assert lib.assertMsg (errors == []) ("ai-delivery gate failed:\n" + lib.concatStringsSep "\n" errors); true;
}
