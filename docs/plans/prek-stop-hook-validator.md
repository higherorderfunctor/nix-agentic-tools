# validate-at-stop: replace the racy prek PostToolUse hook with a Stop hook

> **Status update (2026-08-29):** v1 is implemented. The later validation-policy
> decision is now resolved by `config/repo-validation.nix`: cspell, deadnix,
> shellcheck, and statix stay as pre-commit and Stop feedback and also run as
> merge-blocking corpus gates. Stop requests the generated manual-stage list,
> formats the working tree without staging, and reports a persistent formatter
> failure. Embedded snippets below are the historical implementation plan, not
> the current source of truth.

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the git-hooks validation Claude Code fires from the `PostToolUse`
boundary (where a formatter rewrite desyncs the Edit tool's read-snapshot →
"modified since read" failures) to the `Stop` boundary (after the chunk's last
edit), auto-fixing formatting silently and blocking-with-reason on judgment
lint.

**Architecture:** A `Stop` hook (`validate-at-stop`) runs when Claude hands
control back. It (1) early-exits on a no-diff turn, (2) auto-applies formatting
over the working-tree changeset via the existing git-hooks `treefmt` without
mutating the index, (3) runs the judgment linters over the same changeset and,
if any fail, emits `{"decision":"block","reason":…}` so the finding reaches the
model and forces a fix pass — with a `stop_hook_active` loop-guard so a
persistent false positive can't trap the turn. Formatting no longer races
because at Stop there is no subsequent Edit to desync. The existing racy
`PostToolUse` `git-hooks-run` hook is disabled.

**Tech Stack:** Nix + devenv (`claude.code.hooks` integration), `prek`
(pre-commit reimpl, = `config.git-hooks.package`), `treefmt`, bash (strict
mode), `python3` (JSON), flake `checks/*.nix` as the test surface.

**Prior art / evidence:** Design is POC-validated end-to-end (headless
`claude -p` in a scratch repo, 2026-07-17): Stop fires at hand-back; the
`{"decision":"block","reason":…}` channel reaches the model; `stop_hook_active`
flips true on the continuation (loop guard); an 11-assertion branch suite + a
live block→fix→clean run all passed. See memory
`project_stop_hook_validation_poc`. Root-cause of the race: memory
`project_edit_tool_prek_desync` and assessment
`docs/plans/prek-posttooluse-hook-feedback-channel.md`.

## Global Constraints

- **Strict bash everywhere:** `set -euETo pipefail` +
  `shopt -s inherit_errexit 2>/dev/null || :` (project standard; the abbreviated
  `set -euo pipefail` is forbidden).
- **No bare commands in shipped wrappers:** the hook is a
  `writeShellApplication`; every external command it uses (`git`, `python3`,
  `prek`, coreutils) must come from `runtimeInputs` so it works under a stripped
  PATH (`.claude/rules/nix-standards.md`; `checks/bare-commands.nix`).
- **DRY — reuse validation policy:** invoke formatting + linters through `prek`,
  not by re-declaring tools/excludes or hook IDs; `config/repo-validation.nix`
  is the single source of truth.
- **`.claude/settings.json` is a devenv-generated, read-only store symlink.**
  Changes to `devenv.nix` hooks take effect only after a **devshell reload**,
  never in the session that edited `devenv.nix`
  (`feedback_project_settings_location`).
- **Alphabetical within groups** for any list/attrset added (project standard).
- **Validation entrypoint:** `nix flake check` is the SSOT gate; the new test is
  a `checks/*.nix` derivation (`feedback_validation_entrypoint`).
- **Do not commit working docs** unless asked; this plan file stays untracked.

---

## File Structure

- **Create `lib/validate-at-stop.sh`** — the raw Stop-hook script (strict-mode
  bash; directly unit-testable; not scanned by `bare-commands.nix`, which globs
  `*.nix` only). One responsibility: orchestrate no-diff/format/lint/block.
- **Create `lib/validate-at-stop.nix`** — `{pkgs, lib, config}:` →
  `writeShellApplication` wrapping the `.sh` with `runtimeInputs`. Ships the
  absolute-PATH artifact; its build runs shellcheck (a free lint gate).
- **Create `checks/validate-at-stop.nix`** — hermetic branch-test of the raw
  script against **stub** `prek`/`git-hooks` tools (tests orchestration logic,
  not the real linters — those are covered by git-hooks + CI). Ports the POC's
  assertions.
- **Modify `devenv.nix`** — add `validateAtStop` to the `let` block; disable the
  `git-hooks-run` PostToolUse hook; add the `validate-at-stop` Stop hook.
