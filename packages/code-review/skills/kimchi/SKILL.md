---
name: code-review
description:
  Review a change or merge request with native Kimchi workers. Prepare actual
  inputs and return the copyable workflow command for a local evidence report.
---

# Code review

GitLab CLI: `@glab@`.

Resources: `@resources@`. Profile: `@kimchi-profile@`. Python: `@python@`.
Review workflow: `@workflow@`. Pull workflow: `@pull-workflow@`. Push workflow:
`@push-workflow@`.

Read `@resources@/LAUNCH.md` for target resolution and frozen input. The
installed profile supplies model/effort pins and limits; do not interview for
them.

1. For an MR needing acquisition, write an actual pull request described in
   `@resources@/transport/API.md`. Return
   `/workflow run @pull-workflow@ --input {"request_file":"/ACTUAL/PULL.json"}`,
   replacing the path with the file you wrote. Use configured glab/MCP; never
   inspect credentials. After pull, verify its frozen receipt through
   `@python@ @resources@/transport/local.py verify-freeze --frozen-dir ACTUAL_DIR`.
2. With prepared input, choose a fresh run directory and arm. Write an absolute
   request JSON with actual `arm`, `bundle`, `pass` (default 1), `profile` (the
   installed profile FILE PATH), `run_dir`, and `steering_file` when frozen
   intake is nonempty. Read the profile; its defaults are six lanes and three
   waves. Keep state outside the pinned checkout.
3. Return `/workflow run @workflow@ --input @/ACTUAL/REQUEST.json` with the real
   request path. Kimchi has no model-callable workflow launcher. Printing the
   command does not execute it; never substitute a main-session review.
4. After execution, inspect `status` and `report` using
   `@python@ @resources@/shared/review.py COMMAND --run-dir ACTUAL_RUN_DIR --arm ACTUAL_ARM`.
   Return the local report paths and complete/incomplete status with unresolved
   work. Preserve receipts on failure. Recover explicitly using the same
   request; the shared correction budget remains authoritative.

Review never authorizes posting. Only a separate explicit publication request
may use the push workflow, with the selected report and target bound by
`transport/API.md`. Preserve the report's bot attribution and evidence chain.
