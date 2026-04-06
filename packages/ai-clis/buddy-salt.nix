# mkBuddySalt — compute the buddy salt for a given user + trait combo.
{
  bun,
  jq,
  any-buddy-source,
  runCommand,
}: {
  userId,
  species,
  rarity ? "common",
  eyes ? "·",
  hat ? "none",
  shiny ? false,
  peak ? null,
  dump ? null,
}: let
  assertions = [
    {
      check = peak != dump || peak == null;
      msg = "withBuddy: peak and dump stats must differ";
    }
    {
      check = rarity == "common" -> hat == "none";
      msg = "withBuddy: common rarity forces hat = \"none\"";
    }
  ];
  failedAssertions = builtins.filter (a: !a.check) assertions;
  assertionErrors = builtins.map (a: a.msg) failedAssertions;
in
  assert assertionErrors == [] || throw (builtins.concatStringsSep "\n" assertionErrors);
    runCommand "buddy-salt-${species}-${rarity}" {
      nativeBuildInputs = [bun jq];
      inherit userId species rarity eyes hat;
      shinyFlag =
        if shiny
        then "true"
        else "";
      peakStat =
        if peak != null
        then peak
        else "";
      dumpStat =
        if dump != null
        then dump
        else "";
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      salt=$(bun ${any-buddy-source}/src/finder/worker.ts \
        "$userId" "$species" "$rarity" "$eyes" "$hat" \
        "$shinyFlag" "$peakStat" "$dumpStat" \
        | jq -r '.salt')

      if [[ ! "$salt" =~ ^[a-zA-Z0-9_-]{15}$ ]]; then
        echo "ERROR: invalid salt format: '$salt'" >&2
        exit 1
      fi

      echo -n "$salt" > $out
    ''
