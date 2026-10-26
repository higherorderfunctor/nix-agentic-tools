## devenv `files` Option Internals

> **Last verified:** 2026-10-26 — Kiro steering uses engine copies; Codex skill
> discovery was re-probed on 0.161.0; skills are staged entries the ai-module
> files engine walks. Codex declares its skill migration through activation,
> before linkCheck on both backends. The repository's committed instruction
> files are read-only copies the files engine writes, never `files.*` symlinks.
> Kiro and Kimchi settings and Codex daemon settings are owned copies; Copilot
> writes repository instructions and selected skills as owned copies; its agents
> declare a gap; recursive `ro` skills retain the engine's directory-symlink
> refusal and file-symlink dereference; the files engine writes Claude's project
> rules. Identical copy bytes with changed permissions are corrected without a
> backup. Recursive leaf links target one source-tree store root while retaining
> per-file input contexts. The symlink guard uses devenv's final file target and
> runs after engine pruning and before native file creation. Recursive expansion
> belongs only to the files engine.
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
the old read-only store directory and fails. ai-module's one `files-guard`
checks desired native destinations after engine pruning and pre-link commands,
and before `devenv:files`. It accepts the desired store link, removes changed
store links, and refuses regular files, directories, special files, non-store
links and symlinked parents. The desired target is `config.files.<path>.file`,
including devenv's executable wrapper. Removed links remain devenv's cleanup
responsibility. A failed guard prevents native file creation and shell entry
reports the failed dependency.

The other branch does recurse. `createCopyScript` drops a previous
store-symlink, then materializes with `cp -RL` followed by `chmod -R u+w`, so a
directory source is copied through and the result is WRITABLE. `copyMode`
accepts `symlink` (default), `seed` (create only when absent, preserving user
edits) and `copy` (overwrite every entry). This repo uses neither mode for
generated instruction files; the engine owns their copies.

### Silent-fail behavior (important)

This is upstream behavior for a raw `files.*` entry. For an `ai.*` destination
`ai:files-guard` refuses the same conflicts before `devenv:files`, so shell
entry fails loudly instead.

The create script has three branches for conflicts. Cases 2 and 3 (existing file
or non-file at the target path) **log to stderr but do NOT exit non-zero**: the
config evaluates fine, the build succeeds, but on disk there's no symlink. If a
real directory exists at the target path, devenv logs a warning and silently
skips creating the new directory-link entry.

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
extra top-level skill-link prune: Claude, Kimchi and Kiro skills are real
directories with per-file links. Cleanup handles removed entries, and the
delivery guard handles changed store-link targets. It **only removes symlinks**
— never real files or directories. This is another reason Layout A → B
transitions get stuck: orphan cleanup can't clear a real dir that a previous
generation laid down.

### The files engine's recursive walk

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

The implementation lives in `packages/ai-module/lib/files/default.nix:walk`. A
producer stages one recursive directory source; the files engine expands it into
leaves for both backends. `mkSkillFiles` uses that staging path. There is no
separate backend walker. `mkSkillFiles` accepts `method`, defaulting to
`"symlink"`; Copilot selects `"ro"` on devenv so the same leaf expansion reaches
the owned-copy engine instead of native `files.*` links. Each delivered leaf is
a real file, including a file-symlink source's bytes, and executable bits are
preserved. A directory-symlink source is refused, not followed. Removing a
selected skill or disabling Copilot retires its owned copies through the same
state as instructions, preserving unmanaged siblings and backing up edited
copies.

The walk separates traversal identity from target identity. It traverses the
original source, interpolates that directory once, and points every native leaf
link beneath the resulting store root. It also appends each independently
interpolated leaf's string context to the target. The visible target therefore
shares a real path with a whole-directory Layout A link, while devenv still sees
the per-file inputs that make direnv reload after an edit.

Codex is the exception. Its 0.161.0 scanner ignores a real skill directory
containing symlinked leaves but discovers a symlinked skill directory. Codex
therefore stages each directory with `recursive = false` for the files engine.
`activation.codex-migrate-skill-links` declares `after = []` and
`before = ["linkCheck"]` on both backends. On devenv this becomes
`ai:codex-migrate-skill-links`, after `devenv:files:cleanup` and before
`ai:link-check`; on Home Manager it becomes `ai-codex-migrate-skill-links`,
before `checkLinkTargets` with no predecessors. Skill names are restricted at
evaluation; the command validates the whole target set first, rejects non-store
or non-directory content, and refuses symlinked `.agents` or `skills` parents
before moving each legacy tree intact under the backend's state directory.
Existing store-backed top-level links are unlinked for replacement by the files
engine. The backup preserves even empty directories for recovery; unexpected
content fails the migration loudly before anything changes.

### How HM produces Layout B

HM's `home.file.<name>` submodule has a `recursive` field
(`home-manager/modules/files.nix`). When `source` is a directory and
`recursive = true`, HM's activation script walks the directory and creates
per-file symlinks inside a real subdirectory at `<name>`, with state tracking
per file. This repository instead gives Home Manager per-leaf links already
expanded by the files engine. Codex deliberately uses a non-recursive source,
producing the same whole-directory link as devenv. Shared expansion gives both
backends the same leaf inventory.

### Upstream PR opportunity

Filing a PR to `cachix/devenv` adding a `recursive` field to `fileType` that
triggers a `builtins.readDir`-based walk in the `createFileScript` generator
would benefit every devenv user, not just us. Not blocking any current work —
the user-space walker is a viable fix while waiting for upstream.

### Instruction files are copies, not `files.*` symlinks

This repository's instruction files are written by `ai.*` (configured in
`dev/ai.nix`) like any consumer's. On devenv local `AGENTS.md`, its
`.agents/rules/` child indexes, committed `.github/` instructions, and Claude's
and Kiro's project rules are read-only COPIES the ai-module files engine writes
on every `devenv shell`, `direnv reload`, `devenv up`, `devenv reload` and
manual `devenv test`, after `devenv:files:cleanup` and before
`devenv:enterShell`. Claude's `.claude/CLAUDE.md` stays a store link (its
project context loader follows one; its scoped-rule loader does not).

Why copies rather than `files.*` symlinks:

- **A tracked file cannot be a symlink.** A store symlink commits as mode
  `120000` holding an absolute `/nix/store` path, meaningless in any other clone
  and on github.com.
- **Each writer claims only what it wrote.** A developer's own steering or
  instruction file beside the generated ones survives every reload; a retired
  rule's copy is removed.
- **The engine is idempotent.** An unchanged file keeps its mtime, and changed
  bytes are backed up before replacement. Identical bytes with differing
  permissions are corrected without a backup, including after a checkout changes
  the mode.

`devenv`'s own `files.<name>.copyMode = "copy"` was considered and rejected: it
`rm -rf`s and re-`cp`s unconditionally on every entry (a read race plus mtime
churn), it cannot prune, and it has no ownership record, so it cannot retract a
file whose rule is removed.

Skills still use `files.*` symlinks — they are not tracked. Claude's
`.claude/settings.json` and `.mcp.json` and Codex's `config.toml` are also store
links because those consumers tolerate them. Kiro and Kimchi settings, and Codex
daemon settings, instead use owned read-only copies because their writers rename
over the configured path. Most skill backends enumerate leaves; Codex
intentionally contributes one directory entry per skill.

### Related

- `dev/fragments/ai-skills/skills-fanout-pattern.md` — runtime-specific skill
  delegation and the Codex Layout A exception
