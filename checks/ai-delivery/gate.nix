# Pure gate shared by the production contract and the deliberately broken
# module fixture. Evaluators return config; no test owns a second gate.
{lib}: {
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
    # An absent, non-string or empty body is "" and fails the first two arms.
    #
    # A writer that declares `declarationIndependent` inverts the third arm
    # rather than escaping it — a retirement writer deletes what a PRIOR
    # generation recorded, so a body that varies with the current declaration
    # refutes the claim and is the error.
    body = config: let
      entry = lib.attrByPath writer.writerAttr {} config;
      text =
        if writer.mode == "hm"
        then entry.text or ""
        else entry.exec or "";
    in
      if lib.hasAttrByPath writer.writerAttr config && builtins.isString text
      then text
      else "";
    bodies = {
      empty = body empty;
      nonEmpty = body full;
    };
    label = "${policy.key writer}: ${lib.showOption writer.writerAttr}";
    failures =
      lib.optional (bodies.nonEmpty == "") "${label}: writer absent for NON-EMPTY declaration"
      ++ lib.optional (bodies.empty == "") "${label}: writer absent for EMPTY declaration (removal would never run)"
      ++ lib.optionals (bodies.nonEmpty != "") (
        if writer ? declarationIndependent
        then
          lib.optional (bodies.nonEmpty != bodies.empty)
          "${label}: declared declaration-independent but its body varies with the declaration"
        else
          lib.optional (bodies.nonEmpty == bodies.empty)
          "${label}: writer body is IDENTICAL for NON-EMPTY and EMPTY declarations (the declaration is never read)"
      );
    assertionFailures = lib.concatMap (config:
      map (a: "${label}: ${a.message}")
      (lib.filter (a: !a.assertion) (config.assertions or []))) [full empty];
  in {
    inherit failures label;
    errors =
      assertionFailures
      ++ (
        if writer ? exemption
        then []
        else failures
      )
      ++ lib.optional (writer ? exemption && failures == []) "${label}: exemption is stale; writer now survives both declarations";
    exempted =
      if writer ? exemption
      then failures
      else [];
  };
  results = map inspect policy.imperativeWriters;
  errors = lib.concatMap (result: result.errors) results;
in {
  inherit errors results;
  checked = builtins.length results;
  passed = assert lib.assertMsg (results != []) "ai-delivery: no imperative writers were checked";
  assert lib.assertMsg (errors == []) ("ai-delivery gate failed:\n" + lib.concatStringsSep "\n" errors); true;
}