- **Modify `flake.nix`** — register `checks/validate-at-stop.nix` in the
  per-system `checks` set (~line 202-230).
- **Modify `docs/plans/prek-posttooluse-hook-feedback-channel.md`** — record the
  chosen direction (link to this plan).

---

## Task 1: Verify prek's per-hook `--files` behavior (spike)

The whole design assumes `prek run <hook-id> --files <paths>` runs a single hook
against **working-tree** content (not staged-only, and without a stash cycle
that would matter). Confirm before building.

**Files:** none (investigation; record findings in the commit message of Task
2).

- [ ] **Step 1: Confirm the hook-ids present in the suite**

Run:

```bash
grep -nE '^\s+(treefmt|deadnix|statix|cspell|shellcheck|gitleaks|convco|treefmt-restage)\b' devenv.nix
```

Expected: the ids
`treefmt, deadnix, statix, cspell, shellcheck, gitleaks, convco, treefmt-restage`
(from `git-hooks.hooks`, devenv.nix:118-159).

Classify:

- **auto-fix bucket:** `treefmt` (rewrites → apply silently).
- **judgment bucket:** `cspell deadnix shellcheck statix` (flag, need a
  decision).
- **excluded at Stop:** `gitleaks` (commit/CI security gate, not per-chunk),
  `convco` (commit-message only), `treefmt-restage` (re-stager, N/A).

- [ ] **Step 2: Prove `prek run <id> --files` targets working-tree content**

Run (in a scratch dir, not this repo):

```bash
d=$(mktemp -d); cd "$d"; git init -q; git config user.email a@b.c; git config user.name a
printf 'x=1\n' > s.sh; git add s.sh; git commit -qm init
printf 'x=1  \n' > s.sh          # unstaged trailing-whitespace edit, NOT staged
prek --version 2>/dev/null || echo "use: nix run <repo>#... or the git-hooks prek"
# Using the repo's prek (from devshell):
prek run treefmt --files s.sh; echo "exit=$?"
grep -nP '[ ]+$' s.sh && echo "STILL DIRTY" || echo "treefmt rewrote the UNSTAGED working-tree file"
```

Expected: `treefmt` reformats `s.sh` even though the edit is unstaged → confirms
`--files` uses working-tree content (fixes the staged-only blind spot).

- [ ] **Step 3: Confirm a single judgment hook can be run in isolation and its
      nonzero exit + output are capturable**

Run:

```bash
printf '#!/usr/bin/env bash\nls $undefined_var\n' > bad.sh
out="$(prek run shellcheck --files bad.sh 2>&1)"; echo "exit=$?"; printf '%s\n' "$out" | head
```

Expected: nonzero exit, `out` contains the shellcheck finding.

- [ ] **Step 4: Record the outcome**

If any assumption fails (e.g. `--files` stashes and mangles, or per-id run is
unsupported), STOP and fall back to invoking `treefmt` directly (auto-fix) +
`prek run --files` for the whole judgment set (parse which failed). Note the
chosen strategy for Task 2. Do NOT proceed on an unverified assumption.

---

## Task 2: The validator script + hermetic branch test

**Files:**

- Create: `lib/validate-at-stop.sh`
- Create: `lib/validate-at-stop.nix`
- Create: `checks/validate-at-stop.nix`
- Modify: `flake.nix` (register the check)

**Interfaces:**

- Produces: a `validate-at-stop` executable (via `lib/validate-at-stop.nix`,
  `writeShellApplication`, exe name `validate-at-stop`) consumed by Task 3.
- Contract: reads the Stop-hook JSON payload on **stdin** (keys used: `cwd`,
  `stop_hook_active`); on a judgment failure prints
  `{"decision":"block","reason":<string>}` to **stdout** and exits 0; on a
  persistent failure with `stop_hook_active=="True"` prints
  `{"systemMessage":<string>}` and exits 0; otherwise exits 0 silently.

- [ ] **Step 1: Write the hermetic branch test FIRST (it will fail — no script
      yet)**

Create `checks/validate-at-stop.nix`. It runs the **raw** script against
**stub** `prek`/`treefmt` on PATH so the orchestration branches are
deterministic and hermetic (no real linters in the sandbox):

