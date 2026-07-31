#!/usr/bin/env bash
#
# Generate the mode-F workflow definitions.
#
# Four definitions, emitted as `*.workflow.json` beside this script:
#
#   coverage.workflow.json  a validator fixture exercising all five node types
#                           and both stop forms. NOT for running — it holds a
#                           `watch` node that would poll an external system and
#                           an `onMaxIterations: "continue"` chosen to keep the
#                           warning channel exercised.
#   drain-queue.workflow.json  the same shape against ONE shared queue: K
#                           CONTENDING claimants, which is what exercises atomic
#                           claiming, late-proposed work and duration variance.
#   drain.workflow.json     the shard drain: `parallel` over K independent
#                           self-draining `repeat` branches.
#   smoke.workflow.json     the smallest definition that proves an authored
#                           workflow ran at all.
#
# WHY GENERATED RATHER THAN HAND-WRITTEN. K appears in the drain once per
# branch — in the branch id, in the step id, and in the shard state path — so a
# hand-edited definition encodes K in 3K places and every re-sizing is a
# find-and-replace with three chances to leave a stale shard number behind. Two
# branches pointed at the same shard file is not a validation error (the ids
# still differ, the paths are still legal) and would only present as a drain
# that mysteriously double-processes one shard and never touches another. Here K
# lives in exactly one place, below, and every occurrence is derived from it.
#
# Run `./self-test-validate.sh` after regenerating: it re-runs this generator and
# refuses if the committed JSON is not what the generator produces.
#
# READ-ONLY with respect to Kiro state. Writes only into this directory.
#
# SC2016 is disabled file-wide, and file-wide is the correct scope rather than
# laziness: EVERY multi-line single-quoted string below is a jq PROGRAM, in which
# `$state_root`, `$k` and friends are jq variables bound by --arg / --argjson.
# They must not expand in the shell — quoting them the way SC2016 suggests is the
# bug, not the fix. The directive sits above `set` because shellcheck only honours
# a file-wide directive that precedes the first command.
# shellcheck disable=SC2016
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# THE ONE PLACE K LIVES
#
# K = the number of concurrent drain branches.
#
# Default 5, chosen against R-concurrency-1: the v3 per-parent subagent
# concurrency limit is MAX_CONCURRENT_SUBAGENTS = 5, and v3 QUEUES the sixth
# rather than rejecting it (v2's 4 is a different mechanism in a different
# engine). So 5 is the largest branch count that cannot be throttled by that
# semaphore under either hypothesis about whether workflow branches draw from
# it — which makes it the right FIRST run: if fewer than 5 branches are observed
# running at once, something other than that semaphore is responsible.
#
# K=6 is the follow-up probe, and it is the interesting one, because it is the
# smallest value at which "workflow branches draw permits from the subagent
# semaphore" and "they do not" predict different observations. That is the whole
# reason K is a knob and not a constant.
#
# `=` rather than `:=` on purpose. `:=` also substitutes for a set-but-EMPTY
# value, so `DRAIN_BRANCHES="$some_unset_var"` would silently become 5 instead of
# being refused — the operator would think they had chosen a K and get a
# different one. With `=` an explicit empty value falls through to the guards
# below and is rejected.
: "${DRAIN_BRANCHES=5}"
readonly K="$DRAIN_BRANCHES"

# Per-branch iteration ceiling. One iteration is intended to drain one queue
# item, so this is "the most items any single shard may hold". It is NOT a
# timeout: `onMaxIterations: "abort"` means hitting it fails the branch, which
# is the point — a shard that needed more iterations than declared did not
# drain, and must not be reported as if it had.
readonly MAX_ITERATIONS_PER_BRANCH=50

# Workspace-relative state root. Every fileCheck path below is built from this
# as a LITERAL, never as a template: see contract.jq's TRAP 3 header for why a
# templated fileCheck path skips containment validation entirely.
readonly STATE_ROOT=".kiro-harness/drain"

# The bundled workflow agent that `ralph` uses (R-workflow-7). Whether a
# user-authored agent can fill an `agent` slot is not settled by the corpus, so
# these fixtures stay on the one name known to resolve.
readonly WORKFLOW_AGENT="wf-coder"

