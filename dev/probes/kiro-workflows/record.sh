#!/usr/bin/env bash
# Records, verbatim, what a workflow step actually received after interpolation.
#
# Each argument is logged with its LENGTH and its literal value, separately, so
# three outcomes are distinguishable after the fact:
#   - an unresolved "{{...}}" literal   (value contains braces)
#   - a resolved value                  (non-zero length, no braces)
#   - an empty payload                  (length 0, or an envelope with nothing
#                                        inside it — see §7.3)
# Without the length, an empty captured output is invisible: the injection
# envelope arrives either way.
#
# If an argument happens to be a readable path, its content is logged too, which
# is how `{{artifacts.<name>}}` resolution was confirmed. Content gets the same
# length/value treatment and for the same reason: `$(...)` strips ALL trailing
# newlines, so CONTENT alone is not byte-exact and a file holding only newlines
# would render as an empty `<<<>>>`. CONTENT_LEN is the file's real byte count
# and is the authoritative field. Note also that a multi-line file puts real
# newlines inside the delimiters, so CONTENT is the one field that is not
# guaranteed to occupy a single line.
#
# Usage: record.sh <root> <label> [arg ...]
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

root="${1:?probe root directory required}"
label="${2:?label required}"
shift 2

mkdir -p -- "$root"
out="$root/$label-received.txt"
: >"$out"

i=0
for a in "$@"; do
  i=$((i + 1))
  # One grouped redirect rather than six individual ones (SC2129), so the file
  # is opened once. That is all it buys: the block still performs one write per
  # printf, so it is NOT an atomic append and a concurrent reader could observe a
  # partial record. Nothing here needs that property — each invocation writes its
  # own `$label`-keyed file — so the redirect is not doing safety work.
  {
    printf 'ARG%d_LEN=%s\n' "$i" "${#a}"
    printf 'ARG%d_VALUE=<<<%s>>>\n' "$i" "$a"
    # `-f` and `-r` rather than `-e`: under `set -e` (plus inherit_errexit) an
    # unreadable file or a DIRECTORY would make the `cat` below fail and kill the
    # script mid-probe, losing the records already gathered. `--` because the args
    # are interpolated data: a value beginning with "-" would become a cat option.
    if [ -f "$a" ] && [ -r "$a" ]; then
      printf 'ARG%d_IS_PATH=yes\n' "$i"
      # The byte count comes from the FILE, not from the substitution below,
      # which is the whole point: `$(...)` discards trailing newlines, so a file
      # of `\n\n\n` yields an empty CONTENT and reads exactly like an empty file
      # — the false-empty ambiguity the length fields exist to close (§7.3). `<`
      # rather than `cat` because the shell opens the path itself, so this needs
      # no `--` guard.
      printf 'ARG%d_CONTENT_LEN=%s\n' "$i" "$(wc -c <"$a" | tr -d ' ')"
      printf 'ARG%d_CONTENT=<<<%s>>>\n' "$i" "$(cat -- "$a")"
    else
      printf 'ARG%d_IS_PATH=no\n' "$i"
    fi
  } >>"$out"
done

printf '{"done":true,"args":%d}\n' "$i" >"$root/$label.json"
printf 'RECORDED %s (%d args)\n' "$label" "$i"
cat -- "$out"