```nix
# Hermetic branch-test for lib/validate-at-stop.sh. Exercises the Stop-hook
# orchestration (no-diff / auto-fix / block / loop-guard) against STUB
# git-hooks tools — the real linters are covered by git-hooks + CI, so this
# check stays fast and sandbox-safe. See docs/plans/prek-stop-hook-validator.md.
{pkgs, ...}:
pkgs.runCommandLocal "validate-at-stop-check" {
  nativeBuildInputs = [pkgs.coreutils pkgs.git pkgs.python3 pkgs.shellcheck];
  src = ../lib/validate-at-stop.sh;
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  export HOME="$PWD/home"; mkdir -p "$HOME"
  git config --global user.email a@b.c; git config --global user.name a
  git config --global init.defaultBranch main

  # --- stub prek: `prek run <id> --files ...` ---
  #   id == treefmt        -> strip trailing WS on the given files, exit 0
  #   id == cspell-BAD      -> print a finding, exit 1
  #   anything else         -> exit 0
  mkdir -p stub
  cat > stub/prek <<'STUB'
  #!/usr/bin/env bash
  set -euo pipefail
  [ "$1" = run ] || exit 0
  id="$2"; shift 2; [ "$1" = --files ] && shift
  case "$id" in
    treefmt) for f in "$@"; do sed -i 's/[[:space:]]\{1,\}$//' "$f"; done; exit 0 ;;
    cspell-BAD) echo "cspell: unknown word 'wibble' in $*"; exit 1 ;;
    *) exit 0 ;;
  esac
  STUB
  chmod +x stub/prek
  export PATH="$PWD/stub:$PATH"

  cp "$src" validate.sh; chmod +x validate.sh
  shellcheck -x validate.sh   # lint gate (matches the -x pre-commit standard)
  repo="$PWD/r"; mkdir -p "$repo"; ( cd "$repo"; git init -q; echo base > README; git add .; git commit -qm base )
  payload() { printf '{"cwd":"%s","stop_hook_active":%s,"hook_event_name":"Stop"}' "$repo" "$1"; }
  reset() { ( cd "$repo"; git reset -q --hard; git clean -qfdx ); }

  pass=0; fail=0
  ok() { if eval "$1"; then pass=$((pass+1)); else echo "FAIL: $2"; fail=$((fail+1)); fi; }

  # T1 no-diff -> silent exit 0
  reset; out="$(payload false | bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T1 rc"; ok '[ -z "$out" ]' "T1 silent"

  # T2 trailing WS -> auto-fixed via stub treefmt, no block
  reset; printf 'hi   \n' > "$repo/foo.txt"
  out="$(payload false | JUDGMENT_HOOKS_OVERRIDE=cspell bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T2 rc"
  ok '! printf "%s" "$out" | grep -q decision' "T2 no block"
  ok '! grep -nP "[ ]+\$" "$repo/foo.txt"' "T2 WS removed"

  # T3 judgment failure (stub cspell-BAD) first pass -> block w/ reason
  reset; printf 'wibble\n' > "$repo/bar.txt"
  out="$(payload false | JUDGMENT_HOOKS_OVERRIDE=cspell-BAD bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T3 rc"
  ok 'printf "%s" "$out" | grep -q "\"decision\": \"block\""' "T3 block"
  ok 'printf "%s" "$out" | grep -q project-terms' "T3 reason mentions escape"

  # T4 same failure, stop_hook_active=true -> loop-guard, no block
  reset; printf 'wibble\n' > "$repo/bar.txt"
  out="$(payload true | JUDGMENT_HOOKS_OVERRIDE=cspell-BAD bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T4 rc"
  ok '! printf "%s" "$out" | grep -q "\"decision\""' "T4 no block"
  ok 'printf "%s" "$out" | grep -q systemMessage' "T4 advisory"

  echo "validate-at-stop: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  mkdir -p "$out"; touch "$out/ok"
''
```

Register it in `flake.nix` next to the other checks (~line 204-212). Add the
`let` binding and merge it into the returned `checks` attrset following the
existing `//`-merge idiom, keeping alphabetical order:

```nix
      validateAtStopCheck = {validate-at-stop = import ./checks/validate-at-stop.nix {inherit pkgs;};};
```

…then include `validateAtStopCheck` in the same merge expression the other
`*Check` bindings are combined in.

- [ ] **Step 2: Run the check — verify it FAILS (script missing)**

Run:
`nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).validate-at-stop -L`
Expected: FAIL — `lib/validate-at-stop.sh` does not exist (`src = ../lib/…` path
error), or the eval errors on the missing file.

- [ ] **Step 3: Write `lib/validate-at-stop.sh`**

Uses the strategy confirmed in Task 1. `JUDGMENT_HOOKS_OVERRIDE` exists only so
the hermetic check can pin a stub id; in production the default list is used.

