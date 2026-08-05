# Shared strategy-driven file materializer.
#
# Consumes a `{ <name> = { text, source, strategy }; }` attrset (see
# `fileEntryType`) plus a target directory, and emits per-backend
# writers. Two surfaces use it today — `ai.kiro.steeringFiles` (both
# strategies) and the Kiro hooks surface (copy only; v3 drops symlinked
# hooks) — so caller-facing messages take an explicit `surface` label
# rather than saying "steering".
#
# The writers emit:
#
#   - strategy = "symlink" → exactly the legacy declarative shapes
#     (HM `home.file`, devenv `files.*`) via `mkSymlinkEntries`.
#   - strategy = "copy"    → REAL files written by generated shell:
#     HM via a two-phase activation pair ([B4]: prune entryBefore
#     ["checkLinkTargets"], write entryAfter ["linkGeneration"]),
#     devenv via a task ordered before `devenv:enterShell` (and before
#     `devenv:files` when that task exists — the edge must be
#     conditional, the runner hard-errors on dangling refs).
#
# Lifecycle: a manifest (`<name>\t<sha256-of-what-we-wrote>` per line)
# lives OUTSIDE the scanned dir (HM: XDG state; devenv: $DEVENV_STATE)
# and is rewritten atomically once per run. Every destructive path runs
# the clobber guard (see the state table in
# docs/plans/factory-materializer-design.md §3): symlinks are never user
# content and are replaced/deleted; user-edited and foreign regular
# files are backed up (per-slug, outside the working tree) + warned
# before being touched; non-regular targets are a loud error and are
# never clobbered. Stale temps carrying the RESERVED `.nat-tmp.` infix
# are the ONE non-manifest deletion class ([B8]).
#
# State slugs derive from the target dir (`mkStateSlug`) so distinct
# surfaces get distinct manifests per backend; multi-surface callers
# must keep (backend, targetDir) pairs distinct — the sanitization maps
# `/` and unsafe chars to `-`, so exotic sibling dirs that sanitize
# identically (".kiro/steering" vs ".kiro.steering") would collide and
# must pass an explicit `stateSlug` instead.
{lib}: let
  inherit (import ./ai-common.nix {inherit lib;}) scopedActivation;
