## devenv `files` Option Internals

> **Last verified:** 2026-10-08 — Claude's skills are `ai.*` delivery entries.
> The repository's instruction files are `ai.*`'s own read-only copies (`own`),
> never `files.*` symlinks; the generator's materializer and the AGENTS.md seed
> are gone. Copilot, Kiro and Kimchi settings and Codex daemon settings are
> owned copies. Recursive leaf links target one source-tree store root while
> retaining per-file input contexts. The symlink guard uses devenv's final file
> target, follows its own runtime's writers before file creation, and reports
> every conflict before failing.
>
> Full lineage: `git show 2ac8d522:dev/fragments/devenv/files-internals.md`.

devenv's `files` option is structurally simpler than HM's `home.file`.
Specifically, **it cannot walk a source directory recursively to produce
per-file symlinks**, and it **silently no-ops on dir-vs-symlink conflicts**.
Both behaviors matter when working on devenv module files in this repo.

### Where devenv `files` is defined

Upstream: `<devenv-source>/src/modules/files.nix` in the `cachix/devenv` flake.
On a system that has devenv installed, locate with:

```bash
find /nix/store -name 'files.nix' -path '*devenv*' 2>/dev/null
```

Hashes change across releases; don't bookmark a specific path.

### Structural constraints

**The `source` format is identity:**

```nix
source = {
  type = types.path;
  generate = filename: path: path;   # identity — no walk, no expansion
};
```

Whatever path you provide is passed through verbatim: the format itself never
walks, enumerates, or expands it.

Keep source GENERATION separate from MATERIALIZATION, because only the second
one varies. Generation is identity in every mode. Materialization is where
`copyMode` decides: under the default `symlink` the path becomes the symlink
target and nothing recurses, while under `copy` or `seed` that same path goes to
`cp -RL`, so a directory source is copied through as a tree. "No recursion" is
therefore a property of the symlink branch, not of the `source` format — see the
dispatcher below.

**The submodule has no recursive field:**

`fileType` has `format`, `data`, `file`, `executable`, `copyMode`, plus one
option per format (`ini`, `json`, `yaml`, `toml`, `text`, `source`). Notably
**missing**:

- No `recursive` field
- No `tree` / `walk` field
- No file-level enumeration hook

Each `files.<name>` is exactly one DECLARED entry. Under the default
`copyMode = "symlink"` that is also exactly one on-disk entry; under
`copyMode = "copy"` a directory source lands as a copied tree, so the
one-entry-one-inode reading does not survive that mode.

**`createFileScript` is a dispatcher, not the writer:**

```nix
createFileScript = filename: fileOption:
  if fileOption.copyMode == "symlink"
  then createSymlinkScript filename fileOption
  else createCopyScript filename fileOption;
```

**The symlink branch does one `ln -s` per entry:**

```bash
createSymlinkScript = filename: fileOption: ''
  if [ -L "${filename}" ]; then
    # Update symlink target if it changed
    if [ "$(readlink "${filename}")" != "${fileOption.file}" ]; then
      ln -sf ${fileOption.file} "${filename}"
    fi
  elif [ -f "${filename}" ]; then
    echo "Conflicting file ${filename}" >&2  # NO non-zero exit
  elif [ -e "${filename}" ]; then
    echo "Conflicting non-file ${filename}" >&2  # NO non-zero exit
  else
    mkdir -p "${dirOf filename}"
    ln -s ${fileOption.file} "${filename}"
  fi
'';
```