```bash
#!/usr/bin/env bash
# validate-at-stop — Claude Code `Stop` hook. Runs at the hand-back boundary
# (after the chunk's last edit), so a formatter rewrite never races the Edit
# tool's read-snapshot. Auto-fixes formatting silently; blocks-with-reason on
# judgment lint (reaching the model); escapes loops via stop_hook_active.
# Fileset = working-tree changes (unstaged ∪ staged ∪ untracked), which fixes
# prek's staged-only blind spot at Stop time.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

payload="$(cat)"
get() { printf '%s' "$payload" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))"; }
active="$(get stop_hook_active)"
repo="$(get cwd)"
[ -n "$repo" ] && cd "$repo"

# (1) no-diff early exit — pure-conversation turns cost nothing
if git diff --quiet && git diff --cached --quiet \
   && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  exit 0
fi

# working-tree changeset (unstaged ∪ staged ∪ untracked), NUL-safe
mapfile -d '' -t files < <(
  { git diff -z --name-only; git diff -z --cached --name-only; \
    git ls-files -z --others --exclude-standard; } | sort -zu)
[ "${#files[@]}" -eq 0 ] && exit 0

# (2) auto-fix formatting SILENTLY (reuse git-hooks treefmt config). Never blocks.
prek run treefmt --files "${files[@]}" >/dev/null 2>&1 || true
git add -u -- "${files[@]}" >/dev/null 2>&1 || true

# (3) judgment lint over the same changeset, reusing git-hooks config/excludes.
read -r -a judgment <<< "${JUDGMENT_HOOKS_OVERRIDE:-cspell deadnix shellcheck statix}"
report=""
for id in "${judgment[@]}"; do
  if ! out="$(prek run "$id" --files "${files[@]}" 2>&1)"; then
    report="${report}### ${id}"$'\n'"${out}"$'\n\n'
  fi
done

if [ -n "$report" ]; then
  if [ "$active" = "True" ]; then
    # loop-guard: already continued once — do not trap on a persistent finding.
    printf '%s\n' '{"systemMessage":"validate-at-stop: findings persist after one fix pass; allowing stop. Review the working tree."}'
    exit 0
  fi
  python3 - "$report" <<'PY'
import json, sys
reason = ("validate-at-stop found lint findings before hand-back "
          "(these also run at commit + CI):\n\n" + sys.argv[1] +
          "Fix them; if a cspell word is legitimate add it to "
          "config/cspell/project-terms.txt (sorted insert), then finish.")
print(json.dumps({"decision": "block", "reason": reason}))
PY
  exit 0
fi
exit 0
```

- [ ] **Step 4: Run the check — verify it PASSES (all four branches)**

Run:
`nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).validate-at-stop -L`
Expected: `validate-at-stop: 11 passed, 0 failed`, build succeeds.

- [ ] **Step 5: Write `lib/validate-at-stop.nix` and smoke-build it (shellcheck
      gate)**

```nix
# writeShellApplication wrapper for the Stop-hook validator. runtimeInputs
# give it absolute-PATH access to git/python3/prek under a stripped PATH
# (nix-standards). `prek` = config.git-hooks.package (the pre-commit suite).
{
  pkgs,
  lib,
  config,
}:
pkgs.writeShellApplication {
  name = "validate-at-stop";
  runtimeInputs = [
    config.git-hooks.package
    pkgs.coreutils
    pkgs.git
    pkgs.python3
  ];
  text = builtins.readFile ./validate-at-stop.sh;
}
```

The `writeShellApplication` re-runs shellcheck on build. It is a lib helper, not
a flake package, so there is no `nix build .#validate-at-stop` target — its
shellcheck gate is exercised (a) hermetically by the check's `shellcheck -x`
(Step 4) and (b) again when the devShell builds it in Task 3 Step 3. Fix any SC
findings in `validate-at-stop.sh` until the check is green.

- [ ] **Step 6: Commit**

```bash
git add lib/validate-at-stop.sh lib/validate-at-stop.nix checks/validate-at-stop.nix flake.nix
git commit -m "feat(devenv): add validate-at-stop Stop-hook validator + hermetic check

Runs the git-hooks suite at the Stop boundary instead of PostToolUse:
auto-fix formatting silently, block-with-reason on judgment lint, loop-guard
via stop_hook_active. Fileset covers unstaged+staged+untracked, fixing prek's
staged-only gap. Task 1 verified prek run <id> --files targets working-tree.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Wire it into devenv — add the Stop hook, disable the PostToolUse hook

**Files:**

- Modify: `devenv.nix` (`let` block ~8-14; `claude.code` block ~162-183)

**Interfaces:**

- Consumes: `validate-at-stop` executable from `lib/validate-at-stop.nix`.

- [ ] **Step 1: Bind the validator in the `let` block**

Add alongside `mcpLib`/`gen` (devenv.nix:8-14):

```nix
  validateAtStop = import ./lib/validate-at-stop.nix {inherit pkgs lib config;};
