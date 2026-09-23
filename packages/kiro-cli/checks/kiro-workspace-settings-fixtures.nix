# Fixture suite for the kiro workspace-settings allowlist extractor.
#
# The extractor's GUARDS are the entire safety story for a merge-blocking
# assertion: `mkDevenvWorkspaceSettingsAssertions` rejects any native.settings
# key outside the list this script produces, so an under-capture does not
# degrade gracefully — it rejects settings kiro actually honors. The drift
# check (./kiro-cli-extracted.nix) only ever exercises ONE input, the pinned
# binary, on the happy path; it cannot fail on a shape that binary does not
# have, which is precisely where the guards live.
#
# So each case below drives the REAL script — `vu.kiroSettingsExtractScript`,
# not a copy — over a synthesized input, and states what it proves. Synthesized
# rather than committed, because the alternative is checking ~800 MB of
# proprietary ELF into the tree to test a regex.
#
# The distinction cases 2 and 3 pin is the one the whole design turns on: an
# empty result must mean "upstream has no workspace merge" and never "upstream
# has one and we could not read it".
{pkgs, ...}: {
  checks.kiro-workspace-settings-fixtures = let
    vu = import ../lib/packaging.nix;
    script = vu.kiroSettingsExtractScript pkgs;
    # The registry pair every case needs: the script refuses to conclude anything
    # without it, so its absence is case 4 rather than a property of the others.
    registry = ''CHAT_DEFAULT_MODEL:"chat.defaultModel",CHAT_MODEL_DEFAULTS:"chat.modelDefaults",'';
    marker = "[cli-settings] failed to read workspace cli.json";
    # Shaped like the real thing: two SYMBOLIC members and two literal ones, so
    # case 1 controls both resolution paths rather than only the easy one.
    realSet = ''new Set([pn.CHAT_DEFAULT_MODEL,pn.CHAT_MODEL_DEFAULTS,"chat.defaultAgent","chat.enableThinking","chat.enableKnowledge","chat.enableCodeIntelligence","chat.enableTodoList","chat.enableCheckpoint","chat.enableTangentMode","chat.disableAutoCompaction","chat.enableSubagent","chat.enableDelegate"])'';
  in
    pkgs.runCommandLocal "kiro-workspace-settings-fixtures-check" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      python3="${pkgs.python3}/bin/python3"
      printf="${pkgs.coreutils}/bin/printf"
      grep="${pkgs.gnugrep}/bin/grep"
      jq="${pkgs.jq}/bin/jq"

      # Runs the script and requires it to SUCCEED with the given field equal to
      # the given compact JSON. Comparing one field at a time rather than the
      # whole object keeps each case's expectation readable and lets a case say
      # which of the two emitted lists it is actually about.
      expect_field() {
        local name="$1" filter="$2" want="$3" got=""
        if ! "$python3" ${script} "./$name" >./out 2>./err; then
          echo "FAIL [$name]: expected success, got exit failure:" >&2
          cat ./err >&2
          exit 1
        fi
        got=$("$jq" -c "$filter" ./out)
        if [ "$got" != "$want" ]; then
          echo "FAIL [$name]: $filter expected $want, got $got" >&2
          exit 1
        fi
        echo "ok [$name $filter]"
      }

      # Runs the script and requires it to FAIL with a message naming the cause.
      # Matching the message, not merely the exit code, is what stops one guard's
      # failure from being mistaken for another's.
      expect_fail() {
        local name="$1" phrase="$2"
        if "$python3" ${script} "./$name" >./out 2>./err; then
          echo "FAIL [$name]: expected failure, but it succeeded with: $(cat ./out)" >&2
          exit 1
        fi
        if ! "$grep" -qF -e "$phrase" ./err; then
          echo "FAIL [$name]: expected a message containing '$phrase', got:" >&2
          cat ./err >&2
          exit 1
        fi
        echo "ok [$name]"
      }

      # 1. Happy path. Both members that exist only as `pn.SCREAMING` must come
      #    back resolved, or the symbolic path is silently dead and the allowlist
      #    is short by exactly the keys nobody notices missing.
      "$printf" '%s' '${registry}${marker}${realSet}' > ./case-happy
      expect_field case-happy .workspaceOverridableSettings \
        '["chat.defaultAgent","chat.defaultModel","chat.disableAutoCompaction","chat.enableCheckpoint","chat.enableCodeIntelligence","chat.enableDelegate","chat.enableKnowledge","chat.enableSubagent","chat.enableTangentMode","chat.enableThinking","chat.enableTodoList","chat.modelDefaults"]'

      # 1b. The same scan's OTHER output: the key registry, which is the flatten
      #     boundary rather than an allowlist. It is emitted even when nothing is
      #     workspace-overridable, so cases 1b and 3 together show the two fields
      #     are independent.
      expect_field case-happy .settingKeys '["chat.defaultModel","chat.modelDefaults"]'

      # 2. THE case this design exists for: the merge code is present but the set
      #    cannot be read (here, a nested array member truncates the body). An
      #    empty list would make the module reject every workspace key, so this
      #    must fail loudly instead.
      "$printf" '%s' '${registry}${marker}new Set(["chat.enableTangentMode",[1],"chat.enableThinking"])' > ./case-unreadable
      expect_fail case-unreadable "DOES merge a workspace cli.json"

      # 3. Positive control for case 2 — without it, a guard that always fired
      #    would pass case 2 just as well. No merge code means an empty allowlist
      #    is the TRUE answer, and every kiro before 2.21.1 is this case.
      "$printf" '%s' '${registry}nothing here merges anything' > ./case-no-merge
      expect_field case-no-merge .workspaceOverridableSettings '[]'
      expect_field case-no-merge .settingKeys '["chat.defaultModel","chat.modelDefaults"]'

      # 4. Registry gone: the JS payload is not what we think it is, so "no
      #    allowlist" would be a guess rather than a finding.
      "$printf" '%s' 'no settings registry in this file at all' > ./case-no-registry
      expect_fail case-no-registry "ANCHOR failure"

      # 5. Two candidate sets — the extract describes one binary and one set.
      "$printf" '%s' '${registry}${marker}${realSet}${realSet}' > ./case-ambiguous
      expect_fail case-ambiguous "ambiguous"

      # 6. Truncation that still CLOSES. A member like `g(z[0])` ends the body at
      #    its `]`, which happens to be followed by `)`, so the match succeeds on
      #    a prefix: measured on a 24-member set this returned 12 keys, resolved
      #    cleanly and cleared the size floor. That is the one under-capture the
      #    resolution guards cannot see, and the module would have rejected the
      #    12 keys that fell off.
      "$printf" '%s' '${registry}${marker}new Set(["chat.enableTangentMode","chat.enableThinking","chat.enableKnowledge","chat.enableCheckpoint",g(z[0]),"chat.enableTodoList","chat.enableSubagent"])' > ./case-truncated
      expect_fail case-truncated "was TRUNCATED"

      # 7. A member symbol with no registry entry. Dropping it would yield a
      #    SHORT list that looks plausible, which is the under-capture direction.
      "$printf" '%s' '${registry}${marker}new Set([pn.CHAT_MYSTERY_KEY,"chat.enableTangentMode","chat.enableThinking"])' > ./case-unresolved
      expect_fail case-unresolved "PARTIAL allowlist"

      ${pkgs.coreutils}/bin/mkdir -p "$out"
      ${pkgs.coreutils}/bin/touch "$out/ok"
    '';
}
