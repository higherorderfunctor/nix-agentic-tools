# shellcheck shell=bash
#
# Shared helpers for the mode-F harness. Source this; do not execute it.
#
# Everything here is bash-only on purpose. `shopt` is not a zsh builtin, and
# bash's `nullglob` makes a non-matching glob expand to nothing where zsh
# instead treats it as a hard error — which has already produced one misleading
# result in this corpus. Sourcing from zsh is refused below rather than left to
# misbehave later.
#
# ISOLATION: the lever is HOME, never KIRO_HOME.
#
#   The engine composes its session root as join(homeDir, ".kiro", "sessions")
#   with homeDir = getCliArg("home-dir") ?? os.homedir(), and the Rust launcher
#   spawns the engine with exactly --transport=stdio --auth=acp-callback — it
#   never passes --home-dir. So homeDir is unconditionally $HOME. KIRO_HOME has
#   zero occurrences in the engine bundle, and in the native CLI/TUI layer it
#   means the path OF the .kiro directory itself, not a home directory. Setting
#   it would point this harness at a directory the engine never reads, and the
#   symptom would be a silent "the flag didn't work".
#
#   XDG_DATA_HOME is deliberately left REAL. Redirecting it creates an empty
#   credential database, and the CLI's response to no cached token is an
#   INTERACTIVE BROWSER LOGIN, not an error. That also means this harness cannot
#   run on a machine that has never logged in — a precondition, not a bug.

# This file is source-only, so a bare `return` is the correct refusal. zsh also
# honors `return` in a sourced file, which is what makes the check able to
# reject the shell it is warning about.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "harness/lib.sh requires bash (see the header)" >&2
  return 1
fi

# ---------------------------------------------------------------------------
# Bundle resolution
# ---------------------------------------------------------------------------

# Resolve the live KAS bundle by the CLI's own version, asserting exactly one
# match. Several engine versions accumulate side by side and a naive glob picks
# the wrong one silently: lexical-FIRST selects a bundle six releases behind,
# while lexical-last and newest-by-mtime happen to be correct today, which is
# what makes the naive form dangerous rather than merely wrong.
#
# Prints "<kasid>\t<bundle-path>".
kiro_resolve_bundle() {
  local ver kas bundle
  ver="$(kiro-cli --version | awk '{print $NF}')"

  local -a kasdirs=()
  local nullglob_was_set=0
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  kasdirs=("$HOME/.local/share/kiro-cli/kas/${ver}-"*/)
  [ "$nullglob_was_set" -eq 1 ] || shopt -u nullglob

  if [ "${#kasdirs[@]}" -ne 1 ]; then
    echo "ambiguous engine bundle for ${ver} - refuse (found ${#kasdirs[@]})" >&2
    return 1
  fi

  kas="${kasdirs[0]}"
  bundle="${kas}node_modules/@kiro/agent/dist/server/acp-server.js"
  if [ ! -f "$bundle" ]; then
    echo "engine bundle missing at ${bundle}" >&2
    return 1
  fi

  printf '%s\t%s\n' "$(basename "${kas%/}")" "$bundle"
}

# ---------------------------------------------------------------------------
# Workspace bucket derivation
# ---------------------------------------------------------------------------

# Derive the 16-hex session bucket directory name from a workspace path set.
#
#   bucket = sha256( paths.map(normalize).sort().join(NUL) ).hex[0:16]
#   bucket = "_global"  iff the path set is empty
#
# NORMALIZATION IS TREATED AS IDENTITY HERE, deliberately. The engine
# normalizes each path first; this harness only ever passes absolute, symlink-
# free paths with no trailing slash and no "." or ".." component, for which
# normalization is a no-op. self-test-bucket.sh is what keeps that assumption
# honest — it reproduces every real bucket on the machine from that session's
# own recorded workspacePaths, so a normalization the harness got wrong would
# show up as a mismatch there rather than as a mis-seeded fixture later.
kiro_bucket() {
  if [ "$#" -eq 0 ]; then
    printf '%s' '_global'
    return 0
  fi
  # Python rather than a coreutils pipeline, because the obvious pipeline is
  # GNU-only in THREE separate places and this repo builds aarch64-darwin:
  # `sort -z` does not exist in BSD sort, `head -c -1` rejects a negative count
  # in BSD head, and `sha256sum` is not shipped by macOS at all (it is
  # `shasum -a 256` there). Any one of them is enough to make every fixture
  # unable to compute a bucket name.
  #
  # The bytes hashed are identical to that pipeline's: the paths sorted, joined
  # with NUL, and NOT NUL-terminated. Sorting the ENCODED paths is what keeps it
  # identical -- `LC_ALL=C sort` orders by byte, while Python's default sort
  # orders decoded strings by code point, and the two only coincide for ASCII.
  # `os.fsencode` round-trips arbitrary path bytes, so a path that is not valid
  # UTF-8 still hashes rather than raising.
  #
  # `self-test-bucket.sh` is the control: it re-derives every real bucket on this
  # machine from its own recorded workspacePaths, so a change here that altered
  # the hash would show up as a mismatch rather than as a mis-seeded fixture.
  python3 -c '
import hashlib, os, sys
parts = sorted(os.fsencode(a) for a in sys.argv[1:])
sys.stdout.write(hashlib.sha256(b"\0".join(parts)).hexdigest()[:16])
' "$@"
}