```

- [ ] **Step 2: Disable the racy PostToolUse hook and add the Stop hook**

Replace the current override block (devenv.nix:170-183, the
`hooks.git-hooks-run.command` + `hooks.git-hooks-run.matcher` override and its
comments) with:

```nix
    # Disable devenv's default PostToolUse git-hooks-run hook. It fired the
    # formatter after Edits, and treefmt's rewrite desynced the Edit tool's
    # read-snapshot ("modified since read"). Validation now happens at the
    # Stop boundary via validate-at-stop, where a rewrite has no following
    # Edit to race. Root-cause + POC:
    # docs/plans/prek-stop-hook-validator.md.
    hooks.git-hooks-run.enable = false;

    # Run the git-hooks suite when Claude hands control back (Stop): auto-fix
    # formatting silently, block-with-reason on judgment lint. See the plan.
    hooks.validate-at-stop = {
      enable = true;
      name = "validate-at-stop";
      hookType = "Stop";
      command = lib.getExe validateAtStop;
    };
```

- [ ] **Step 3: Eval-verify the generated settings (no live session needed)**

Run:

```bash
nix build .#devShells.$(nix eval --raw --impure --expr builtins.currentSystem).default 2>&1 | tail -3
# Inspect what devenv WOULD generate (the option value), not the stale symlink:
```

Then confirm the intent by reading the option — expected: `hooks.Stop` contains
`validate-at-stop`; `hooks.PostToolUse` no longer contains `git-hooks-run`.

- [ ] **Step 4: Commit**

```bash
git add devenv.nix
git commit -m "build(devenv): move git-hooks to a Stop hook; disable racy PostToolUse hook

Replaces the PostToolUse git-hooks-run hook (formatter rewrite desynced the
Edit tool between edits) with validate-at-stop at the Stop boundary.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: HITL activation + live verification

`.claude/settings.json` regenerates only on a **devshell reload**, and a live
agent run is a user-driven test — spoon-fed step-by-step, never async
(`feedback_hitl_walk_through_live`, `feedback_nixos_config_hitl`).

- [ ] **Step 1: Reload the devshell** (user runs) — `direnv reload` / re-enter
      `devenv shell`. Then verify materialization:

  ```bash
  python3 -c "import json;h=json.load(open('.claude/settings.json'))['hooks'];print('Stop:',[x for g in h.get('Stop',[]) for x in g['hooks']]);print('PostToolUse:',h.get('PostToolUse','none'))"
  ```

  Expected: `Stop` lists the `validate-at-stop` store path; `PostToolUse` no
  longer contains `git-hooks-run`.

- [ ] **Step 2: Live block→fix→clean, in a NEW session** (mirrors the POC live
      run). Introduce a deliberate cspell-flaggable word in a tracked file, let
      the turn end, and confirm the Stop hook blocks with the finding, the fix
      pass clears it, and the turn then hands back clean. Confirm a
      pure-conversation turn (no file changes) does NOT run the suite (no-diff
      early-exit).

- [ ] **Step 3: Confirm the race is gone.** Do a multi-edit sequence on one
      already-tracked file within a single turn; verify no "modified since read"
      failures occur (the previously-failing pattern).

---

## Task 5: Record the decision

- [ ] **Step 1** — In `docs/plans/prek-posttooluse-hook-feedback-channel.md`,
      replace the "Fix directions (decide later)" framing with a short
      "Resolved" note pointing to this plan and the chosen direction (Stop hook;
      formatters auto-fix; judgment lint blocks-with-reason). Additive,
      mark-don't-delete (`feedback_no_plan_removals`).
- [ ] **Step 2** — Update memory `project_edit_tool_prek_desync` to note the
      resolution supersedes the S12 matcher-scoping stopgap.

---

## Open questions / deferred from v1

- **Resolved 2026-08-29 — validator placement:** cspell, deadnix, shellcheck,
  and statix remain local pre-commit and Stop feedback, with authoritative
  whole-corpus CI gates. Changeset feedback is useful but cannot cover
  `--no-verify`, human/editor paths, or latent corpus drift.
- **SubagentStop:** should subagents validate at their own Stop too (worktree
  edits)? v1 is main-agent Stop only.
- **prek stash under `--files`:** if Task 1 finds `--files` still stashes, note
  it — harmless at Stop (no following edit) but document.
- **Bucket membership:** is `gitleaks` wanted per-chunk (secrets caught earlier)
  or is commit/CI sufficient? v1 excludes it from the Stop suite.