# ---------------------------------------------------------------------------
# THE ONE PLACE THE STEP'S MODEL AND EFFORT LIVE
#
# Both are pinned deliberately, and `auto` is pinned EXPLICITLY rather than
# omitted -- those are different things. Omitting the field lets the engine
# cascade a value in from the parent session (`_kiro/workflow/new` reads
# `parentModelId` / `parentEffortLevel` off `parentSessionId`), so an identical
# definition would run differently depending on whose session started it. A
# harness that exists to compare two orchestration shapes over the same workload
# cannot have the model as a floating variable: `auto` is a ROUTER, and two runs
# it routes differently are not comparable, which is the one property the
# measurement depends on. Writing the field down also makes it a one-line
# change to re-run the whole battery against a specific model.
#
# `low` because the work each step does is mechanical -- take the first item
# whose flag is false, do it, write the file back. Effort buys reasoning depth
# that this workload has no use for, and it is charged per step per iteration,
# which a K-branch drain multiplies.
#
# These are node-level fields on `step` (the vendor's own bundled recipes set
# both, e.g. `modelId: "claude-fable-5"` with `effortLevel: "xhigh"`), and
# contract.jq already lists them among the step's optional keys.
readonly STEP_MODEL_ID="auto"
readonly STEP_EFFORT_LEVEL="low"

# ---------------------------------------------------------------------------
# Guards on K
# ---------------------------------------------------------------------------

if ! [[ $K =~ ^[0-9]+$ ]]; then
  echo "refusing: DRAIN_BRANCHES must be a decimal integer (got '${K}')" >&2
  exit 1
fi

if [ "$K" -lt 1 ]; then
  echo "refusing: K=${K} — a drain needs at least one branch" >&2
  exit 1
fi

# The ceiling is DEFAULT_MAX_STEP_NODES = 20, and it binds directly: each branch
# spends exactly one step node, and the count is structural (once per authored
# node, independent of iterations or branch runtime), so K step nodes is the
# whole budget. K=21 is not a slow workflow, it is a rejected one.
if [ "$K" -gt 20 ]; then
  echo "refusing: K=${K} exceeds maxStepNodes=20 — each branch spends one step node" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Emission
#
# jq builds every document: it owns JSON escaping, so no prompt text can break
# the file, and its output is stable enough to diff. Formatting is left to
# treefmt (biome owns *.json) — self-test-validate.sh compares generator output
# to the committed files SEMANTICALLY for exactly that reason.
# ---------------------------------------------------------------------------

emit() {
  local name="$1"
  shift
  local out="$here/${name}.workflow.json"
  jq "$@" >"$out"
  printf 'wrote %s\n' "$out"
}

# --- smoke -----------------------------------------------------------------
#
# NO `completion` FIELD, and that is a correction rather than an omission (C-18).
#
# `completion` reads like an assertion on what the step produced. It is not: it
# is the entry condition for `runCompletionLoop`, which holds the step's session
# open ACROSS TURNS, re-evaluates the condition against `capturedOutput` after
# each one, and while unsatisfied parks the node `paused` — "waiting for the
# next user message" — blocking in `awaitNextTurn`. A step with no `completion`
# returns from that loop immediately and finishes after one turn.
#
# So `completion` turns a one-shot step into a conversation, and an unattended
# driver has nobody to send the next message. The first live run of this fixture
# wrote the correct file, said the correct thing, and reported `paused` with an
# EMPTY captured output — the work done, every visible signal saying it was not.
#
# The assertion it looked like it was making belongs on the driver's side: check
# the workspace file and the agent's message stream after the run. Those are
# observations; this was a control-flow directive wearing an assertion's name.
emit smoke -n \
  --arg agent "$WORKFLOW_AGENT" \
  --arg model "$STEP_MODEL_ID" \
  --arg effort "$STEP_EFFORT_LEVEL" \
  --arg state_root "$STATE_ROOT" '
  {
    name: "mode-f-smoke",
    description: (
      "Smallest definition that proves an authored workflow actually ran: one "
      + "step, no loop, no concurrency, no file check. Run this BEFORE "
      + "drain.workflow.json — it separates \"the workflowsEnabled seed did not "
      + "take\" from \"my definition is wrong\", which are otherwise the same "
      + "symptom. `inputs` is deliberately absent here to exercise the schema "
      + "default (record(string) with .default({})), and `completion` is "
      + "deliberately absent because it would hold the step session open across "
      + "turns and park an unattended run `paused` forever (C-18)."
    ),
    steps: [
      {
        type: "step",
        id: "smoke-marker",
        agent: $agent,
        modelId: $model,
        effortLevel: $effort,
        prompt: (
          "Create the directory \($state_root) if it does not exist, write the "
          + "single line SMOKE-OK into \($state_root)/smoke.txt, then reply with "
          + "exactly SMOKE-OK and nothing else."
        )
      }
    ]
  }'