# Absolute path of a seeded session's directory, given the scratch HOME, the
# session id, and the workspace path set.
kiro_session_dir() {
  local scratch_home="$1" session_id="$2"
  shift 2
  printf '%s/.kiro/sessions/%s/%s' \
    "$scratch_home" "$(kiro_bucket "$@")" "$session_id"
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

# Refuse to operate on anything that is not inside the scratch root. Every
# destructive helper routes through this: the harness deletes directories, and
# a bug in a path variable must not be able to reach the operator's real state.
kiro_assert_under_scratch() {
  local target="$1" scratch_root="$2"
  case "$target" in
  "$scratch_root" | "$scratch_root"/*) ;;
  *)
    echo "refusing: '${target}' is not under scratch root '${scratch_root}'" >&2
    return 1
    ;;
  esac
  # A scratch root that resolves to $HOME, /, or an ancestor of the real
  # ~/.kiro is a configuration error, not a target.
  case "$scratch_root" in
  "" | "/" | "$HOME")
    echo "refusing: scratch root '${scratch_root}' is unsafe" >&2
    return 1
    ;;
  esac
}

# Refuse if a path is a symlink where the engine requires a real entry.
#
# Two loaders disagree and the difference is load-bearing in both directions:
#
#   - HOOK files: the directory reader types a symlink as its own kind and the
#     loader keeps only plain files, so a symlinked hook is SILENTLY skipped —
#     no warning, no log line, no error.
#   - SESSION and BUCKET directories: the listing code filters on
#     Dirent.isDirectory(), which is false for a symlink, so a symlinked
#     session vanishes from --resume / --resume-picker / --list-sessions while
#     staying reachable by --resume-id. A split symptom, which is the shape
#     that produced a wrong conclusion in this corpus once already.
#
# AGENT profile files are exempt: that loader follows symlinks and recurses.
# Do not carry this check across to them.
kiro_assert_real() {
  local p="$1"
  if [ -L "$p" ]; then
    echo "refusing: '${p}' is a symlink where the engine requires a real entry" >&2
    return 1
  fi
  if [ ! -e "$p" ]; then
    echo "refusing: '${p}' does not exist" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Log assertions
# ---------------------------------------------------------------------------

# Newest engine log under a given HOME. Every engine start writes
# "Initializing persistence at <path>", which names the resolved session root
# unambiguously — that line is the only trustworthy confirmation that a HOME
# redirect actually took, so it is what the harness reads instead of inferring.
kiro_newest_log() {
  local scratch_home="$1" newest
  # Sorted LEXICALLY by path, not by mtime. The engine names its log directories
  # with a timestamp, so lexical order IS chronological order — and that avoids
  # both `find -printf` (GNU-only, absent on darwin) and any reliance on mtime,
  # which this corpus has already been burned by: a file's mtime can advance for
  # reasons unrelated to the thing being measured.
  newest="$(find "$scratch_home/.kiro/logs" -name 'kiro.log' -type f 2>/dev/null |
    LC_ALL=C sort | tail -1)"
  if [ -z "$newest" ]; then
    echo "no kiro.log under ${scratch_home}/.kiro/logs" >&2
    return 1
  fi
  printf '%s\n' "$newest"
}

# The resolved session root, read out of the log rather than assumed.
kiro_logged_session_root() {
  local log="$1"
  grep -oE 'Initializing persistence at [^"]+' "$log" |
    tail -1 | sed 's/^Initializing persistence at //'
}