No recursion in this branch — one `ln -s` per entry. Upstream
`src/modules/files.nix:115` updates with `ln -sf` without `-n`: an existing link
to a directory is followed, so a changed target attempts to create a link inside
the old read-only store directory and fails. The delivery router's devenv-only
`ai:<runtime>:guard-symlink-updates` task uses its lowered symlink entries to
unlink only changed links whose current target is under `/nix/store/`. It fails
loudly on a real file or directory at a delivered path, where devenv would only
warn and skip the entry. For a non-store link, devenv ran `ln -sf` without `-n`:
a link to a file, or a dangling link, was replaced, but a link to a writable
directory was followed, leaving the old link and adding a stray link inside that
directory. The guard now refuses both. The guard runs after
`devenv:files:cleanup` and all owned and command writers of its runtime ordered
before `devenv:files`, then before `devenv:files`. There is one guard per
runtime with symlink entries; no file-type probing is needed. A cross-owner
handoff from an owned copy to a symlink can fail the guard for one shell entry
until the other owner's retraction has run. Its desired target is
`config.files.<path>.file` for entries whose final `copyMode` is `symlink`,
including devenv's executable wrapper, rather than the source-tree path. The
guard reports every offending path before failing. A failed guard makes
`devenv:files` and `devenv:enterShell` `DependencyFailed`: shell entry continues
with a warning, but no `files.*` entry from any runtime or the user is created
or updated, and `devenv test` fails.

The other branch does recurse. `createCopyScript` drops a previous
store-symlink, then materializes with `cp -RL` followed by `chmod -R u+w`, so a
directory source is copied through and the result is WRITABLE. `copyMode`
accepts `symlink` (default), `seed` (create only when absent, preserving user
edits) and `copy` (overwrite every entry). This repo uses `seed` only for the
generated `AGENTS.md` ownership handoff described below. Repeated overwrite mode
remains rejected.

### Silent-fail behavior (important)

The create script has three branches for conflicts. Cases 2 and 3 (existing file
or non-file at the target path) **log to stderr but do NOT exit non-zero**. The
`ai.skills` config evaluates fine, the build succeeds, but on disk there's no
symlink.

**Consequence for Layout B → A transitions:** if a real directory exists at the
target path (because an HM activation or a previous devenv run using a
directory-walking helper laid it down), devenv will log a warning and silently
skip creating the new directory-link entry. The user sees skills "missing" with
no clear error.

**Detect silent failures in practice:**

```bash
devenv shell 2>&1 | grep -i conflict
# OR
devenv test 2>&1 | grep -i conflict
```

Look for `Conflicting file <path>` or `Conflicting non-file <path>` lines.

### State tracking and orphan cleanup

devenv tracks managed files in `${config.devenv.state}/files.json`. On every
run, the cleanup task reads previous state, compares to current config, and
removes orphaned symlinks pointing into `/nix/store/*`. The repository needs no
extra top-level skill-link prune: Claude, Copilot and Kiro skills are real
directories with per-file links. Cleanup handles removed entries, and the
delivery guard handles changed store-link targets. It **only removes symlinks**
— never real files or directories. This is another reason Layout A → B
transitions get stuck: orphan cleanup can't clear a real dir that a previous
generation laid down.

### The user-space walker (the delivery router's one walk)

To produce Layout B (a directory containing per-file symlinks) via the `files`
option, split one logical "skill directory" into N
`files."<path>".source = <file>;` entries — one per leaf file. This must happen
at Nix evaluation time because devenv's create script has no hook for runtime
expansion.

`builtins.readDir <path>` returns `{ name → type }` for a directory. Recursing
through it produces the leaf-file list, and each leaf becomes a `files` entry
whose `source` points at the full path within the original tree.

Key behaviors:

- Works on any path Nix evaluation has read access to. For
  `ai.skills = { foo = ./skills/foo; }`, the path is relative to the flake root
  and Nix can read it.
- Preserves the directory structure of the source.
- Eval-time cost is proportional to file count. Negligible for typical skill
  dirs.
- Does NOT need IFD. It's pure `readDir` on paths the flake already tracks.