in rec {
  # ── Name safety ─────────────────────────────────────────────────────
  # Same charset as mkKiro's hook-name assertion: names are interpolated
  # into shell words, target paths, grep patterns, and the temp-sweep
  # glob. Leading alphanumeric bars dotfiles (the sweep's safety proof).
  nameRegex = "[A-Za-z0-9][A-Za-z0-9._-]*";
  nameSafe = name: builtins.match nameRegex name != null;

  # Derive a state slug from a target dir: keep [A-Za-z0-9._-], map the
  # rest (incl. `/`) to `-`, strip leading punctuation so the result
  # satisfies `nameSafe` (".kiro/steering" → "kiro-steering").
  mkStateSlug = targetDir: let
    mapped =
      lib.stringAsChars
      (c:
        if builtins.match "[A-Za-z0-9._-]" c != null
        then c
        else "-")
      targetDir;
    stripped = builtins.head (builtins.match "[._-]*(.*)" mapped);
  in
    if nameSafe stripped
    then stripped
    else throw "materialize.mkStateSlug: cannot derive a safe state slug from targetDir '${targetDir}'";

  # ── Entry shape ─────────────────────────────────────────────────────
  # [B1] `text` is `nullOr str`, NOT `lines`: str merges via
  # mergeEqualOption, so two emitters defining the same key with
  # DIFFERENT content is a hard eval error, and equal content dedupes.
  # [B2] `strategy` has NO default here — the shared options block is
  # inert data with no `config` access, so every emitter must stamp
  # `strategy = cfg.<surface>Strategy` explicitly. Colliding emitters
  # therefore always agree on strategy; collisions surface on `text`.
  fileEntryType = lib.types.submodule {
    options = {
      text = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Inline file content (exactly one of `text`/`source`).";
      };
      source = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Source path (exactly one of `text`/`source`). Only meaningful
          for `strategy = "symlink"`; copy-mode emitters normalize paths
          to `text` at eval. Documented pure-path (fixture/flake files),
          not derivation outputs — `builtins.readFile` on a drv output
          is IFD.
        '';
      };
      strategy = lib.mkOption {
        type = lib.types.enum ["copy" "symlink"];
        description = "Delivery mechanism for this entry (stamped explicitly by every emitter; no default).";
      };
    };
  };

  # ── Entry helpers ───────────────────────────────────────────────────
  copyEntries = lib.filterAttrs (_: e: e.strategy == "copy");
  symlinkEntries = lib.filterAttrs (_: e: e.strategy == "symlink");

  # Normalized content of a copy entry (writer contract: accepts either
  # field; `source` is read at eval — pure paths only, see above).
  entryContent = entry:
    if entry.text != null
    then entry.text
    else builtins.readFile entry.source;

  # The heredoc write appends exactly one trailing newline, so the body
  # embeds content minus a single trailing newline (byte-preserving for
  # newline-terminated content; newline-normalizing otherwise).
  stripTrailingNewline = s:
    if lib.hasSuffix "\n" s
    then lib.removeSuffix "\n" s
    else s;

  # ── Eval assertions (both backends) ────────────────────────────────
  # `surface` names the option surface in the message and has NO default:
  # two surfaces ride this now, and a wrong-but-plausible "steering" in a
  # hooks diagnostic sends the reader to the wrong option.
  mkEntryAssertions = {
    app,
    surface,
    files,
  }: let
    badShape =
      builtins.attrNames
      (lib.filterAttrs (_: e: (e.text == null) == (e.source == null)) files);
    # §4: copy-mode names only — symlink entries keep the legacy
    # freedom (the regex gates only what the generated shell touches).
    badNames =
      builtins.filter (n: !nameSafe n)
      (builtins.attrNames (copyEntries files));
  in [
    {
      assertion = badShape == [];
      message = "ai.${app}: ${surface} entries must set exactly one of `text`/`source`; offending: ${lib.concatStringsSep ", " badShape}";
    }
    {
      assertion = badNames == [];
      message = "ai.${app}: copy-strategy ${surface} file names must match ${nameRegex} (they are interpolated into shell words, target paths, and the temp-sweep pattern); offending: ${lib.concatStringsSep ", " badNames}";
    }
  ];

  # ── Symlink writer (legacy shapes, shared by both backends) ────────
  mkSymlinkEntries = {
    files,
    targetDir,
  }:
    lib.mapAttrs' (name: entry:
      lib.nameValuePair "${targetDir}/${name}" (
        if entry.text != null
        then {inherit (entry) text;}
        else {inherit (entry) source;}
      ))
    (symlinkEntries files);

  # ── Script fragments (internal) ────────────────────────────────────
  # Shared prologue: strict mode, path/state vars, backup helper. The
  # NAT_MAT_* vars and nat_mat_* helpers are defined-before-use inside
  # every generated script, so concatenated activation snippets from
  # multiple surfaces cannot observe each other's values.
  mkPrologue = {
    targetDirExpr,
    stateDirExpr,
    stateSlug,
    coreutils,
  }: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    NAT_MAT_TARGET_DIR="${targetDirExpr}"
    NAT_MAT_STATE_DIR="${stateDirExpr}"
    NAT_MAT_MANIFEST="$NAT_MAT_STATE_DIR/${stateSlug}.manifest"
    NAT_MAT_BACKUP_DIR="$NAT_MAT_STATE_DIR/${stateSlug}.bak"
    NAT_MAT_TAB="$(printf '\t')"
    NAT_MAT_ERRORS=0
    ${coreutils}/bin/mkdir -p "$NAT_MAT_TARGET_DIR" "$NAT_MAT_STATE_DIR"
    nat_mat_backup() {
      ${coreutils}/bin/mkdir -p "$NAT_MAT_BACKUP_DIR"
      # mktemp guarantees uniqueness even for same-second backups of the
      # same file (epoch kept so backups sort by time); cp -p then
      # stamps the source's mode/times onto the reserved path.
      nat_mat_bak="$(${coreutils}/bin/mktemp "$NAT_MAT_BACKUP_DIR/$1.$(${coreutils}/bin/date +%s).XXXXXX")"
      ${coreutils}/bin/cp -pf -- "$NAT_MAT_TARGET_DIR/$1" "$nat_mat_bak"
    }
  '';

  # Loud-error epilogue. `false` (not `exit`) so the failure propagates
  # through the caller's `set -e` without truncating a concatenated HM
  # activation script the way `exit` would.
  mkEpilogue = stateSlug: ''
    if [ "$NAT_MAT_ERRORS" != 0 ]; then
      echo "ERROR: materialize(${stateSlug}): unresolved target conflicts (see messages above)" >&2
      false
    fi
  '';

  # [B8] Stale-temp sweep — the ONE declared non-manifest deletion
  # class: dot-prefixed files carrying the RESERVED `.nat-tmp.` infix.
  # The infix, not the name shape, is the safety proof: a bare
  # `.<name>.*` pattern would eat user dotfiles (a vim `.foo.md.swp`, a
  # `.a.md.notes`), whereas no managed name (regex bars leading dots)
  # and essentially no user file carries `.nat-tmp.`. Also sweeps the
  # state dir (manifest temps use the same infix).
  mkSweep = coreutils: ''
    for nat_mat_f in "$NAT_MAT_TARGET_DIR"/.*".nat-tmp."* "$NAT_MAT_STATE_DIR"/.*".nat-tmp."*; do
      if [ -f "$nat_mat_f" ]; then ${coreutils}/bin/rm -f -- "$nat_mat_f"; fi
    done
  '';

  # Prune pass: delete every name in the PREVIOUS manifest that is NOT
  # in the current copy-set ([B4]: previousManifest ∖ currentCopySet —
  # covers entry removed, entry flipped to symlink, surface emptied; a
  # flipped name MUST be pruned so link generation can take the path
  # over cleanly). Applies the clobber guard on every deletion.
  mkPruneCore = {
    currentNames,
    stateSlug,
    coreutils,
  }: let
    keepCase = lib.optionalString (currentNames != []) ''
      case "$nat_mat_name" in
            ${lib.concatMapStringsSep "|" lib.escapeShellArg currentNames}) continue ;;
          esac
    '';
  in ''
    if [ -f "$NAT_MAT_MANIFEST" ]; then
      while IFS="$NAT_MAT_TAB" read -r nat_mat_name nat_mat_prev; do
        [ -n "$nat_mat_name" ] || continue
        case "$nat_mat_name" in
          */* | . | .. | .*)
            echo "WARNING: materialize(${stateSlug}): ignoring suspicious manifest entry '$nat_mat_name'" >&2
            continue
            ;;
        esac
        ${keepCase}
        nat_mat_target="$NAT_MAT_TARGET_DIR/$nat_mat_name"
        if [ -L "$nat_mat_target" ]; then
          # a symlink is never user content — old delivery, remove
          ${coreutils}/bin/rm -f -- "$nat_mat_target"
        elif [ ! -e "$nat_mat_target" ]; then
          : # already gone
        elif [ ! -f "$nat_mat_target" ]; then
          echo "ERROR: materialize(${stateSlug}): $nat_mat_target is not a regular file or symlink; leaving it in place" >&2
          NAT_MAT_ERRORS=1
        else
          nat_mat_disk="$(${coreutils}/bin/sha256sum -- "$nat_mat_target" | ${coreutils}/bin/cut -d ' ' -f 1)"
          if [ "$nat_mat_disk" != "$nat_mat_prev" ]; then
            nat_mat_backup "$nat_mat_name"
            echo "WARNING: materialize(${stateSlug}): $nat_mat_target was edited since it was materialized; backed up to $NAT_MAT_BACKUP_DIR" >&2
          fi
          ${coreutils}/bin/rm -f -- "$nat_mat_target"
        fi
      done < "$NAT_MAT_MANIFEST"
    fi
  '';

  # Write pass: per-file atomic mktemp+mv with the clobber guard, then
  # one atomic manifest rewrite. Content rides quoted heredocs whose
  # per-script EOF marker derives from the content hash, so no embedded
  # body can terminate its own heredoc.
  mkWriteCore = {
    files, # copy entries only
    stateSlug,
    coreutils,
    diffutils,
    gnugrep,
  }: let
    names = builtins.attrNames files;
    marker = "NAT_MAT_${builtins.substring 0 16 (
      builtins.hashString "sha256" (
        builtins.unsafeDiscardStringContext
        (lib.concatMapStrings (n: entryContent files.${n}) names)
      )
    )}_EOF";
    fnDefs = ''
      NAT_MAT_NEW_MANIFEST="$(${coreutils}/bin/mktemp "$NAT_MAT_STATE_DIR/.${stateSlug}.manifest.nat-tmp.XXXXXX")"
      nat_mat_write() {
        nat_mat_name="$1"
        nat_mat_prev="$2"
        nat_mat_target="$NAT_MAT_TARGET_DIR/$nat_mat_name"
        nat_mat_tmp="$(${coreutils}/bin/mktemp "$NAT_MAT_TARGET_DIR/.$nat_mat_name.nat-tmp.XXXXXX")"
        ${coreutils}/bin/cat > "$nat_mat_tmp"
        # D3 guardrail: managed copies land read-only (0444) so a casual
        # agent edit bounces; mv-replacement ignores target-file perms,
        # so our own updates and prunes still work.
        ${coreutils}/bin/chmod 444 "$nat_mat_tmp"
        if [ -L "$nat_mat_target" ]; then
          # -L before cmp (constraint 9): a symlink is never user
          # content; cmp-skipping an identical-content symlink would
          # reinstate the v3 skips-symlinks defect.
          ${coreutils}/bin/rm -f -- "$nat_mat_target"
        elif [ ! -e "$nat_mat_target" ]; then
          : # fresh write
        elif [ ! -f "$nat_mat_target" ]; then
          echo "ERROR: materialize(${stateSlug}): $nat_mat_target is not a regular file or symlink; refusing to clobber" >&2
          ${coreutils}/bin/rm -f -- "$nat_mat_tmp"
          NAT_MAT_ERRORS=1
          return 0
        else
          nat_mat_disk="$(${coreutils}/bin/sha256sum -- "$nat_mat_target" | ${coreutils}/bin/cut -d ' ' -f 1)"
          if [ -n "$nat_mat_prev" ] && [ "$nat_mat_disk" = "$nat_mat_prev" ]; then
            if ${diffutils}/bin/cmp -s -- "$nat_mat_tmp" "$nat_mat_target"; then
              # ours + unchanged: skip (no mtime churn)
              ${coreutils}/bin/rm -f -- "$nat_mat_tmp"
              printf '%s\t%s\n' "$nat_mat_name" "$nat_mat_disk" >> "$NAT_MAT_NEW_MANIFEST"
              return 0
            fi
          elif [ -n "$nat_mat_prev" ]; then
            nat_mat_backup "$nat_mat_name"
            echo "WARNING: materialize(${stateSlug}): $nat_mat_target was edited since it was materialized; backed up to $NAT_MAT_BACKUP_DIR; overwriting" >&2
          else
            nat_mat_backup "$nat_mat_name"
            echo "WARNING: materialize(${stateSlug}): $nat_mat_target existed but was not managed; backed up to $NAT_MAT_BACKUP_DIR; adopting" >&2
          fi
        fi
        ${coreutils}/bin/mv -f -- "$nat_mat_tmp" "$nat_mat_target"
        printf '%s\t%s\n' "$nat_mat_name" "$(${coreutils}/bin/sha256sum -- "$nat_mat_target" | ${coreutils}/bin/cut -d ' ' -f 1)" >> "$NAT_MAT_NEW_MANIFEST"
      }
    '';
    # One block per entry: recorded-hash lookup (grep `|| :`-guarded —
    # first run has no manifest; dots regex-escaped for exact match),
    # then the guarded write fed by a quoted heredoc (delimiters at
    # column 0 via explicit \n concatenation, which the HM subshell
    # wrapping does not disturb).
    entryBlock = name: entry: let
      regexName = lib.replaceStrings ["."] ["\\."] name;
    in
      "nat_mat_prev=\"\"\n"
      + "if [ -f \"$NAT_MAT_MANIFEST\" ]; then\n"
      + "  nat_mat_prev=\"$(${gnugrep}/bin/grep -m 1 -e \"^${regexName}$NAT_MAT_TAB\" \"$NAT_MAT_MANIFEST\" | ${coreutils}/bin/cut -f 2-)\" || :\n"
      + "fi\n"
      + "nat_mat_write ${lib.escapeShellArg name} \"$nat_mat_prev\" <<'${marker}'\n"
      + stripTrailingNewline (entryContent entry)
      + "\n${marker}\n";
  in
    fnDefs
    + lib.concatStrings (lib.mapAttrsToList entryBlock files)
    + ''
      ${coreutils}/bin/mv -f -- "$NAT_MAT_NEW_MANIFEST" "$NAT_MAT_MANIFEST"
    '';

  # ── HM copy writer: two-phase activation pair [B4] ─────────────────
  #
  # Phase A (prune) runs entryBefore ["checkLinkTargets"]: pruning a
  # copy→symlink flip BEFORE the check leaves a clean path for HM to
  # link — no "Existing file … is in the way" abort, no `force = true`
  # (constraint 1), no linkNewGen adoption trap. Phase B (write) runs
  # entryAfter ["linkGeneration"] (constraint 5).
  #
  # Callers must emit these entries whenever the module is enabled —
  # NOT gated on a non-empty file set ([B6-partial]) — so emptying the
  # surface still prunes everything (N→0).
  mkHmActivation = {
    files,
    targetDir,
    stateSlug,
    coreutils,
    diffutils,
    gnugrep,
  }:
    assert lib.assertMsg (nameSafe stateSlug)
    "materialize: stateSlug must match ${nameRegex}: '${stateSlug}'"; let
      copies = copyEntries files;
      common = {
        inherit stateSlug coreutils;
        targetDirExpr = "$HOME/${targetDir}";
        stateDirExpr = "\${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/materialize";
      };
    in {
      "materialize-${stateSlug}-prune" = lib.hm.dag.entryBefore ["checkLinkTargets"] (
        scopedActivation (
          mkPrologue common
          + mkSweep coreutils
          + mkPruneCore {
            inherit stateSlug coreutils;
            currentNames = builtins.attrNames copies;
          }
          + mkEpilogue stateSlug
        )
      );
      "materialize-${stateSlug}-write" = lib.hm.dag.entryAfter ["linkGeneration"] (
        scopedActivation (
          mkPrologue common
          + mkWriteCore {
            inherit stateSlug coreutils diffutils gnugrep;
            files = copies;
          }
          + mkEpilogue stateSlug
        )
      );
    };

  # ── devenv copy writer: one prune+write task [B4] ──────────────────
  #
  # `after = ["devenv:files:cleanup"]` and the CONDITIONAL
  # `before = [... "devenv:files"]` edge order the prune before devenv
  # creates `files.*` symlinks (a flipped name's real file would
  # otherwise trigger createFileScript's silent "Conflicting file"
  # skip). The `devenv:files` edge MUST be conditional: on the pinned
  # devenv, `tasks."devenv:files"` exists only when `config.files != {}`
  # and the runner hard-errors (TasksNotFound) on a dangling ref; the
  # unconditional `devenv:enterShell` edge alone then guarantees
  # write-before-shell. (Task names verified against the pinned devenv
  # rev; they are undocumented internals — re-check on pin bumps.)
  #
  # Callers must emit the task whenever the module is enabled (N→0
  # prunes on devenv too).
  mkDevenvTask = {
    files,
    targetDir,
    stateSlug,
    hasFiles, # config.files != {} at the call site
    coreutils,
    diffutils,
    gnugrep,
  }:
    assert lib.assertMsg (nameSafe stateSlug)
    "materialize: stateSlug must match ${nameRegex}: '${stateSlug}'"; let
      copies = copyEntries files;
      common = {
        inherit stateSlug coreutils;
        targetDirExpr = "$DEVENV_ROOT/${targetDir}";
        stateDirExpr = "$DEVENV_STATE/nix-agentic-tools/materialize";
      };
    in {
      exec =
        mkPrologue common
        + ''
          cd "$DEVENV_ROOT"
        ''
        + mkSweep coreutils
        + mkPruneCore {
          inherit stateSlug coreutils;
          currentNames = builtins.attrNames copies;
        }
        + mkWriteCore {
          inherit stateSlug coreutils diffutils gnugrep;
          files = copies;
        }
        + mkEpilogue stateSlug;
      after = ["devenv:files:cleanup"];
      before = ["devenv:enterShell"] ++ lib.optional hasFiles "devenv:files";
    };

  # ── devenv consumer backstop [B7] ──────────────────────────────────
  # An enterTest fragment asserting every copy entry exists as a REAL
  # file: a failed materialize task only warns at shell entry; this
  # makes `devenv test`/CI fail. Ships WITH the module to every
  # consumer. (`exit 1` matches devenv enterTest convention — this is a
  # test script, not an HM activation block.)
  mkEnterTest = {
    app,
    files,
    targetDir,
  }: let
    copies = copyEntries files;
  in
    lib.concatMapStrings (name: ''
      if [ ! -f "$DEVENV_ROOT/${targetDir}/${name}" ] || [ -L "$DEVENV_ROOT/${targetDir}/${name}" ]; then
        echo "FAIL: ai.${app}: ${targetDir}/${name} is not materialized as a real file" >&2
        exit 1
      fi
    '') (builtins.attrNames copies);
}