# --- drain -----------------------------------------------------------------
#
# joinPolicy MUST be "allSettled", and this corrects an earlier design that
# said "all".
#
# The reasoning is inverted from how it reads. "all" sounds like "wait for all
# of them", and the bundled workflow-creator steering even describes it as "all
# branches must succeed" — but the operative half of that sentence is the next
# one: "First failure aborts siblings." `joinAll` aborts on the first branch
# FAILURE, not on the first completion, so under "all" a single poisoned queue
# item takes down every other branch's in-flight work. For K INDEPENDENT
# self-draining branches that is exactly backwards: the branches share nothing,
# so one shard failing tells you nothing about the others and must not stop
# them.
#
# "allSettled" waits for every branch regardless of individual failures. A
# failing branch is contained, the other K-1 drain to completion, and the run
# still reports `failed` at the top level — so nothing is silently swallowed.
# That last part is what makes it safe rather than merely permissive.
#
# "any" is worse than either: `joinAny` calls abort() on every other branch
# controller the moment ONE branch completes, which for a drain means the first
# shard to finish destroys the rest.
#
# onMaxIterations MUST be "abort":
#   - "pause" is a state you cannot leave. Resuming grants no further iterations
#     (the loop re-derives its counter from the children already created, which
#     already equals maxIterations) and a paused run cannot be retried — retry
#     applies only to completed/failed/aborted. The bundled `ralph` and `goal`
#     recipes both ship "pause"; do not copy it from them.
#   - "continue" marks the repeat COMPLETED on exhaustion, which is
#     indistinguishable from a genuine drain, so an unfinished shard would score
#     as success. That is the one failure mode a drain harness must not have.

emit drain -n \
  --argjson k "$K" \
  --argjson iters "$MAX_ITERATIONS_PER_BRANCH" \
  --arg agent "$WORKFLOW_AGENT" \
  --arg model "$STEP_MODEL_ID" \
  --arg effort "$STEP_EFFORT_LEVEL" \
  --arg state_root "$STATE_ROOT" '
  # Two digits is always enough: K <= 20 is asserted by the generator. Fixed
  # width keeps shard ids sorting lexically the way they sort numerically.
  def shard_label: if . < 10 then "0" + tostring else tostring end;

  {
    name: "mode-f-drain",
    description: (
      "Drains \($k) independent shards concurrently: one `parallel` over \($k) "
      + "self-draining `repeat` branches, each branch one `step`. Each branch "
      + "owns exactly one shard state file under \($state_root)/ and terminates "
      + "on that file alone, so the branches share no state and no branch can "
      + "observe another. Generated by generate.sh — edit K there, not here."
    ),
    inputs: {
      goal: "prompt"
    },
    steps: [
      {
        type: "parallel",
        id: "drain",
        joinPolicy: "allSettled",
        branches: [
          range(1; $k + 1)
          | (. | shard_label) as $label
          | ("\($state_root)/shard-\($label).json") as $shard
          | {
              type: "repeat",
              id: "shard-\($label)",
              steps: [
                {
                  type: "step",
                  id: "shard-\($label)-item",
                  agent: $agent,
                  modelId: $model,
                  effortLevel: $effort,
                  prompt: (
                    "Goal: {{goal}}\n\n"
                    + "You are draining shard \($label) of \($k). Your shard state file is "
                    + "\($shard), a JSON object of the form "
                    + "{\"items\": [{\"id\": \"...\", \"done\": false}], \"drained\": false}.\n\n"
                    + "If it does not exist, create it: decompose your share of the goal into "
                    + "items, each with \"done\": false, and set top-level \"drained\": false.\n\n"
                    + "If it does exist, take the FIRST item whose \"done\" is false, complete "
                    + "just that one item, then write the file back with that item marked "
                    + "\"done\": true. Set top-level \"drained\": true only when no item with "
                    + "\"done\": false remains.\n\n"
                    + "Write NOTHING outside \($shard). The other \($k - 1) branches are "
                    + "draining their own shard files concurrently and a write into another "
                    + "shard corrupts a sibling mid-run."
                  )
                }
              ],
              maxIterations: $iters,
              onMaxIterations: "abort",
              stopCondition: {
                fileCheck: {
                  path: $shard,
                  jsonPath: "drained",
                  value: true
                }
              }
            }
        ]
      }
    ]
  }'

