<!-- TODO: remove this file before merging to main -->

❯ add it as a short backlog item.

knock out 1-3 so we can ypdate specific packages as a single task.

then debug which version checking is really needed, if doesn't make sense for main then adjust the logic not to
grab release version.

then parallel updates using worktree hack.
FINISH CI
parallel nix update and github api key
SWITCH MCPS OR NODE BASED PACKAGES TO BUN

SINGLE SOURCER OF YRUTH FOR FLAKE INPUTS KINDA NUTS NEED EXPLAIN

● Resume prompt:

▎ Continue the nix-update migration on refactor/ai-factory-architecture. Check
.remember/remember.md for the remaining work list. Start with item 1 (replace custom TOML parser
with builtins.fromTOML) and work through the list. Don't push until everything builds end-to-end.
update script caches (<REPO>/.cache?</REPO>

why update script takes so much cpu, did direnv fire maybe?

ME: doub;e check work
ME: test in nixos-config

- Update overlays/README.md table to reflect all the source changes made tonight
- Document the unfree guard pattern as an architecture fragment
  ● Here's my plan for the remaining items:
  1. Pre-commit hook fix
     devenv's git-hooks.hooks config has a treefmt entry but no re-staging. Options:
  - Add a custom hook that runs AFTER treefmt: git diff --name-only | xargs git add
  - Or configure treefmt hook's pass_filenames + post-run staging
  - Need to check if devenv/prek supports entry overrides or post-hook commands
  2. Dirty tree guard in update:nix-update
     Add at the top of the task exec:
     if [ -n "$(git status --porcelain)" ]; then
     echo "ERROR: working tree is dirty. Commit or stash changes first." >&2
     git status --short >&2
     exit 1
     fi

  3. Per-package tasks (sequential → parallel)
     Generate from the package set at eval time:

  # Build task attrset from flake packages

  updatePkgTasks = lib.mapAttrs' (name: \_: lib.nameValuePair "update:pkg:${name}" {
  description = "Update ${name}";
  exec = ''...''; # nix-update call for this package
  }) filteredPackages;

  For sequential: chain with after (each depends on previous).
  For parallel with worktrees: wrap each exec in git worktree add /tmp/update-${name} && cd ... && nix-update ...
  && git worktree remove.

  The update:nix-update meta task has after = [all per-package task names]. 4. Worktree parallel pattern

  # Per task exec

  wt="/tmp/nix-update-${name}"
  git worktree add "$wt" HEAD --detach
  cd "$wt"
  nix run --inputs-from . nix-update -- --flake ${name} --commit --system "$system"
  cd -

  # Cherry-pick the commit back

  git cherry-pick "$(git -C "$wt" rev-parse HEAD)"
  git worktree remove "$wt"

  Risk: cherry-pick conflicts if two packages modify the same file (shouldn't happen — each writes to its own .nix
  file). The meta task would need to handle the cherry-picks sequentially after all parallel tasks complete.

  Actually simpler: don't cherry-pick. Each worktree commits on a detached HEAD. After all parallel tasks, collect
  the patches and apply them:
  git -C "$wt" format-patch HEAD~1 --stdout | git am

  This is the pattern but it adds real complexity. Worth implementing after the basics are solid.

❯ git cant do like 3 way merges, fail if its cannot automatically do (shouldn't be the case since none touch the
same file). just a thought, im guessing.

---

Are we (and this may be tricky) able to warn if someone overrides
this flakes input nixpkgs or any other inputs, and, if possible check if cachix is set, then
produce a warning they are bypassing cachix and remove the follows?
or if they are not using cachix, then produce a warning that they should be using cachix and remove the follows?

so.. if we cannot see the users cachix/substitutors
a) warn if inputs are overridden about producing a cache miss.

if we cant see the users cachix/substitutors, then
b) warn if cachix is not substitors that we have prebuilt binaries from cachix
c) only warn (a) if (b) passes (they have our substitors) but they are overriding inputs, otherwise just warn about (b) and not (a) since they are already bypassing cachix

These are only warnings, we wont break their build.
if possible provide an option to disable the warning? not sure how easy this is with different module systems possibly in play (or even no module if consumer just uses overlays and no hm/devenv). just thinking about it from a UX perspective what we may be able to do.
