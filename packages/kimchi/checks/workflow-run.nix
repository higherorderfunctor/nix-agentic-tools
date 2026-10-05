{
  pkgs,
  self,
  ...
}: let
  launcher = import ../lib/mkWorkflowRun.nix {inherit pkgs;};
  kimchiSource = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.kimchi.passthru.extractionSources.kimchi;
in {
  # Read the build's pinned source at build time, never through IFD or a stale sidecar.
  checks.kimchi-workflow-version =
    pkgs.runCommand "kimchi-workflow-version" {
      nativeBuildInputs = [pkgs.jq pkgs.yq-go];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      yq -o=json '.' ${kimchiSource}/pnpm-lock.yaml > lock.json
      jq -e '.importers["."].dependencies["@kimchi-dev/kimchi-workflows"].version | split("(")[0] == "0.0.9"' lock.json > /dev/null
      echo 'PASS: bundled workflows 0.0.9 matches the verified reader' > "$out"
    '';
  checks.kimchi-workflow-record-reader =
    pkgs.runCommand "kimchi-workflow-record-reader" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      read_case() {
        local name=$1 expected=$2 expected_exit=$3 actual_exit=0
        ${launcher}/bin/kimchi-workflow-run --read-session "$PWD/$name" 17 > result.json || actual_exit=$?
        test "$actual_exit" = "$expected_exit"
        jq -e --arg status "$expected" --arg dir "$PWD/$name" \
          '.status == $status and .sessionDir == $dir and has("eventsFile") and has("runId")' result.json >/dev/null
      }

      for status in blocked completed crashed; do
        mkdir -p "$status/workflow"
        cp ${./fixtures/workflow-run}/"$status.jsonl" "$status/workflow/run.events.jsonl"
      done
      read_case completed completed 0
      jq -e '.output.marker == "item2-ok" and .runId == "workflow-success-da9f64f0"' result.json >/dev/null
      # An agent request carries opaque history; never return it to the parent.
      jq 'if .type == "questionnaire-asked" then .conversation = [{role: "assistant", content: "private history"}] else . end' blocked/workflow/run.events.jsonl > enriched.jsonl
      mv enriched.jsonl blocked/workflow/run.events.jsonl
      read_case blocked blocked 1
      jq -e '.error.requests[0].path == "need-human" and .error.requests[0].questionnaire.questions[0].key == "answer"' result.json >/dev/null
      jq -e '(.error.requests[0] | has("conversation") | not)' result.json >/dev/null
      read_case crashed crashed 1
      jq -e '.error | contains("4000-token budget")' result.json >/dev/null

      mkdir -p none multiple/workflow
      printf 'preflight diagnostic\n' > none/stderr
      # Even a child exit of zero without a record is failure.
      ${launcher}/bin/kimchi-workflow-run --read-session "$PWD/none" 0 > result.json && exit 1
      jq -e '.status == "failed" and .eventsFile == null and (.error | contains("child exit=0") and contains("preflight diagnostic"))' result.json >/dev/null
      cp completed/workflow/run.events.jsonl multiple/workflow/one.events.jsonl
      cp completed/workflow/run.events.jsonl multiple/workflow/two.events.jsonl
      read_case multiple failed 1
      jq -e '.error | contains("ambiguous")' result.json >/dev/null

      # Source-supported boundaries beyond the three observed outcome fixtures.
      mkdir -p abandoned/workflow cancelled/workflow malformed/workflow
      head -n 2 ${./fixtures/workflow-run/completed.jsonl} > abandoned/workflow/run.events.jsonl
      read_case abandoned in_progress 1
      cp abandoned/workflow/run.events.jsonl cancelled/workflow/run.events.jsonl
      printf '%s\n' '{"type":"run-cancelled","runId":"workflow-success-da9f64f0","source":"command","at":"2026-10-04T08:20:24.182Z"}' >> cancelled/workflow/run.events.jsonl
      read_case cancelled cancelled 1
      jq -e '.error.source == "command" and .error.type == "run-cancelled"' result.json >/dev/null
      printf 'not json\n' > malformed/workflow/run.events.jsonl
      read_case malformed failed 1

      # A completed foreach sibling must not hide another item's unfinished work;
      # a new loop iteration must replace the previous iteration's blocked state.
      for case_name in active-blocked foreach loop; do
        mkdir -p "$case_name/workflow"
        jq -cn --arg name "$case_name" '
          def event($type; $path): {at: "2026-10-04T08:20:24.182Z", path: $path, runId: "synthetic", type: $type};
          event("run-started"; null),
          (if $name == "active-blocked" then
            event("step-started"; "batch@0/answer"),
            event("questionnaire-asked"; "batch@1/answer")
          elif $name == "foreach" then
            event("step-started"; "batch@0/answer"),
            event("step-completed"; "batch@1/answer")
          else
            event("questionnaire-asked"; "loop#1/answer"),
            event("step-completed"; "loop#2/answer")
          end),
          (event("run-completed"; null) + {output: "done"})
        ' > "$case_name/workflow/run.events.jsonl"
      done
      read_case active-blocked in_progress 1
      read_case foreach in_progress 1
      read_case loop completed 0
      # Re-reading must not change the saved evidence, including malformed logs.
      cp -r completed readonly
      cp -r malformed readonly-malformed
      chmod -R a-w readonly readonly-malformed
      read_case readonly completed 0
      read_case readonly-malformed failed 1
      test ! -e readonly/reader-stderr
      test ! -e readonly-malformed/reader-stderr

      # Model is mandatory before any launch (no Kimchi executable in this check).
      touch required.workflow.ts
      actual_exit=0
      ${launcher}/bin/kimchi-workflow-run "$PWD/required.workflow.ts" > result.json 2> usage || actual_exit=$?
      test "$actual_exit" = 2
      grep -F 'kimchi-workflow-run --model ID' usage
      echo PASS > "$out"
    '';
}
