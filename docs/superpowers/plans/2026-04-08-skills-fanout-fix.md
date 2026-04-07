# Skills Fanout Fix Plan (2026-04-08)

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan
> task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route Claude's `ai.skills` fanout through
`programs.claude-code.skills` (matching the Copilot/Kiro pattern),
and bring the devenv ai module to skills layout parity with HM
via a user-space directory walker. Both halves of the
skills-layout-uniformity fix in one session.

**Why now:** This is the single biggest unblock in the TOP
priority tier. It blocks:

- Tasks 3-7 of the `ai.claude.*` full passthrough work (memory,
  settings, mcpServers, skills, plugins)
- Task D (devenv ai module mirror of the passthrough)
- nixos-config full migration to `ai.*`

The fix itself is small (~3-5 commits) and lands a real consumer
clobber bug from 2026-04-06.

**Tech Stack:** Nix module system, home-manager, devenv,
`builtins.readDir` (eval-time directory walk),
`evalModules`-based checks.

---

## Required reading (in order)

Before starting any task, read these to understand the
constraints and design rationale:

1. **`memory/project_ai_claude_passthrough.md`** — condensed
   plan extracted from the deleted superpowers plan. Contains
   Tasks 2, 2b, the option analysis (A/B/C for devenv parity),
   and the touch points.
2. **`memory/project_ai_skills_layout.md`** — original design
   decision: all three branches must delegate through
   `programs.<cli>.skills`. The 2026-04-06 consumer clobber bug
   story.
3. **`memory/project_devenv_files_internals.md`** — full devenv
   `files.*` constraints (no recursive walk, silent-fail on
   dir-vs-symlink conflict, the `mkDevenvSkillEntries` walker
   approach).
4. **`dev/fragments/ai-skills/skills-fanout-pattern.md`** —
   in-tree fragment summarizing the uniform delegation pattern.
   Loaded automatically when editing `modules/ai/**` or
   `lib/hm-helpers.nix`.
5. **`dev/fragments/devenv/files-internals.md`** — in-tree
   fragment summarizing devenv constraints. Loaded automatically
   when editing `modules/devenv/**` or `lib/hm-helpers.nix`.
6. **`docs/plan.md`** — current TOP priority backlog. Verify
   the "ai.claude.\* full passthrough" section to make sure no
   newer related items have landed.

---

## Decision required before execution

**Task 2b (devenv parity) has three options.** Option A is
recommended in the memory but the user has not formally chosen.
Confirm before starting Task 2:

- **Option A — `mkDevenvSkillEntries` eval-time walker
  (RECOMMENDED, used by this plan)**. Add a helper to
  `lib/hm-helpers.nix` that recursively walks a source directory
  with `builtins.readDir` and emits per-leaf-file
  `files."<prefix>/<relpath>".source = <file>;` entries. All
  three devenv modules swap their single-`.source` assignments
  for the helper. Ships today, no upstream dep, matches HM Layout
  B output exactly.

- **Option B — Accept the HM/devenv split, document the
  divergence.** No code changes. Add a doc note that mixing HM
  and devenv on the same `.claude/skills/<name>` path causes
  silent failures. Contradicts the "config parity is mandatory"
  rule in CLAUDE.md.

- **Option C — Upstream PR to `cachix/devenv`** adding a
  `recursive` field to `fileType` in `src/modules/files.nix`.
  Correct long-term but doesn't unblock today.

**This plan assumes Option A.** If the user picks B or C, stop
after Task 1 and re-plan.

---

## Tasks

### Task 1: HM Claude `ai.skills` fanout fix

Route the Claude branch through `programs.claude-code.skills`
instead of writing `home.file` directly. Aligns with the existing
Copilot and Kiro patterns.

**Files:**

- Modify: `modules/ai/default.nix` (Claude `mkIf` block)
- Modify: `checks/module-eval.nix` (add `aiSkillsFanout` test)
- Modify: `dev/fragments/ai-skills/skills-fanout-pattern.md`
  (update Last verified marker after the fix lands)

