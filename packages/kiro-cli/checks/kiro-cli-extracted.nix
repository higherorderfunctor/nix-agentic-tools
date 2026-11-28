# Drift check — every platform's side of the committed
# packages/kiro-cli/extracted/extracted.json must match what that platform's
# release contains, the facts must merge across systems, and the facts the
# Kiro modules were written against must still hold. Blocking (a typed trigger
# vanishing is a correctness signal the typed surface must react to). The build
# of passthru.extracted also enforces the shape assertions baked into
# vu.mkKiroExtract's locators.
#
# The option tables of `--help` (`cli.options`) are the one host-run fact: the
# x86_64-linux extraction runs the Linux payload, and that single measurement is
# declared for x86_64-linux only (clap compiles the tables from one source; the
# Darwin runner is capped). Its build log prints the whole measured table.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (import ../lib/friendly-features.nix) featureSettingImplications friendlyRolloutFeatures;
    inherit (extractedLib {inherit pkgs;}) mkOwnerCheck;
  in
    {
      # The trigger-map locator on synthetic bundles: a quoted key is the same
      # key, the map is still found beside the engine's hook exit-code effect
      # table, and zero maps, two maps and non-literal entries each fail with
      # their own diagnostic.
      kiro-hook-triggers-fixtures = let
        # One frozen trigger map bound to `binding`, its `SessionStart` entry
        # spelled `key:value` so the fixtures can vary quoting and literalness.
        triggerMap = binding: key: value: "var ${binding}=Object.freeze({${key}:${value},SessionEnd:\"SessionEnd\",Stop:\"Stop\",PreToolUse:\"PreToolUse\",PostToolUse:\"PostToolUse\",PreTaskExec:\"PreTaskExec\",PostTaskExec:\"PostTaskExec\",UserPromptSubmit:\"UserPromptSubmit\",PostFileCreate:\"PostFileCreate\",PostFileSave:\"PostFileSave\",PostFileDelete:\"PostFileDelete\",Manual:\"Manual\",agentSpawn:\"SessionStart\"});";
        computedMap = triggerMap "M" "SessionStart" "\"Session\"+\"Start\"";
        # The engine's hook exit-code effect table: keyed by trigger names like
        # the map, but its values are objects or a shared reference.
        exitCodeTable = "var N={0:\"none\",1:\"none\",2:\"none\",other:\"none\"};var E=Object.freeze({SessionStart:{0:\"stdout\",1:\"none\",2:\"none\",other:\"none\"},SessionEnd:N,Stop:{0:\"stop-decision\",1:\"keep-working\",2:\"none\",other:\"none\",decidesWhenUnfinished:!0},PreToolUse:{0:\"permission-decision\",1:\"none\",2:\"block\",other:\"none\"}});";
        extract = (import ../lib/packaging.nix).kiroHookTriggersExtractScript pkgs;
        # A literal map with `SessionStart` quoted: recognize it even when
        # an identifier-keyed effect table appears first.
        literalMap = binding: triggerMap binding "\"SessionStart\"" "\"SessionStart\"";
      in
        pkgs.runCommand "kiro-hook-triggers-fixtures" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          jq=${pkgs.jq}/bin/jq
          printf '%s' 'var M=Object.freeze({});' > absent.js
          printf '%s' ${pkgs.lib.escapeShellArg computedMap} > computed.js
          # A locator that accepts a computed map beside the effect table
          # would succeed where the production bundle should be refused.
          printf '%s' ${pkgs.lib.escapeShellArg (exitCodeTable + computedMap)} > exit-codes-computed.js
          # The table comes first, as in the 3.6.0 bundle, so a locator that
          # takes the first `SessionStart` object picks the table here.
          printf '%s' ${pkgs.lib.escapeShellArg (exitCodeTable + literalMap "M")} > exit-codes.js
          # A locator that takes the first or the last map instead of failing
          # succeeds here.
          printf '%s' ${pkgs.lib.escapeShellArg (literalMap "M" + literalMap "N")} > ambiguous.js
          # The effect table alone is an absent map, not a map with a computed
          # entry: a locator that diagnoses any lone candidate as non-literal fails.
          printf '%s' ${pkgs.lib.escapeShellArg exitCodeTable} > table-only.js
          ${extract} exit-codes.js > exit-codes.json
          [ "$("$jq" -c '.hookTriggers' exit-codes.json)" = '["Manual","PostFileCreate","PostFileDelete","PostFileSave","PostTaskExec","PostToolUse","PreTaskExec","PreToolUse","SessionEnd","SessionStart","Stop","UserPromptSubmit"]' ]
          [ "$("$jq" -c '.hookTriggerAliases' exit-codes.json)" = '{"agentSpawn":"SessionStart"}' ]
          for case in \
            absent:"absent or ambiguous (0 of 0" \
            ambiguous:"absent or ambiguous (2 of 2" \
            computed:"non-literal entry" \
            exit-codes-computed:"absent or ambiguous (0 of 2" \
            table-only:"absent or ambiguous (0 of 1"; do
            status=0
            ${extract} "''${case%%:*}.js" > /dev/null 2> err.txt || status=$?
            # Two statements: the left side of `&&` is exempt from errexit, so
            # an extractor that unexpectedly exits 0 would not fail the fixture.
            [ "$status" = 1 ]
            ${pkgs.gnugrep}/bin/grep -qF "''${case#*:}" err.txt
          done
          touch "$out"
        '';
      # The real 3.0.0 help fixtures exercise both option layouts and check
      # the continuation alias in the printed table, then exercise three
      # inputs the parser refuses.
      kiro-cli-help-fixtures = pkgs.runCommand "kiro-cli-help-fixtures" {nativeBuildInputs = [pkgs.gnugrep pkgs.gnused];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        parse() { ${pkgs.python3}/bin/python3 -I ${../extract/cli-help.py} --help-dir "$1"; }
        parse ${./fixtures/help} 2> table.txt > /dev/null
        grep -q '^  top  *--resume-picker  *-  *--list' table.txt
        # Refusals, each with the message that names it.
        refuses() {
          local label="$1" message="$2" status=0
          rm -rf case && mkdir case && cp ${./fixtures/help}/*.txt case/
          chmod -R u+w case
          sed -i "$3" "case/$4"
          parse case > /dev/null 2> err.txt || status=$?
          # Two statements: the left side of `&&` is exempt from errexit.
          [ "$status" != 0 ]
          grep -qF "$message" err.txt || { echo "FAIL: $label: got $(cat err.txt)" >&2; exit 1; }
        }
        refuses "no Options section" "no Options section" 's/^Options:$/Flags:/' top.txt
        refuses "an option line it cannot read" "option line not understood" 's/^  -h, --help .*/  -h/' top.txt
        refuses "v3 gone from acp --agent-engine" "no longer lists v3" 's/v2, v1, v3/v2, v1/' acp.txt
        touch "$out"
      '';
      # Exercise both rollout scripts on synthetic payloads so extraction and
      # patch refusal agree about which embedded rows are manifest sites.
      kiro-rollout-fixtures = let
        inherit (import ../lib/packaging.nix) kiroRolloutExtractScript kiroRolloutPatchScript;
      in
        pkgs.runCommand "kiro-rollout-fixtures" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${pkgs.python3}/bin/python3 - \
            ${kiroRolloutExtractScript pkgs} ${kiroRolloutPatchScript pkgs} <<'PY'
          import json, pathlib, subprocess, sys

          extract_script, patch_script = sys.argv[1:]
          feature = "example_rollout"
          root = pathlib.Path("payload")
          root.mkdir()
          path = root / "binary"

          def run_script(script, *args):
              """Run a rollout script on the fixture and capture its diagnostics."""
              return subprocess.run([sys.executable, script, *args], capture_output=True, text=True)

          manifest = {
              feature: {
                  "description": "Enable the example rollout for selected accounts",
                  "treatment_percent": 10,
              },
          }
          data = json.dumps(manifest, indent=2).encode()
          prefix = b"\x7fELF" + data + b"\0"

          # Counting treatment-only rows would make the patch refuse. Check the
          # write on the shipped shape; extraction covers the other spellings.
          for regression, treatment_groups, check_patch in (
              ("an empty treatment list still is not a manifest site", [], False),
              ("an escaped quote does not end the treatment list", ["@kiro-cli-team", 'escaped"string'], False),
              ("the shipped team-only row is not a manifest site", ["@kiro-cli-team"], True),
          ):
              treatment = json.dumps({
                  "groups": {"kiro-cli-team": ["account"]},
                  feature: {"treatment": treatment_groups},
              }, indent=2).encode()
              path.write_bytes(prefix + treatment)
              extracted = run_script(extract_script, path)
              assert extracted.returncode == 0, (regression, extracted)
              assert json.loads(extracted.stdout) == {
                  "rolloutFeatures": ["example_rollout"],
                  "rolloutPatchability": {"example_rollout": {"patchable": True, "unmatchedSites": 0}},
                  "rolloutStates": {"example_rollout": {"treatment_percent": 10}},
              }, (regression, extracted)
              if not check_patch:
                  continue
              patched = run_script(patch_script, feature, root)
              assert patched.returncode == 0, (regression, patched)
              patched_manifest, patched_treatment = path.read_bytes().split(b"\0", 1)
              # Native offsets stay fixed and the account treatment bytes are not patched.
              assert len(patched_manifest) == len(prefix) - 1, regression
              assert patched_treatment == treatment, regression
              entry = json.loads(patched_manifest.removeprefix(b"\x7fELF"))[feature]
              assert entry["treatment_percent"] == 100 and entry["segment"] == "all", (regression, entry)

          # Matching only the opening of the row or list would allow partial
          # patches; skipping a treatment row in any layout but the one 3.6.0
          # ships would stop the match failing closed. The scalar row checks
          # the patcher refusal shared by all unmatched sites.
          only_treatment = {feature: {"treatment": ["@kiro-cli-team"]}}
          for regression, entry, indent, check_refusal in (
              ("a scalar is not a valid treatment list", {feature: {"treatment": "@kiro-cli-team"}}, 2, True),
              ("a valid first item does not excuse a non-string item", {feature: {"treatment": ["@kiro-cli-team", 5]}}, 2, False),
              ("compact layout is not the shipped treatment shape", only_treatment, None, False),
              ("extra manifest fields are not a treatment-only row", {feature: {"treatment": ["@kiro-cli-team"], **manifest[feature]}}, 2, False),
              ("wrong indentation is not the shipped treatment shape", only_treatment, 4, False),
          ):
              blob = prefix + json.dumps(entry, indent=indent).encode()
              path.write_bytes(blob)
              extracted = run_script(extract_script, path)
              assert extracted.returncode == 0, (regression, extracted)
              assert json.loads(extracted.stdout)["rolloutPatchability"][feature] == {
                  "patchable": False,
                  "unmatchedSites": 1,
              }, (regression, extracted)
              if not check_refusal:
                  continue
              refused = run_script(patch_script, feature, root)
              assert refused.returncode == 1, (regression, refused)
              assert "'example_rollout' has 1 site(s)" in refused.stderr, (regression, refused)
              assert "Refusing to half-patch." in refused.stderr, (regression, refused)
              assert path.read_bytes() == blob, regression

          for blob, error in [
              (data + b"\0" + json.dumps({"other": {"description": ""}}, indent=2).encode(),
               "conflicting rollout copies"),
              (b"no manifest", "no rollout manifest found"),
              (data[:-2], "rollout manifest end not found"),
          ]:
              path.write_bytes(blob)
              result = run_script(extract_script, path)
              assert result.returncode == 1 and error in result.stderr, result
          PY
          touch "$out"
        '';
    }
    // mkOwnerCheck {
      dir = ../extracted;
      name = "kiro-cli";
      needs =
        [
          # Calibration and catalog extraction request JSON; other formats
          # may be added without breaking either caller.
          {
            contains = "json";
            key = "cli.options.chat.--format.possibleValues";
          }
        ]
        ++ map (feature: {
          contains = feature;
          key = "rolloutFeatures";
        }) (builtins.attrValues friendlyRolloutFeatures)
        ++ map (setting: {
          contains = "chat.${setting}";
          key = "settingKeys";
        }) (builtins.attrValues featureSettingImplications);
      # Static reads of every release, run on Linux; on Darwin the check
      # compares nothing and validates the committed facts only.
      inherit (self.ciPackages.x86_64-linux.kiro-cli.passthru) extracted;
    };
}
