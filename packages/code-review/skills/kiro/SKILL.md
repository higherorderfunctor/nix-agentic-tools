---
name: code-review
description:
  Review a change or merge request using native Kiro v3 workflows. Prepare
  inputs, launch the workflow and monitor to a local evidence report.
---

# Code review

GitLab CLI: `@glab@`.

Resources: `@resources@`. Profile: `@kiro-profile@`. Python: `@python@`.

Read `@resources@/LAUNCH.md` for target resolution and frozen input. The
installed profile supplies model/effort pins and limits; do not interview for
them.

1. For an MR needing acquisition, write the actual pull request described in
   `@resources@/transport/API.md`. Prepare its recipe with
   `@python@ @resources@/transport/materialize.py --phase pull --profile @kiro-profile@ --request ACTUAL_REQUEST --workspace ACTUAL_WORKSPACE`.
   Validate its complete JSON object using native `validate_workflow`, then
   launch `run_workflow` with the returned absolute `workflow` path and a unique
   `runLabel`. Wait for its verified frozen receipt. Use configured glab/MCP;
   never inspect credentials.
2. With prepared input, choose a fresh run directory outside the pinned checkout
   and beneath this launch workspace. Read `limits.max_waves` from the installed
   profile (default 3). Prepare using
   `@python@ @resources@/shared/review.py prepare --input ACTUAL_BUNDLE --run-dir ACTUAL_RUN_DIR --arm ACTUAL_ARM --runtime kiro-cli --profile @kiro-profile@ --pass ACTUAL_PASS --max-waves PROFILE_MAX_WAVES`.
   Default pass to 1. Enqueue nonempty frozen intake through the shared `intake`
   command documented in `@resources@/shared/API.md`.
3. Generate the review recipe with
   `@python@ @resources@/kiro/generate.py --workspace ACTUAL_WORKSPACE --run-dir ACTUAL_RUN_DIR --arm ACTUAL_ARM --profile @kiro-profile@`.
   Role agents are installed already; generation writes no agent definitions.
   Read the recipe from the returned `workflow` path and validate its complete
   JSON object with native `validate_workflow`. Launch native `run_workflow`,
   passing that absolute path as `workflowPath` and a unique `runLabel`.
4. Monitor through the report watch. Require the shared report's status, not
   agent success prose. Return local report paths, complete/incomplete status
   and unresolved work. Preserve failed state and receipts for explicit
   recovery; interrupted roles restart fresh with the remaining shared
   correction budget.

If native tools are absent, retain the prepared paths and name the blocker; do
not substitute a main-session review. Record coordinator effort when observed;
otherwise retain unknown provenance and proceed without an interview.

Review never authorizes posting. A separate explicit publication request may
prepare `--phase push` with the selected report and target bound by
`transport/API.md`. Preserve bot attribution and the complete evidence chain.