**Steps:**

- [ ] **Step 1: Write the failing eval check.** Add to
      `checks/module-eval.nix`:

  ```nix
  # Test: ai.skills fans out via programs.claude-code.skills
  # (not home.file directly)
  aiSkillsFanout = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai = {
          claude.enable = true;
          skills.stack-fix = /tmp/test-skill;
        };
      };
    }
  ];
  ```

  And in the output attrset:

  ```nix
  ai-skills-fanout-eval = pkgs.runCommand "ai-skills-fanout-eval" {} ''
    if [ "${
      if aiSkillsFanout.config.programs.claude-code.skills ? stack-fix
      then "yes"
      else "no"
    }" != "yes" ]; then
      echo "FAIL: ai.skills not routed via programs.claude-code.skills"
      exit 1
    fi
    echo "ok" > $out
  '';
  ```

- [ ] **Step 2: Verify the check fails against current code.**

  ```bash
  nix build .#checks.x86_64-linux.ai-skills-fanout-eval 2>&1 | tail -10
  ```

  Expected: build fails with the FAIL message — the new check
  detects today's `home.file`-direct behavior and rejects it.

- [ ] **Step 3: Rewrite the Claude skills fanout in
      `modules/ai/default.nix`.** Find the
      `(mkIf cfg.claude.enable (mkMerge [{ ... home.file = ... }]))`
      block. Replace the `home.file."//.claude/skills/${name}"`
      concatMapAttrs lines with:

  ```nix
  programs.claude-code.skills = lib.mapAttrs (_: mkDefault) cfg.skills;
  ```

  The instructions concatMapAttrs (writing
  `.claude/rules/${name}.md`) STAYS — only the skills part moves
  to the upstream option. Confirm the result by re-reading the
  Copilot and Kiro branches; all three branches should look
  structurally identical for the skills fanout line.

- [ ] **Step 4: Run the check and verify pass.**

  ```bash
  nix build .#checks.x86_64-linux.ai-skills-fanout-eval
  ```

  Expected: builds successfully. Output file contains `ok`.

- [ ] **Step 5: Run full flake check.**

  ```bash
  nix flake check
  ```

  Expected: all checks pass. No regressions in `ai-eval`,
  `ai-with-clis-eval`, `ai-buddy-eval`, `ai-with-settings-eval`.

