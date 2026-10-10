# One shell case of a check that runs a script outside its own derivation,
# so a case that must fail can. `command` must fail naming every fragment of
# `names` on stderr, or pass when `names` is empty; stderr names no `omits`.
{lib}: {
  command,
  label,
  names ? [],
  omits ? [],
}: let
  err = ''"$TMPDIR/${label}.err"'';
  expected =
    if names == []
    then "pass"
    else "fail";
  fail = message: ''{ echo "FAIL: ${label} ${message}:" >&2; cat ${err} >&2; exit 1; }'';
in
  ''
    if ${command} 2> ${err}; then status=pass; else status=fail; fi
    [ "$status" = ${expected} ] || ${fail "must ${expected}"}
  ''
  + lib.concatMapStrings (name: "grep -qF ${lib.escapeShellArg name} ${err} || ${fail "does not name ${name}"}\n") names
  + lib.concatMapStrings (name: "if grep -qF ${lib.escapeShellArg name} ${err}; then ${fail "names ${name}"}; fi\n") omits
