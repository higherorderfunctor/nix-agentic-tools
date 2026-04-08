## devenv `files` Option Internals

> **Last verified:** 2026-04-08 (commit 03af9d3 — feat(lib): add `mkDevenvSkillEntries` walker for devenv `files.*` parity). devenv internals
> are pinned to whatever version is in flake.lock; if you touch
> `modules/devenv/**`, `lib/hm-helpers.nix:mkDevenvSkillEntries`,
> or anywhere that uses `files.*.source` and this fragment isn't
> updated in the same commit, stop and fix it.

devenv's `files` option is structurally simpler than HM's
`home.file`. Specifically, **it cannot walk a source directory
recursively to produce per-file symlinks**, and it **silently
no-ops on dir-vs-symlink conflicts**. Both behaviors matter when
working on devenv module files in this repo.

### Where devenv `files` is defined

Upstream: `<devenv-source>/src/modules/files.nix` in the
`cachix/devenv` flake. On a system that has devenv installed,
locate with:

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

Whatever path you provide becomes the symlink target verbatim.
No recursion, no enumeration, no per-file generation.

**The submodule has no recursive field:**

`fileType` has `format`, `data`, `file`, `executable`, plus one
option per format (`ini`, `json`, `yaml`, `toml`, `text`,
`source`). Notably **missing**:

- No `recursive` field
- No `tree` / `walk` field
- No file-level enumeration hook

Each `files.<name>` is exactly one on-disk entry.

**Create script does one `ln -s` per entry:**

```bash
createFileScript = filename: fileOption: ''
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

No recursion. One `ln -s` per entry.

### Silent-fail behavior (important)

The create script has three branches for conflicts. Cases 2 and
3 (existing file or non-file at the target path) **log to stderr
but do NOT exit non-zero**. The `ai.skills` config evaluates
fine, the build succeeds, but on disk there's no symlink.

**Consequence for Layout A → B transitions:** if a real directory
exists at the target path (because an HM activation or a previous
devenv run using a directory-walking helper laid it down), devenv
will log a warning and silently skip creating the file entry. The
user sees skills "missing" with no clear error.

**Detect silent failures in practice:**

```bash
devenv shell 2>&1 | grep -i conflict
# OR
devenv test 2>&1 | grep -i conflict
```

Look for `Conflicting file <path>` or `Conflicting non-file <path>`
lines.

### State tracking and orphan cleanup

devenv tracks managed files in `${config.devenv.state}/files.json`.
On every run, the cleanup task reads previous state, compares to
current config, and removes orphaned symlinks pointing into
`/nix/store/*`. It **only removes symlinks** — never real files
or directories. This is another reason Layout A → B transitions
get stuck: orphan cleanup can't clear a real dir that a previous
generation laid down.

### The user-space walker (`mkDevenvSkillEntries`)

To produce Layout B (a directory containing per-file symlinks)
via the `files` option, split one logical "skill directory" into
N `files."<path>".source = <file>;` entries — one per leaf file.
This must happen at Nix evaluation time because devenv's create
script has no hook for runtime expansion.

`builtins.readDir <path>` returns `{ name → type }` for a
directory. Recursing through it produces the leaf-file list, and
each leaf becomes a `files` entry whose `source` points at the
full path within the original tree.

Key behaviors:

- Works on any path Nix evaluation has read access to. For
  `ai.skills = { foo = ./skills/foo; }`, the path is relative to
  the flake root and Nix can read it.
- Preserves the directory structure of the source.
- Eval-time cost is proportional to file count. Negligible for
  typical skill dirs.
- Does NOT need IFD. It's pure `readDir` on paths the flake
  already tracks.

The implementation lives in `lib/hm-helpers.nix:mkDevenvSkillEntries`
(when Task 2b lands) and is the recommended fix for the HM/devenv
skills layout parity gap.

### Why HM doesn't have this problem

HM's `home.file.<name>` submodule has a `recursive` field
(`home-manager/modules/files.nix`). When `source` is a directory
and `recursive = true`, HM's activation script walks the directory
and creates per-file symlinks inside a real subdirectory at
`<name>`, with state tracking per file. Upstream
`programs.claude-code.skills` uses this via `mkSkillEntry`. Our
own `lib/hm-helpers.nix:mkSkillEntries` mirrors the pattern for
`programs.copilot-cli.skills` and `programs.kiro-cli.skills`.

devenv chose a simpler, flatter model without recursive support.
Not a bug; a deliberate design difference. The user-space walker
restores parity at the cost of eval-time directory walks.

### Upstream PR opportunity

Filing a PR to `cachix/devenv` adding a `recursive` field to
`fileType` that triggers a `builtins.readDir`-based walk in the
`createFileScript` generator would benefit every devenv user, not
just us. Not blocking any current work — the user-space walker is
a viable fix while waiting for upstream.

### Related

- `dev/fragments/ai-skills/skills-fanout-pattern.md` — the
  uniform `programs.<cli>.skills` delegation pattern that this
  walker enables on devenv side
- `memory/project_devenv_files_internals.md` — original deep-dive
  source content
- `memory/project_ai_claude_passthrough.md` — Task 2b (devenv
  parity decision: Option A recommended uses this walker)