# --- coverage --------------------------------------------------------------
#
# Not a runnable fixture. It exists so the validator's per-node-type rules have
# something to be exercised against: all five node types, both stop forms, the
# `stopWhen` watch-terminal reference, and every optional field the union
# accepts. self-test-validate.sh mutates this file to produce the
# missing-required-field negatives for `sequence` and `watch`, which the drain
# cannot supply because it contains neither.

emit coverage -n \
  --arg agent "$WORKFLOW_AGENT" '
  {
    name: "mode-f-contract-coverage",
    description: (
      "VALIDATOR FIXTURE — DO NOT RUN. Exercises all five node types, both stop "
      + "forms and every optional field, so that contract.jq is checked against "
      + "a definition using its whole surface rather than only the shapes the "
      + "drain happens to use. It holds a `watch` node that would poll an "
      + "external system, and an `onMaxIterations: \"continue\"` deliberately "
      + "chosen to keep the warning channel non-empty — see self-test-validate.sh, "
      + "which asserts this file passes plain validation and FAILS --strict."
    ),
    inputs: {
      goal: "prompt"
    },
    modelId: "auto",
    effortLevel: "high",
    steps: [
      {
        type: "sequence",
        id: "cov-seq",
        steps: [
          {
            type: "step",
            id: "cov-step",
            agent: $agent,
            prompt: "Coverage step. Goal: {{goal}}. Reply COV-DONE.",
            artifacts: {notes: "notes.md"},
            captureOutput: true,
            completion: {containsText: "COV-DONE"},
            modelId: "auto",
            effortLevel: "high"
          },
          {
            type: "watch",
            id: "cov-watch",
            handler: "github-pr",
            config: {},
            idleTimeoutSec: 30
          },
          {
            type: "repeat",
            id: "cov-repeat",
            steps: [
              {
                type: "step",
                id: "cov-repeat-step",
                agent: $agent,
                input: "Coverage step driven by `input` rather than `prompt`."
              }
            ],
            maxIterations: 3,
            onMaxIterations: "abort",
            stopWhen: "cov-watch.terminal"
          },
          {
            type: "parallel",
            id: "cov-par",
            joinPolicy: "allSettled",
            branches: [
              {
                type: "step",
                id: "cov-par-a",
                agent: $agent,
                prompt: "Coverage branch a.",
                captureOutput: false
              },
              {
                type: "repeat",
                id: "cov-par-b",
                steps: [
                  {
                    type: "step",
                    id: "cov-par-b-step",
                    agent: $agent,
                    prompt: "Coverage branch b."
                  }
                ],
                maxIterations: 2,
                onMaxIterations: "continue",
                stopCondition: {
                  fileCheck: {
                    path: ".kiro-harness/cov/b.json",
                    jsonPath: "done",
                    value: true
                  }
                }
              }
            ]
          }
        ]
      }
    ]
  }'
