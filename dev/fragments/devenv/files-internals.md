## devenv `files` Option Internals

> **Last verified:** 2026-08-29 (commit pending — repository instruction copies
> now use one packaged materializer from both shell-entry tasks and a flake
> contract test; the helper also repairs symlinks/modes and rejects an empty
> source before pruning). Prior: 2026-08-17 (commit pending — Codex's devenv
> backend now resolves linked-worktree Git metadata into a direct named-profile
> permission; like the existing cache-root fanout, this evaluation-only settings
> effect creates no `files.*` artifact). Prior: 2026-08-17 (commit pending —
> Codex deliberately uses devenv's one-entry directory symlink behavior because
> 0.147.0 discovers that layout but ignores a real skill directory containing
> symlinked leaves; a pre-files migration validates ownership and moves the
> legacy directory intact to a recoverable state backup). Prior: 2026-08-16
> (commit pending — Kiro 2.18.1 now discovers and live-reloads symlink
> replacement in both project and Home-Manager-like layouts, so runtime steering
> moved to `ai.kiro.files` and ordinary `files.*` delivery; generated tracked
> instruction projections remain copies because store symlinks cannot be
> committed portably). Prior: 2026-08-15 (commit pending — Codex, glab, and
> Semble writable-root fanout now travels through the hidden
> `ai.codex.internal._integration_writable_roots` channel and is folded into
> native config at emission; it still creates no `files.*` artifact). Prior:
> 2026-08-14 (commit pending — Semble's shell-entry cache guard remains an
> environment/settings lifecycle effect and creates no `files.*` artifact).
> Prior: 2026-08-05 (commit pending — re-verifies that Codex's environment
> resolver and sandbox-root fanout create no `files.*` artifact while its test
> override moves out of the formal module argument set). Prior: 2026-08-05
> (commit pending — Codex and glab sandbox-root fanout is settings/environment
> integration and deliberately creates no `files.*` artifact). Prior: 2026-08-02
> (commit pending — Semble's devenv facet keeps its sandbox-writable cache in
> project state and exports the same path through `SEMBLE_CACHE_LOCATION`; this
> is environment/settings fanout, not a `files.*` artifact). Prior: 2026-07-21
> (commit pending — corrects the Kiro-symlink citation to kirodotdev/Kiro#9787
> with the engine qualifier, and the `files.<name>.source` claim; earlier
> revision added auto-regeneration via `gen` import). devenv internals are
> pinned to whatever version is in flake.lock; if you touch `modules/devenv/**`,
> `lib/hm-helpers.nix:mkDevenvSkillEntries`, `devenv.nix` `files` block, or
> anywhere that uses `files.*.source` and this fragment isn't updated in the
> same commit, stop and fix it.

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

Whatever path you provide becomes the symlink target verbatim. No recursion, no
enumeration, no per-file generation.

**The submodule has no recursive field:**

`fileType` has `format`, `data`, `file`, `executable`, plus one option per
format (`ini`, `json`, `yaml`, `toml`, `text`, `source`). Notably **missing**:

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
removes orphaned symlinks pointing into `/nix/store/*`. It **only removes
symlinks** — never real files or directories. This is another reason Layout A →
B transitions get stuck: orphan cleanup can't clear a real dir that a previous
generation laid down.

### The user-space walker (`mkDevenvSkillEntries`)

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

The implementation lives in `lib/hm-helpers.nix:mkDevenvSkillEntries` and is the
recommended fix when a runtime requires the HM-style recursive layout.

Codex is the exception. Its 0.147.0 scanner ignores a real skill directory
containing symlinked leaves but discovers a symlinked skill directory. Codex
therefore uses `mkSkillDirectoryEntries`, whose directory source maps directly
onto devenv's identity behavior. The `ai:codex:migrate-skill-links` task runs
after `devenv:files:cleanup` and before `devenv:files`. It validates the whole
target set first, rejects unsafe names and non-store or non-directory content,
and refuses symlinked `.agents` or `skills` parents before moving each legacy
tree intact under the devenv state directory. Existing store-backed top-level
links are unlinked so devenv cannot follow them while updating the target. The
backup preserves even empty directories for recovery; unexpected content fails
the migration loudly before anything changes.