The implementation lives in `lib/ai/formats.nix:walk`, called by
`lib/ai/deliver.nix` for any delivery entry with `recursive = true` on the
devenv backend. A factory therefore declares the tree ONCE, with a directory
source, and each backend expands it its own way — this walk, or Home Manager's
native recursion. It replaced three hand-written copies of the same recursion
(the skill helper, its devenv twin, and kiro's inline agents-directory walker).

The walk separates traversal identity from target identity. It traverses the
original source, interpolates that directory once, and points every native leaf
link beneath the resulting store root. It also appends each independently
interpolated leaf's string context to the target. The visible target therefore
shares a real path with a whole-directory Layout A link, while devenv still sees
the per-file inputs that make direnv reload after an edit.

Codex is the exception. Its 0.147.0 scanner ignores a real skill directory
containing symlinked leaves but discovers a symlinked skill directory. Codex
therefore declares `recursive = false` with a directory source, which maps
directly onto devenv's identity behavior. The `ai:codex:migrate-skill-links`
task runs after `devenv:files:cleanup` and before `devenv:files`. It validates
the whole target set first, rejects unsafe names and non-store or non-directory
content, and refuses symlinked `.agents` or `skills` parents before moving each
legacy tree intact under the devenv state directory. Existing store-backed
top-level links are unlinked so devenv cannot follow them while updating the
target. The backup preserves even empty directories for recovery; unexpected
content fails the migration loudly before anything changes.

### How HM produces Layout B

HM's `home.file.<name>` submodule has a `recursive` field
(`home-manager/modules/files.nix`). When `source` is a directory and
`recursive = true`, HM's activation script walks the directory and creates
per-file symlinks inside a real subdirectory at `<name>`, with state tracking
per file. Our delivery entries use it for Layout B consumers, Claude's skills
included: the adapter passes `recursive` straight through to `home.file`. Codex
deliberately uses a non-recursive Home Manager source instead, producing the
same whole-directory link as devenv.

devenv chose a simpler, flatter model without recursive support. Not a bug; a
deliberate design difference. The user-space walker restores parity at the cost
of eval-time directory walks.

### Upstream PR opportunity

Filing a PR to `cachix/devenv` adding a `recursive` field to `fileType` that
triggers a `builtins.readDir`-based walk in the `createFileScript` generator
would benefit every devenv user, not just us. Not blocking any current work —
the user-space walker is a viable fix while waiting for upstream.

### Instruction files are copies, not `files.*` symlinks

This repository's instruction files are written by `ai.*` (configured in
`dev/ai.nix`) like any consumer's. On devenv the committed ones (AGENTS.md,
`.github/copilot-instructions.md`, `.github/instructions/*`) and Claude's and
Kiro's project rule files are read-only COPIES written by `lib/ai/own.py`
through a directory ledger each, on every `devenv shell`, `direnv reload`,
`devenv up`, `devenv reload` and manual `devenv test`, after
`devenv:files:cleanup` and before `devenv:enterShell`. Claude's
`.claude/CLAUDE.md` stays a store link (its project context loader follows one;
its scoped-rule loader does not).

Why copies rather than `files.*` symlinks:

- **A tracked file cannot be a symlink.** A store symlink commits as mode
  `120000` holding an absolute `/nix/store` path, meaningless in any other clone
  and on github.com.
- **A ledger claims only what it wrote.** A developer's own steering or
  instruction file beside the generated ones survives every reload; a retired
  rule's copy is removed.
- **`own` is idempotent and quiet.** Unchanged bytes keep the mtime, and a file
  whose bytes already match (a `git pull` of the committed copy) is adopted
  without a backup; different bytes are backed up once before replacement.

`devenv`'s own `files.<name>.copyMode = "copy"` was considered and rejected: it
`rm -rf`s and re-`cp`s unconditionally on every entry (a read race plus mtime
churn), it cannot prune, and it has no ownership record, so it cannot retract a
file whose rule is removed. The `seed` mode the generator's AGENTS.md used is
gone with the generator's materializer.

Skills still use `files.*` symlinks — they are not tracked. Claude's
`.claude/settings.json` and `.mcp.json` and Codex's `config.toml` are also store
links because those consumers tolerate them. Copilot, Kiro and Kimchi settings,
and Codex daemon settings, instead use owned read-only copies because their
writers rename over the configured path. Most skill backends enumerate leaves;
Codex intentionally contributes one directory entry per skill.

### Related

- `dev/fragments/ai-skills/skills-fanout-pattern.md` — runtime-specific skill
  delegation and the Codex Layout A exception
