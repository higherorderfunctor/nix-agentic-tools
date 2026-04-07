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

### Task 2: Devenv parity — extension module + ecosystem walker (Option A)

**Architectural principle:** `ai.*` is fanout-only; never
contains implementation logic. Missing functionality in upstream
(devenv `claude.code` lacking a `skills` option) lives in an
extension module that mirrors how `modules/claude-code-buddy/`
extends HM's `programs.claude-code` with the `buddy` option.
When the upstream option ships, the extension module either
delegates through it or gets dropped entirely.

For Claude (devenv): create a NEW extension module that adds
`claude.code.skills` option to devenv. For Copilot/Kiro
(devenv): the `cfg.skills` options already exist on our own
modules (`modules/devenv/copilot.nix:77`,
`modules/devenv/kiro.nix:106`); just swap their internal
implementations from single-source writes to the walker.

After this task, all three devenv ecosystem modules have a
`<cli>.skills` option and `modules/devenv/ai.nix` becomes pure
fanout — three structurally identical lines.

**Files:**

- Modify: `lib/hm-helpers.nix` (add `mkDevenvSkillEntries`)
- Create: `modules/devenv/claude-code-skills/default.nix`
  (NEW extension module — adds `claude.code.skills` option to
  devenv, mirrors `modules/claude-code-buddy/` for HM)
- Modify: `modules/devenv/copilot.nix` (swap implementation to
  walker)
- Modify: `modules/devenv/kiro.nix` (swap implementation to
  walker)
- Modify: `modules/devenv/ai.nix` (replace per-branch files.\*
  writes with delegation through `<cli>.skills` options)
- Modify: `flake.nix` (register new extension module under
  `devenvModules.claude-code-skills`)
- Modify: `checks/devshell-eval.nix` (add layout-assertion check)
- Modify: `dev/fragments/devenv/files-internals.md` (update Last
  verified marker, document the extension module pattern)
- Modify: `dev/fragments/ai-skills/skills-fanout-pattern.md`
  (update the table to show devenv branches delegate the same
  way as HM branches now)

**Steps:**