### How HM produces Layout B

HM's `home.file.<name>` submodule has a `recursive` field
(`home-manager/modules/files.nix`). When `source` is a directory and
`recursive = true`, HM's activation script walks the directory and creates
per-file symlinks inside a real subdirectory at `<name>`, with state tracking
per file. Upstream `programs.claude-code.skills` uses this via `mkSkillEntry`.
Our own `lib/hm-helpers.nix:mkSkillEntries` mirrors the pattern for direct
Layout B consumers. Codex deliberately uses a non-recursive Home Manager source
instead, producing the same whole-directory link as devenv.

devenv chose a simpler, flatter model without recursive support. Not a bug; a
deliberate design difference. The user-space walker restores parity at the cost
of eval-time directory walks.

### Upstream PR opportunity

Filing a PR to `cachix/devenv` adding a `recursive` field to `fileType` that
triggers a `builtins.readDir`-based walk in the `createFileScript` generator
would benefit every devenv user, not just us. Not blocking any current work —
the user-space walker is a viable fix while waiting for upstream.

### Instruction files are copies, not `files.*` symlinks

`devenv.nix` imports `dev/instructions.nix` as `instr` — the same import
`flake.nix` uses, so both render identical bytes. It exposes the four
`instructions-*` derivations; the working tree is materialized from them by a
shell-entry task, **not** by `files.*`:

```nix
instr = import ./dev/instructions.nix {
  inherit lib pkgs;
  inherit (inputs) treefmt-nix;
};
```

`lib/materialize-repo-instructions.nix` packages the copier.
`dev/tasks/generate.nix` invokes that helper from
`generate:instructions:materialize` with `before = ["devenv:enterShell"]`, so
every `devenv shell`, `direnv reload`, `devenv up`, `devenv reload`, and manual
`devenv test` copies `CLAUDE.md`, `.claude/rules/*.md`, `AGENTS.md`,
`.github/copilot-instructions.md`, `.github/instructions/*.md` and
`.kiro/steering/*.md` into place as **real files**.

Why copies rather than `files.*`:

- **The tracked outputs cannot be symlinks at all.** A store symlink commits as
  mode `120000` holding an absolute `/nix/store` path — meaningless in any other
  clone.

The earlier Kiro-loader rationale is stale. Bounded live-TUI spikes against the
pinned 2.18.1 release used `/context show` to prove both startup discovery and
same-session symlink replacement reload in project-local and isolated global
layouts. Factory-generated steering therefore traverses `ai.kiro.files` and the
ordinary backend symlink sink. Kiro hooks retain real-file materialization
because the steering probes did not revalidate hook loading or its ownership
lifecycle.

The materializer is idempotent (same bytes, real-file type, and mode leave the
mtime alone), atomic (`mktemp` + `mv`, so a concurrent agent session never reads
a partial file), and prunes generated files whose fragment was renamed or
removed — including dangling symlinks. It refuses to prune when a generated
source directory is unexpectedly empty. `checks/instruction-materialization.nix`
runs this exact executable against a temporary repository and gates all of those
properties under `nix flake check`; CI does not need a full devenv shell to test
them.

`devenv`'s own `files.<name>.copyMode = "copy"` was considered and rejected: it
`rm -rf`s and re-`cp`s unconditionally on every entry (a read race plus mtime
churn), it cannot prune, and feeding it _formatted_ content would require
`builtins.readFile` on the built derivation — IFD on every eval.
(`files.<name>.source` does exist in the pinned version — mkKiro uses it — but
it only takes a path, not formatted content.)

**Prerequisite:** the `coding-standards` overlay must be applied to devenv's
pkgs, because the fragment composition reads
`pkgs.coding-standards.passthru.fragments`.

Skills, `settings.json` and MCP JSON still use `files.*` symlinks — they are not
tracked. Most skill backends enumerate leaves; Codex intentionally contributes
one directory entry per skill.

### Related

- `dev/fragments/ai-skills/skills-fanout-pattern.md` — runtime-specific skill
  delegation and the Codex Layout A exception
