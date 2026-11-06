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
      # key; an absent map and a non-literal entry each fail by name.
      kiro-hook-triggers-fixtures = let
        bundle = key: value: "var M=Object.freeze({${key}:${value},SessionEnd:\"SessionEnd\",Stop:\"Stop\",PreToolUse:\"PreToolUse\",PostToolUse:\"PostToolUse\",PreTaskExec:\"PreTaskExec\",PostTaskExec:\"PostTaskExec\",UserPromptSubmit:\"UserPromptSubmit\",PostFileCreate:\"PostFileCreate\",PostFileSave:\"PostFileSave\",PostFileDelete:\"PostFileDelete\",Manual:\"Manual\",agentSpawn:\"SessionStart\"});";
        extract = (import ../lib/packaging.nix).kiroHookTriggersExtractScript pkgs;
      in
        pkgs.runCommand "kiro-hook-triggers-fixtures" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          jq=${pkgs.jq}/bin/jq
          printf '%s' ${pkgs.lib.escapeShellArg (bundle "\"SessionStart\"" "\"SessionStart\"")} > quoted.js
          printf '%s' 'var M=Object.freeze({});' > absent.js
          printf '%s' ${pkgs.lib.escapeShellArg (bundle "SessionStart" "\"Session\"+\"Start\"")} > computed.js
          ${extract} quoted.js > quoted.json
          [ "$("$jq" '.hookTriggers | length' quoted.json)" = 12 ]
          [ "$("$jq" -r '.hookTriggerAliases.agentSpawn' quoted.json)" = SessionStart ]
          for case in absent:"hook trigger map is absent" computed:"non-literal entry"; do
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
      kiro-rollout-fixtures = pkgs.runCommand "kiro-rollout-fixtures" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 - ${(import ../lib/packaging.nix).kiroRolloutExtractScript pkgs} <<'PY'
        import json, pathlib, subprocess, sys
        manifest = {"v3_prompt": {"description": "", "treatment_percent": 10, "internal_treatment_percent": 50}}
        data = json.dumps(manifest, indent=2).encode()
        path = pathlib.Path("binary")
        for blob, error in [(data + b'\0' + json.dumps({"other": {"description": ""}}, indent=2).encode(), "conflicting rollout copies"), (b"no manifest", "no rollout manifest found"), (data[:-2], "rollout manifest end not found")]:
            path.write_bytes(blob)
            result = subprocess.run([sys.executable, sys.argv[1], str(path)], capture_output=True, text=True)
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
          # The block form `Possible values:` and an alias on its own line.
          (optionNeed "acp" "--auth-method" {
            aliases = ["--authMethod"];
            possibleValues = ["cli" "client"];
            takesValue = true;
            valueName = "METHOD";
          })
          # The inline form `[possible values: …]`, in printed order.
          (optionNeed "acp" "--agent-engine" {
            possibleValues = ["v2" "v1" "v3"];
            takesValue = true;
            valueName = "ENGINE";
          })
          (optionNeed "chat" "--format" {
            possibleValues = ["plain" "json" "json-pretty"];
            short = "-f";
            takesValue = true;
            valueName = "FORMAT";
          })
          # The compact top-level layout: an alias on a continuation line.
          (optionNeed "top" "--resume-picker" {aliases = ["--list"];})
          # `...` marks a count flag.
          (optionNeed "top" "--verbose" {
            count = true;
            short = "-v";
          })
          # The top-level options that take a value.
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