- [ ] **Step 1: Confirm pre-investigation findings before
      starting.** Two questions were resolved during 2026-04-07
      grooming and don't need to be re-investigated; just verify
      the current code still matches the findings:

  **(a) Copilot configDir divergence is intentional.** Per
  [GitHub Docs — Creating agent skills for Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-skills),
  Copilot CLI reads from BOTH locations:
  - `~/.copilot/skills/` for personal/global skills (HM scope —
    `modules/copilot-cli/default.nix` defaults `configDir = ".copilot"`)
  - `.github/skills/` for project-local skills (devenv scope —
    `modules/devenv/copilot.nix` hardcodes `.github/skills/`)

  Both are correct, no fix needed. Just don't accidentally
  collapse them in the walker.

  **(b) devenv `claude.code` has NO `skills` option yet.** Per
  [cachix/devenv#2441](https://github.com/cachix/devenv/issues/2441),
  it's an active feature request. devenv has
  `claude.code.{commands,agents,mcpServers,hooks}` but no
  `skills`. This is why Task 2 uses `files.*` directly instead
  of delegating through `claude.code.skills` like Task 1
  delegates through `programs.claude-code.skills`. The walker
  produces Layout B output via devenv's native `files.*`
  mechanism — matching the on-disk shape that HM produces but
  using devenv's idioms.

  When devenv#2441 lands upstream and `claude.code.skills`
  becomes available, switch the devenv Claude branch to
  delegate through it (matches HM pattern exactly, removes the
  walker for the claude branch only). See backlog item
  "Switch devenv claude branch to claude.code.skills delegation
  when upstream lands" in `docs/plan.md`.

- [ ] **Step 2: Add `mkDevenvSkillEntries` walker to
      `lib/hm-helpers.nix`.** This is the SHARED implementation
      that all three devenv ecosystem modules will call from
      their config blocks. The walker stays in lib/ — not in any
      individual ecosystem module — because it's a generic
      utility.

  Append to `lib/hm-helpers.nix`:

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

  Format and commit the helper alone:

  ```bash
  treefmt lib/hm-helpers.nix
  git add lib/hm-helpers.nix
  git commit -m "$(cat <<'EOF'
  feat(lib): add mkDevenvSkillEntries walker for devenv files.* parity

  Generic helper that walks a source directory at eval time with
  builtins.readDir and emits devenv-compatible files.<path>.source
  entries — one per leaf file. Matches the on-disk layout HM
  produces via recursive = true, but does it through devenv's
  native files.* mechanism in user space (devenv's files option
  has no recursive walk of its own).

  Used by the next several commits to back ecosystem-specific
  skills options on the devenv side (claude-code-skills extension
  module + copilot/kiro module config blocks). Lives in lib/ not
  in any individual ecosystem module because it's a generic
  utility.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 3: Create `modules/devenv/claude-code-skills/default.nix`
      extension module.** This adds a `claude.code.skills` option
      to devenv, mirroring how `modules/claude-code-buddy/`
      extends HM's `programs.claude-code` with `buddy`. The
      implementation uses `mkDevenvSkillEntries`.

  Sketch (verify against current devenv claude.code option
  structure before finalizing):

  ```nix
  # claude.code.skills — devenv extension that adds a `skills`
  # option to upstream devenv's claude.code module. Mirrors how
  # modules/claude-code-buddy/ extends HM's programs.claude-code
  # with `buddy`. The upstream devenv claude.code module
  # (cachix/devenv src/modules/integrations/claude.nix) does not
  # yet expose a skills option — see cachix/devenv#2441. When
  # that lands, this whole module gets dropped (or refactored to
  # delegate through the upstream option).
  {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (lib) mkOption types;
    inherit (import ../../../lib/hm-helpers.nix {inherit lib;}) mkDevenvSkillEntries;
    cfg = config.claude.code.skills or {};
  in {
    options.claude.code.skills = mkOption {
      type = types.attrsOf types.path;
      default = {};
      description = ''
        Skill directories to expose as ~/.claude/skills/<name>/
        (project-local: .claude/skills/<name>/). Each value is a
        path to a skill directory containing SKILL.md and
        supporting files. The directory tree is walked at
        evaluation time and per-file symlinks are written via
        devenv files.* entries (Layout B parity with HM).
      '';
      example = lib.literalExpression ''
        {
          stack-fix = ./skills/stack-fix;
          stack-plan = ./skills/stack-plan;
        }
      '';
    };

    config = lib.mkIf (cfg != {}) {
      files = mkDevenvSkillEntries ".claude" cfg;
    };
  }
  ```

  Format and commit:

  ```bash
  treefmt modules/devenv/claude-code-skills/default.nix
  git add modules/devenv/claude-code-skills/default.nix
  git commit -m "$(cat <<'EOF'
  feat(devenv): add claude.code.skills extension module

  Upstream devenv claude.code (cachix/devenv) does not yet expose
  a skills option — tracked at cachix/devenv#2441. Add an
  extension module that declares claude.code.skills, mirroring
  how modules/claude-code-buddy/ extends HM's
  programs.claude-code with the buddy option. Implementation
  uses the mkDevenvSkillEntries walker added in the previous
  commit.

  When upstream devenv ships claude.code.skills, this module
  becomes vestigial — delete it and have ai.nix delegate
  directly through the upstream option. See plan.md backlog
  item.

  Note: this extension module is NOT yet imported by anything.
  The next commit registers it in flake.nix devenvModules and
  the ai.nix Claude branch starts delegating through it.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 4: Register the new extension module in `flake.nix`.**
      Add to `devenvModules` attrset alongside the existing
      modules. Consumers using `devenvModules.default` get it
      automatically; consumers using surgical imports add it
      manually.

  ```bash
  treefmt flake.nix
  git add flake.nix
  git commit -m "$(cat <<'EOF'
  build(flake): register devenvModules.claude-code-skills

  Wires the devenv claude.code.skills extension module into the
  flake's devenvModules attrset so consumers can import it.
  Required before the ai.nix Claude branch can delegate through
  claude.code.skills (next commit).

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 5: Refactor `modules/devenv/copilot.nix` to use the
      walker internally.** The `cfg.skills` option already exists
      (line 77); just swap the implementation in the config
      block. Replace the
      `lib.concatMapAttrs (name: path: { ".github/skills/${name}".source = path; }) cfg.skills`
      block with:

  ```nix
  // hmHelpers.mkDevenvSkillEntries ".github" cfg.skills
  ```

  (Make sure `hmHelpers` is in scope; if not, add the import to
  the let block.)

  Format and commit:

  ```bash
  treefmt modules/devenv/copilot.nix
  git add modules/devenv/copilot.nix
  git commit -m "$(cat <<'EOF'
  refactor(devenv): copilot.skills uses walker for Layout B parity

  Swap copilot.skills internal implementation from single
  files.<path>.source writes (Layout A — single dir symlink) to
  mkDevenvSkillEntries walker (Layout B — per-file symlinks
  inside a real dir). Matches HM programs.copilot-cli.skills
  on-disk shape.

  No interface change for consumers — copilot.skills option
  signature is unchanged. Only the internal expansion differs.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 6: Refactor `modules/devenv/kiro.nix` to use the
      walker internally.** Same shape as Step 5 but for Kiro.
      Replace the
      `lib.concatMapAttrs (name: path: { ".kiro/skills/${name}".source = path; }) cfg.skills`
      block with:

  ```nix
  // hmHelpers.mkDevenvSkillEntries ".kiro" cfg.skills
  ```

  Format and commit:

  ```bash
  treefmt modules/devenv/kiro.nix
  git add modules/devenv/kiro.nix
  git commit -m "$(cat <<'EOF'
  refactor(devenv): kiro.skills uses walker for Layout B parity

  Swap kiro.skills internal implementation from single
  files.<path>.source writes (Layout A) to mkDevenvSkillEntries
  walker (Layout B). Matches HM programs.kiro-cli.skills on-disk
  shape.

  No interface change for consumers.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 7: Refactor `modules/devenv/ai.nix` to delegate
      through ecosystem options.** This is the architectural
      cleanup that makes ai.\* pure fanout. Each branch becomes a
      one-line delegation.

  Find the existing per-branch `files = ... // concatMapAttrs ...`
  blocks for skills and replace with:

  ```nix
  # Claude branch (currently hardcoded files.* writes for skills):
  (mkIf cfg.claude.enable {
    claude.code.enable = mkDefault true;
    claude.code.skills = lib.mapAttrs (_: mkDefault) cfg.skills;
    # ... instructions stay as before
  })

  # Copilot branch:
  (mkIf cfg.copilot.enable {
    copilot.enable = mkDefault true;
    copilot.skills = lib.mapAttrs (_: mkDefault) cfg.skills;
    # ... rest of copilot fanout
  })

  # Kiro branch:
  (mkIf cfg.kiro.enable {
    kiro.enable = mkDefault true;
    kiro.skills = lib.mapAttrs (_: mkDefault) cfg.skills;
    # ... rest of kiro fanout
  })
  ```

  All three skills lines should be structurally identical
  (delegating through the ecosystem option, mkDefault wrapped).
  ai.nix no longer touches `files.*` for skills. Implementation
  lives entirely in the ecosystem modules.

  This requires the claude-code-skills extension module to be
  imported (Step 4 registered it; consumers need to import it
  via `devenvModules.default` or surgical imports).

  Format and commit:

  ```bash
  treefmt modules/devenv/ai.nix
  git add modules/devenv/ai.nix
  git commit -m "$(cat <<'EOF'
  refactor(devenv): ai.skills branches delegate through ecosystem options

  ai.* should be pure fanout. Implementation logic belongs in
  ecosystem modules. This commit moves the devenv ai.skills
  branches from direct files.* writes to delegation through:

  - claude.code.skills (provided by the new claude-code-skills
    extension module added two commits ago)
  - copilot.skills (existing option, internal walker landed in
    the previous commit)
  - kiro.skills (existing option, same)

  All three ai.skills branches now look structurally identical:
  mkIf cfg.<cli>.enable + <cli>.skills = lib.mapAttrs mkDefault.
  Mirrors the HM ai.nix shape exactly. ai.* is pure fanout on
  both HM and devenv.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

- [ ] **Step 8: Add devshell eval check** in
      `checks/devshell-eval.nix`. Test that evaluating a devenv
      module with `ai.skills = { sample = /tmp/sample-skill-dir; }`
      produces per-file entries like
      `files.".claude/skills/sample/SKILL.md".source` instead of
      a single `.claude/skills/sample` entry.

- [ ] **Step 9: Run the devshell eval check + flake check.**

  ```bash
  nix build .#checks.x86_64-linux.devenv-skills-layout-eval
  nix flake check
  devenv test
  ```

  Expected: all checks pass.

  Format and commit:

  ```bash
  treefmt checks/devshell-eval.nix
  git add checks/devshell-eval.nix
  git commit -m "$(cat <<'EOF'
  test(devenv): add devshell-skills-layout eval check

  Verifies the devenv ai.skills fanout produces per-file Layout B
  entries (".claude/skills/<name>/SKILL.md".source) rather than
  single dir symlinks (".claude/skills/<name>".source). Catches
  any regression that re-introduces direct files.* writes in
  ai.nix or any ecosystem module.

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

~9 commits in this session, atomic per concern:

1. `refactor(ai): route ai.skills through programs.claude-code.skills`
   (Task 1 — HM side fix)
2. `feat(lib): add mkDevenvSkillEntries walker for devenv files.* parity`
   (Task 2 Step 2 — generic helper)
3. `feat(devenv): add claude.code.skills extension module`
   (Task 2 Step 3 — new extension module, mirrors buddy pattern)
4. `build(flake): register devenvModules.claude-code-skills`
   (Task 2 Step 4 — wire new module into the flake)
5. `refactor(devenv): copilot.skills uses walker for Layout B parity`
   (Task 2 Step 5 — internal implementation swap)
6. `refactor(devenv): kiro.skills uses walker for Layout B parity`
   (Task 2 Step 6 — same)
7. `refactor(devenv): ai.skills branches delegate through ecosystem options`
   (Task 2 Step 7 — the architectural cleanup, ai.\* becomes pure fanout)
8. `test(devenv): add devshell-skills-layout eval check`
   (Task 2 Step 8 — regression protection)
9. `docs(fragments): update Last verified markers post skills fanout fix`
   (Task 4 — fragment hygiene)

Optional 10th commit if Task 3 reveals migration issues:
`docs: note skills layout migration one-time backup`.

If anything breaks during Tasks 5-7, fix on tip with new commits
rather than amending. Sentinel workflow is additive only.

The atomic split lets you bisect cleanly. Each commit is small
(~30-150 lines) and stands alone (flake check passes after each).

## After this session

Once skills fanout uniformity lands, the next plan can pick up:

- **Tasks 3-7** of the `ai.claude.*` full passthrough (separate
  plan, draft when ready)
- **Always-loaded content audit fix** (independent TOP item)
- **nixos-config AI config migration to `ai.*`** (after full
  passthrough lands)
