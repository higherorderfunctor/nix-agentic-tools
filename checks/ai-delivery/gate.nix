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
    present = config: let
      bodyPath =
        writer.writerAttr
        ++ [
          (
            if writer.mode == "hm"
            then "text"
            else "exec"
          )
        ];
    in
      lib.hasAttrByPath bodyPath config
      && (let
        body = lib.getAttrFromPath bodyPath config;
      in
        builtins.isString body && builtins.match "[[:space:]]*" body == null);
    label = "${policy.key writer}: ${lib.showOption writer.writerAttr}";
    failures =
      lib.optional (!(present full)) "${label}: writer absent for NON-EMPTY declaration"
      ++ lib.optional (!(present empty)) "${label}: writer absent for EMPTY declaration (removal would never run)";
    assertionFailures = lib.concatMap (config:
      map (a: "${label}: ${a.message}")
      (lib.filter (a: !a.assertion) config.assertions)) [full empty];
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
