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
    # One option of the `--help` table as the extractor records it, with the
    # defaults of a plain flag; each need below spells out what differs.
    optionNeed = table: long: overrides: {
      key = "cli.options.${table}.${long}";
      value =
        {
          aliases = [];
          count = false;
          inherit long;
          possibleValues = [];
          short = null;
          takesValue = false;
          valueName = null;
        }
        // overrides;
    };
  in
    {
      # The trigger-map locator on synthetic bundles: a quoted key is the same
      # key, the map is still found beside the engine's hook exit-code effect
      # table. Check the diagnostics for zero or two maps and non-literal entries.
      kiro-hook-triggers-fixtures = let
        # One frozen trigger map bound to `binding`, its `SessionStart` entry
        # spelled `key:value` so the fixtures can vary quoting and literalness.
        triggerMap = binding: key: value: "var ${binding}=Object.freeze({${key}:${value},SessionEnd:\"SessionEnd\",Stop:\"Stop\",PreToolUse:\"PreToolUse\",PostToolUse:\"PostToolUse\",PreTaskExec:\"PreTaskExec\",PostTaskExec:\"PostTaskExec\",UserPromptSubmit:\"UserPromptSubmit\",PostFileCreate:\"PostFileCreate\",PostFileSave:\"PostFileSave\",PostFileDelete:\"PostFileDelete\",Manual:\"Manual\",agentSpawn:\"SessionStart\"});";
        computedMap = triggerMap "M" "SessionStart" "\"Session\"+\"Start\"";
        # The engine's hook exit-code effect table: keyed by trigger names like
        # the map, but its values are objects or a shared reference.
        exitCodeTable = "var N={0:\"none\",1:\"none\",2:\"none\",other:\"none\"};var E=Object.freeze({SessionStart:{0:\"stdout\",1:\"none\",2:\"none\",other:\"none\"},SessionEnd:N,Stop:{0:\"stop-decision\",1:\"keep-working\",2:\"none\",other:\"none\",decidesWhenUnfinished:!0},PreToolUse:{0:\"permission-decision\",1:\"none\",2:\"block\",other:\"none\"}});";
        extract = (import ../lib/packaging.nix).kiroHookTriggersExtractScript pkgs;
        # A trigger map whose every entry is a literal, with the `SessionStart`
        # key quoted. The `quoted` case checks that a quoted key is the same
        # key; `ambiguous` puts two of these in one bundle.
        literalMap = binding: triggerMap binding "\"SessionStart\"" "\"SessionStart\"";
      in
        pkgs.runCommand "kiro-hook-triggers-fixtures" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          jq=${pkgs.jq}/bin/jq
          printf '%s' ${pkgs.lib.escapeShellArg (literalMap "M")} > quoted.js
          printf '%s' 'var M=Object.freeze({});' > absent.js
          printf '%s' ${pkgs.lib.escapeShellArg computedMap} > computed.js
          # A locator that accepts a computed map beside the effect table
          # would succeed where the production bundle should be refused.
          printf '%s' ${pkgs.lib.escapeShellArg (exitCodeTable + computedMap)} > exit-codes-computed.js
          # The table comes first, as in the 3.6.0 bundle, so a locator that
          # takes the first `SessionStart` object picks the table here.
          printf '%s' ${pkgs.lib.escapeShellArg (exitCodeTable + triggerMap "M" "SessionStart" "\"SessionStart\"")} > exit-codes.js
          # A locator that takes the first or the last map instead of failing
          # succeeds here.
          printf '%s' ${pkgs.lib.escapeShellArg (literalMap "M" + literalMap "N")} > ambiguous.js
          ${extract} quoted.js > quoted.json
          [ "$("$jq" '.hookTriggers | length' quoted.json)" = 12 ]
          [ "$("$jq" -r '.hookTriggerAliases.agentSpawn' quoted.json)" = SessionStart ]
          ${extract} exit-codes.js > exit-codes.json
          [ "$("$jq" -c '.hookTriggers' exit-codes.json)" = '["Manual","PostFileCreate","PostFileDelete","PostFileSave","PostTaskExec","PostToolUse","PreTaskExec","PreToolUse","SessionEnd","SessionStart","Stop","UserPromptSubmit"]' ]
          [ "$("$jq" -c '.hookTriggerAliases' exit-codes.json)" = '{"agentSpawn":"SessionStart"}' ]
          for case in absent:"hook trigger map is absent" computed:"non-literal entry" ambiguous:"absent or ambiguous (2 of 2" exit-codes-computed:"absent or ambiguous (0 of 2"; do
            status=0
            ${extract} "''${case%%:*}.js" > /dev/null 2> err.txt || status=$?
            # Two statements: the left side of `&&` is exempt from errexit, so
            # an extractor that unexpectedly exits 0 would not fail the fixture.
            [ "$status" = 1 ]
            ${pkgs.gnugrep}/bin/grep -qF "''${case#*:}" err.txt
          done
          touch "$out"
        '';
      # The help parser on the real 3.0.0 output saved under fixtures/help: every
      # shape it has (compact and long layouts, aliases, `...` counts, inline
      # and block possible values, multi-line prose) against hand-written rows,
      # then the three inputs it refuses.
      kiro-cli-help-fixtures = pkgs.runCommand "kiro-cli-help-fixtures" {nativeBuildInputs = [pkgs.gnugrep pkgs.gnused];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        jq=${pkgs.jq}/bin/jq
        parse() { ${pkgs.python3}/bin/python3 -I ${../extract/cli-help.py} --help-dir "$1"; }
        parse ${./fixtures/help} 2> table.txt > parsed.json
        fail=0
        # expect <label> <jq filter that must hold>
        expect() {
          if ! "$jq" -e "$2" parsed.json > /dev/null; then
            echo "FAIL: $1" >&2
            fail=1
          fi
        }
        expect "table sizes" '(.cli.options | map_values(length)) == {acp: 10, chat: 30, top: 13}'
        expect "chat --output-format: block values, one description wrapped over two lines" \
          '.cli.options.chat["--output-format"].possibleValues == ["text", "stream-json"]'
        expect "chat --session-source: value name with a bar, inline values" \
          '.cli.options.chat["--session-source"] | .valueName == "v1|v2" and .possibleValues == ["v1", "v2"]'
        expect "chat --wrap: block values" \
          '.cli.options.chat["--wrap"].possibleValues == ["always", "never", "auto"]'
        expect "chat --legacy-ui: alias in the long layout" \
          '.cli.options.chat["--legacy-ui"].aliases == ["--classic"]'
        expect "chat --verbose: count flag" '.cli.options.chat["--verbose"].count'
        expect "chat --resume-picker has no alias" '.cli.options.chat["--resume-picker"].aliases == []'
        expect "top --legacy-ui: alias in the compact layout" \
          '.cli.options.top["--legacy-ui"].aliases == ["--classic"]'
        expect "top --resume-picker: alias on a continuation line" \
          '.cli.options.top["--resume-picker"].aliases == ["--list"]'
        expect "top --version: short name without a value" \
          '.cli.options.top["--version"] | .short == "-V" and .takesValue == false'
        expect "acp --auth-method: block values and an alias" \
          '.cli.options.acp["--auth-method"] | .aliases == ["--authMethod"] and .possibleValues == ["cli", "client"]'
        expect "acp has no top-only option" '.cli.options.acp | has("--resume") | not'
        [ "$fail" = 0 ]
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

          # Counting treatment-only rows would make these patches refuse.
          for treatment_groups in (["@kiro-cli-team"], [], ["@kiro-cli-team", 'escaped"string']):
              treatment = json.dumps({
                  "groups": {"kiro-cli-team": ["account"]},
                  feature: {"treatment": treatment_groups},
              }, indent=2).encode()
              path.write_bytes(prefix + treatment)
              extracted = run_script(extract_script, path)
              assert extracted.returncode == 0, extracted
              assert json.loads(extracted.stdout)["rolloutPatchability"][feature] == {
                  "patchable": True,
                  "unmatchedSites": 0,
              }, extracted
              patched = run_script(patch_script, feature, root)
              assert patched.returncode == 0, patched
              patched_manifest, patched_treatment = path.read_bytes().split(b"\0", 1)
              assert len(patched_manifest) == len(prefix) - 1
              assert patched_treatment == treatment
              entry = json.loads(patched_manifest.removeprefix(b"\x7fELF"))[feature]
              assert entry["treatment_percent"] == 100 and entry["segment"] == "all", entry

          # Matching only the opening of the row or list would allow partial patches.
          for row in (
              {"treatment": "@kiro-cli-team"},
              {"treatment": ["@kiro-cli-team", 5]},
              {"treatment": ["@kiro-cli-team"], **manifest[feature]},
          ):
              blob = prefix + json.dumps({feature: row}, indent=2).encode()
              path.write_bytes(blob)
              extracted = run_script(extract_script, path)
              assert extracted.returncode == 0, extracted
              assert json.loads(extracted.stdout)["rolloutPatchability"][feature] == {
                  "patchable": False,
                  "unmatchedSites": 1,
              }, extracted
              refused = run_script(patch_script, feature, root)
              assert refused.returncode == 1 and "Refusing to half-patch." in refused.stderr, refused
              assert path.read_bytes() == blob

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
          {
            contains = "SessionStart";
            key = "hookTriggers";
          }
          {
            contains = "chat.modelDefaults";
            key = "settingKeys";
          }
          {
            contains = "chat.defaultModel";
            key = "workspaceOverridableSettings";
          }
          {
            contains = "chat.enableTangentMode";
            key = "workspaceOverridableSettings";
          }
          # Vocabulary no code here consumes is pinned by membership, so an
          # upstream addition shows only as drift of the committed raw.
          # The inline form `[possible values: …]`; the launcher appends `v3`.
          {
            contains = "v3";
            key = "cli.options.acp.--agent-engine.possibleValues";
          }
          # The block form `Possible values:`.
          {
            contains = "cli";
            key = "cli.options.acp.--auth-method.possibleValues";
          }
          {
            contains = "json";
            key = "cli.options.chat.--format.possibleValues";
          }
          # The top-level options that take a value: the scan list of
          # lib/launchValueOptions.nix is derived from this table, so these
          # records are exact.
          (optionNeed "top" "--agent" {
            takesValue = true;
            valueName = "AGENT";
          })
          (optionNeed "top" "--repo" {
            takesValue = true;
            valueName = "REPO";
          })
          (optionNeed "top" "--resume-id" {
            takesValue = true;
            valueName = "SESSION_ID";
          })
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