- [ ] **Step 6: Update the architecture fragment's Last verified
      marker.** Edit
      `dev/fragments/ai-skills/skills-fanout-pattern.md` and
      change the Last verified line to today's date and the
      forthcoming commit hash placeholder. The actual hash gets
      filled in after commit but before push (or in a follow-up
      amend — skip if it's awkward in the sentinel workflow).

- [ ] **Step 7: Format and commit.**

  ```bash
  treefmt modules/ai/default.nix checks/module-eval.nix \
    dev/fragments/ai-skills/skills-fanout-pattern.md
  git add modules/ai/default.nix checks/module-eval.nix \
    dev/fragments/ai-skills/skills-fanout-pattern.md
  git commit -m "$(cat <<'EOF'
  refactor(ai): route ai.skills through programs.claude-code.skills

  ai.skills was writing home.file.".claude/skills/<name>" directly,
  bypassing programs.claude-code.skills and making per-Claude
  ai.claude.skills (future passthrough work) impossible without a
  home.file collision. Route the Claude fanout through the upstream
  option so there's one source of truth for .claude/skills/*.

  Aligns Claude branch with Copilot and Kiro branches — all three
  now delegate through programs.<cli>.skills uniformly.

  Consumer transition: any consumer who migrated a skill from
  programs.claude-code.skills to ai.skills while the old direct-
  home.file code was live will hit "Existing file would be
  clobbered" on first activation after this. Run
  `home-manager switch -b backup` once; subsequent activations
  succeed cleanly.

  Adds aiSkillsFanout module-eval check to prevent regression.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

### Task 2: Devenv parity — `mkDevenvSkillEntries` walker (Option A)

Add a user-space directory walker to `lib/hm-helpers.nix` that
emits per-leaf-file devenv `files` entries, achieving Layout B
parity with HM. Apply to all three devenv ecosystem modules.

**Files:**

- Modify: `lib/hm-helpers.nix` (add `mkDevenvSkillEntries`)
- Modify: `modules/devenv/ai.nix` (Claude branch skills fanout)
- Modify: `modules/devenv/copilot.nix`
- Modify: `modules/devenv/kiro.nix`
- Modify: `checks/devshell-eval.nix` (add layout-assertion check)
- Modify: `dev/fragments/devenv/files-internals.md` (update Last
  verified marker)

**Steps:**

- [ ] **Step 1: Verify Copilot configDir before starting.** The
      current devenv copilot module uses `.github/skills/`.
      Double-check against the upstream HM Copilot module + the
      Copilot CLI docs:

  ```bash
  grep -n "skills" modules/copilot-cli/default.nix
  grep -n "skills" modules/devenv/copilot.nix
  ```

  Confirm both use the same prefix. If they diverge, that's a
  pre-existing bug — fix it in the same commit as Task 2 or
  flag it as a separate task (do not silently propagate the
  divergence into the new walker).

- [ ] **Step 2: Add `mkDevenvSkillEntries` to
      `lib/hm-helpers.nix`.** Append:

  ```nix
  # Recursively enumerate a skill source directory at eval time
  # and emit devenv-compatible
  # `files."<prefix>/<relpath>".source = <file>;` entries for
  # every leaf file. Mirrors HM `recursive = true` in user space
  # because devenv's `files.<name>.source = path` option only
  # creates a single dir symlink (Layout A) and has no recursive
  # walk of its own.
  #
  # Usage: `mkDevenvSkillEntries ".claude" { skillName = ./path/to/skill; }`
  # returns: { ".claude/skills/skillName/SKILL.md".source = ...; ... }
  mkDevenvSkillEntries = configDir: attrs: let
    walkDir = prefix: dir: let
      entries = builtins.readDir dir;
    in
      lib.concatMapAttrs (
        name: kind:
          if kind == "directory"
          then walkDir "${prefix}/${name}" "${dir}/${name}"
          else if kind == "regular" || kind == "symlink"
          then {"${prefix}/${name}".source = "${dir}/${name}";}
          else {} # skip unknown entries
      )
      entries;
  in
    lib.concatMapAttrs (
      skillName: skillPath:
        if lib.isPath skillPath && lib.pathIsDirectory skillPath
        then walkDir "${configDir}/skills/${skillName}" skillPath
        else {"${configDir}/skills/${skillName}/SKILL.md".source = skillPath;}
    )
    attrs;
  ```

- [ ] **Step 3: Write the failing devshell eval check** in
      `checks/devshell-eval.nix`. Test that evaluating a devenv
      module with `ai.skills = { sample = /tmp/sample-skill-dir; }`
      produces per-file entries like
      `files.".claude/skills/sample/SKILL.md".source` instead of
      a single `.claude/skills/sample` entry.

- [ ] **Step 4: Update `modules/devenv/ai.nix` Claude branch.**
      Replace the existing
      `concatMapAttrs (name: path: { ".claude/skills/${name}".source = mkDefault path; })`
      block with the walker. Note that `mkDefault` needs to wrap
      the `source` attribute of each generated entry, not the
      entry itself, so the helper returns plain attrsets and the
      caller re-wraps:

  ```nix
  // lib.mapAttrs
    (_: entry: entry // {source = mkDefault entry.source;})
    (hmHelpers.mkDevenvSkillEntries ".claude" cfg.skills);
  ```

- [ ] **Step 5: Update `modules/devenv/copilot.nix`** with the
      same pattern, using the configDir verified in Step 1:

  ```nix
  // hmHelpers.mkDevenvSkillEntries ".github" cfg.skills;
  ```

- [ ] **Step 6: Update `modules/devenv/kiro.nix`** with the same
      pattern:

  ```nix
  // hmHelpers.mkDevenvSkillEntries ".kiro" cfg.skills
  ```

- [ ] **Step 7: Run the devshell eval check + flake check.**

  ```bash
  nix build .#checks.x86_64-linux.devenv-skills-layout-eval
  nix flake check
  ```

  Expected: previously-failing check passes. No regressions in
  existing devshell checks.

- [ ] **Step 8: Update the architecture fragment's Last verified
      marker** in `dev/fragments/devenv/files-internals.md`.

- [ ] **Step 9: Format and commit.**

  ```bash
  treefmt lib/hm-helpers.nix modules/devenv/ai.nix \
    modules/devenv/copilot.nix modules/devenv/kiro.nix \
    checks/devshell-eval.nix \
    dev/fragments/devenv/files-internals.md
  git add lib/hm-helpers.nix modules/devenv/ai.nix \
    modules/devenv/copilot.nix modules/devenv/kiro.nix \
    checks/devshell-eval.nix \
    dev/fragments/devenv/files-internals.md
  git commit -m "$(cat <<'EOF'
  refactor(devenv): align skills fanout to HM Layout B

  devenv's files option only creates single dir symlinks (Layout A)
  while HM's programs.<cli>.skills uses recursive = true (Layout B).
  Add mkDevenvSkillEntries helper that walks the source dir at
  eval time with builtins.readDir and emits per-file
  files.<path>.source entries, matching HM output.

  Closes the config parity gap between HM and devenv skills fanout
  for all three ecosystems (Claude, Copilot, Kiro).

  Adds devenv-skills-layout-eval check to prevent regression.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

### Task 3: Verify against the consumer (nixos-config)

End-to-end verification on a real consumer with the migrated
skills. This catches anything the eval-only checks miss.

**Files:** none modified in this repo. The verification is run
against the user's nixos-config consumer.

**Steps:**

- [ ] **Step 1: Update nixos-config flake input.**

  ```bash
  cd ~/Documents/projects/nixos-config
  nix flake update nix-agentic-tools
  git diff flake.lock | grep nix-agentic-tools
  ```

  Confirm the input bumped to the tip of `sentinel/monorepo-plan`
  containing both Task 1 and Task 2 commits.

- [ ] **Step 2: Run `home-manager switch`.**

  ```bash
  home-manager switch
  ```

  Expected outcomes:
  - **Best case (no migration history)**: clean activation, no
    errors, exit 0.
  - **Migration case**: error like
    `Existing file '/home/.../.claude/skills/<name>' would be clobbered by /nix/store/...`.
    This is the documented one-time transition error. Remedy:

    ```bash
    home-manager switch -b backup
    ```

    The `-b backup` flag moves the conflicting path aside.
    Subsequent activations succeed cleanly.

- [ ] **Step 3: Verify on-disk Layout B.**

  ```bash
  ls -la ~/.claude/skills/
  ls -la ~/.claude/skills/<some-skill>/
  ```

  Expected: `~/.claude/skills/<name>/` is a real directory (not
  a symlink), containing per-file symlinks into `/nix/store/...`.

- [ ] **Step 4: Test claude actually finds the skills.** Launch
      claude in any project, run `/help` or invoke a skill by
      name. Confirm it loads as expected.

- [ ] **Step 5: If migration error happened, document it in
      the commit chain.** Either: amend the Task 1 commit message
      to mention the actual command the user ran (`-b backup`),
      OR add a third commit `docs: note skills layout migration
    one-time backup` documenting the transition for other
      consumers.

### Task 4: Tidy fragment Last-verified markers

Backlog item from the Checkpoint 8 review: include commit subject
in Last-verified markers. Apply to the two fragments touched in
Tasks 1 and 2 only — full sweep of all 9 fragments is a separate
backlog item.

**Files:**

- Modify: `dev/fragments/ai-skills/skills-fanout-pattern.md`
- Modify: `dev/fragments/devenv/files-internals.md`

**Steps:**

- [ ] **Step 1: Get the actual commit hashes** from Tasks 1 and
      2:

  ```bash
  git log --oneline -5
  ```

  Note the hash + subject for each.

- [ ] **Step 2: Update the Last-verified markers** in both
      fragments. Format:

  ```markdown
  > **Last verified:** 2026-04-08 (commit <hash> — <subject>).
  ```

- [ ] **Step 3: Format, commit, and push.**

  ```bash
  treefmt dev/fragments/ai-skills/skills-fanout-pattern.md \
    dev/fragments/devenv/files-internals.md
  git add dev/fragments/ai-skills/skills-fanout-pattern.md \
    dev/fragments/devenv/files-internals.md
  git commit -m "$(cat <<'EOF'
  docs(fragments): update Last verified markers post skills fanout fix

  Refresh the ai-skills-fanout-pattern and devenv-files-internals
  fragment Last-verified lines to point at the commits that
  implemented the patterns they describe (Tasks 1 and 2 of the
  skills fanout fix plan, 2026-04-08).

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  git push origin sentinel/monorepo-plan
  ```

---

## Out of scope (do NOT do in this session)

- **Tasks 3-7 of the ai.claude.\* full passthrough** (memory,
  settings, mcpServers, skills passthrough, plugins) — separate
  plan, drafted after this one lands and the user is ready
- **Task D devenv ai module mirror of the passthrough** —
  same separate plan
- **Always-loaded content audit + dynamic loading fix** —
  separate TOP backlog item, separate plan
- **Migrating nixos-config AI config to ai.\* unified module** —
  blocked on the full passthrough work landing first
- **Bumping fragment Last verified markers across all 9
  fragments** — Task 4 only touches the two we modify here
- **Cspell allowlist additions** — handle inline as they come up
- **README.md / CONTRIBUTING.md updates** — not needed for this
  scope

---

## Verification protocol (full checklist before declaring done)

After all four tasks land:

- [ ] `nix flake check` passes
- [ ] `nix build .#checks.x86_64-linux.ai-skills-fanout-eval`
      passes
- [ ] `nix build .#checks.x86_64-linux.devenv-skills-layout-eval`
      passes (name TBD per Task 2 Step 3 implementation)
- [ ] `nix build .#docs` succeeds
- [ ] `devenv test` passes (catches devenv-side regressions the
      module-eval checks might miss)
- [ ] `home-manager switch` on nixos-config consumer succeeds
      (with `-b backup` once if migration error fires)
- [ ] `~/.claude/skills/<name>/` is a real dir with per-file
      symlinks (Layout B)
- [ ] Claude session loads and finds the skills
- [ ] Sentinel branch pushed to origin
- [ ] All 4 commits have Co-Authored-By footer

## Commit count target

4 commits in this session:

1. `refactor(ai): route ai.skills through programs.claude-code.skills`
2. `refactor(devenv): align skills fanout to HM Layout B`
3. (Optional) `docs: note skills layout migration one-time backup`
4. `docs(fragments): update Last verified markers post skills fanout fix`

If Task 3 reveals issues that require fixes in Task 1 or 2, add
follow-up commits on tip rather than amending. Sentinel workflow
is additive only.

## After this session

Once skills fanout uniformity lands, the next plan can pick up:

- **Tasks 3-7** of the `ai.claude.*` full passthrough (separate
  plan, draft when ready)
- **Always-loaded content audit fix** (independent TOP item)
- **nixos-config AI config migration to `ai.*`** (after full
  passthrough lands)
