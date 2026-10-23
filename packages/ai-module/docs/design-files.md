# Generic files

> **Last verified:** 2026-10-22 — split from DESIGN.md without changing the
> generic file, activation or service contracts.

### Layer 2: generic files

`ai.files` is `attrsOf fileEntry`, default `{}`. It serves runtimes and ordinary
program modules equally. `fileEntry` is the files engine schema: content
alternatives `run/source/text/value` default null; `enable` defaults true;
`executable` and `mode` default null; `format` defaults `raw`; `method` defaults
`symlink`; `recursive` defaults false. Two internal fields are added.
`_contentPrio` is read-only: the strongest priority of any `content` definition,
read without evaluating one, so a runtime's generated tree can leave out a
whole-content default a consumer replaced. `requires` is a list of derivations,
default `[]`. The engine appends their string context to each delivered leaf
after the recursive walk, so the backends build them before delivery and
evaluation never reads them; a runtime's generated files require its generated
tree, whose guards, surface checks and byte limits then gate a recursive source
or a value that does not point into it. Types, priority arbitration and all
refused combinations remain in the engine document. A backend-specific method
still requires both `devenv` and `hm` fields.

Normalize the complete map once, after merging and runtime gating, then check
expanded destination collisions. Symlinks lower to `home.file` or devenv
`files`; `ro` and `rw` always use the engine on both backends. Native devenv
copy cannot retire real files (`dev/fragments/devenv/files-internals.md`). There
is no native-copy escape hatch for an entry owned by this map: a native
`files.<path>.copyMode` other than `symlink` on any enabled normalized
destination, including `ro` and `rw`, fails evaluation with that path named.

`ai.deliveredPaths` is public and read-only: every enabled `ai.files` key, a
recursive key as `<key>/**`. The devenv module appends it to
`treefmt.config.settings.global.excludes` when the shell has treefmt enabled, so
repository formatting never rewrites a delivered file; another consumer can read
the same list for its own formatter.

One stable namespace, `ai`, owns the unified copy plan. The engine state is HM
`${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/files/ai.json` and
devenv `$DEVENV_STATE/nix-agentic-tools/files/ai.json`. Roots are `$HOME` and
`$DEVENV_ROOT`, respectively. Neither namespace nor engine task names are
per-file options. The same root must not be activated concurrently through two
independent backend states. The engine's state-directory move and legacy import
are described in [files-engine.md](files-engine.md#legacy-ownership-import).

Layer 2 generates `files-prune` internally on every activation, including with
an empty map, so removing the last file still drains it. For an empty map only,
its command exits before Python starts when neither the engine state file nor
any listed legacy ledger exists; the engine deletes both once nothing is owned,
so a consumer that declares no files pays one shell test per activation. A
nonempty map always starts the engine in prune, whose parent check refuses a
symlinked parent before HM's native linking. `files-apply` is generated only for
a nonempty plan. Backend lowering validates and lowers their union with the
caller's `ai.activation` graph; the generated entries are not option definitions
that a whole-option priority override can remove. A caller key colliding with a
reserved name fails evaluation, whether or not that entry is emitted: both
backends reserve `files-apply` and `files-prune`, and devenv also reserves
`files-guard`, `files-inspect` and `files-snapshot`. Generated entries have
`runWhenDisabled = true`. Prune has `after = []; before = ["linkCheck"];`; apply
has `after = ["files"]` plus `"secrets"` when any enabled entry uses
`content.run`. Apply also depends directly on prune and, when emitted, the
devenv native guard; devenv refuses a dependency on an absent task. The internal
`materialized` point depends on apply. These reserved entries and their names
cannot be overridden by callers. Content renderers execute only in apply.

The devenv guard is a third ordinary generated activation entry, between
`linkCheck` and `files`, emitted only when the plan has native links. It checks
the desired native links after cleanup and pre-link commands: accept the desired
store link, remove a stale store link, refuse regular files, special files and
non-store links, and refuse symlinked parents. Only desired native destinations
are examined; there is no native-link state in the engine. Native backends
retract their own removed links.

Devenv also generates the observer pair, `files-snapshot` and `files-inspect`,
which never deletes and never fails the shell. Both entries remain emitted with
an empty plan: inspection must still report retained paths from its ledger, and
snapshot precedes the always-present cleanup task. `files-snapshot` clears both
abstract defaults and runs before `devenv:files:cleanup`: it copies the owned
paths of devenv's previous link list into
`$DEVENV_STATE/ai-delivery-observed.json`. `files-inspect` runs after
`materialized` with devenv `showOutput`, because devenv hides a passing task's
output. It warns for an owned link that is absent or replaced by a file, a
directory or a stale link, and for a remembered path no longer delivered where
the store link it delivered is still on disk, which cleanup should have removed.
A remembered path that is absent, or holds anything else, is the user's and is
forgotten silently: devenv only ever wrote that store link there. Ownership is
the normalized plan, each path named by its `ai.claims.path` claim or else
`ai.files`. Native links come from the backend file map.
