# A corpus scan, not a changed-files scan: a gate that only looks at the diff
# cannot notice that the tree behind it grew a new direct write.
# The corpus stays the factory libraries until chunk 13 moves non-AI owners'
# module-level tasks through layer 1.
{pkgs, ...}: {
  checks.ai-module-no-direct-sink-writes =
    pkgs.runCommandLocal "ai-module-no-direct-sink-writes" {
      src = ../../..;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      # The source is a read-only store path, so artifacts land in the build
      # directory while the scan itself runs with repo-relative paths.
      work="$PWD"
      cd "$src"

      # An assignment to one of the native sinks, at the start of a line.
      # `files`, `tasks` and `enterTest` are matched bare because that is how
      # a devenv fragment writes them. `enterTest` is here because a writer's
      # verification is as much a sink write as the writer itself: a factory
      # that emitted one directly would keep a second way, outside ai-module,
      # to make `devenv test` fail.
      anchored='^[[:space:]]*(home\.file|home\.activation|files|tasks|enterTest)([."[]|[[:space:]]*=)'
      # The nested form: a `home = {` block whose body writes `file` and
      # `activation` at a depth the anchored pattern cannot see. Flagging the
      # block itself is a forbidden direct sink owner.
      nested='^[[:space:]]*home[[:space:]]*=[[:space:]]*\{'

      # packages/ai-module IS the delivery layer this gate routes factories
      # through, so it is outside the scanned factory set rather than
      # exempted line by line.
      ${pkgs.findutils}/bin/find packages -mindepth 3 -path 'packages/*/lib/*' -not -path 'packages/ai-module/*' -type f -name '*.nix' -print0 \
        | ${pkgs.coreutils}/bin/sort -z > "$work/corpus"
      # A scan of nothing exits 0 and is indistinguishable from a pass.
      ${pkgs.coreutils}/bin/test -s "$work/corpus"
      echo "scanned $(${pkgs.coreutils}/bin/tr -d -c '\0' < "$work/corpus" | ${pkgs.coreutils}/bin/wc -c) factory library files"

      # Zero direct writers, with no exemption mechanism. Distinguish grep's
      # ordinary no-match status from an unreadable or malformed corpus.
      : > "$work/actual"
      while IFS= read -r -d $'\0' path; do
        if ${pkgs.gnugrep}/bin/grep -nHE -e "$anchored" -e "$nested" "$path" >> "$work/actual"; then
          :
        else
          rc=$?
          ${pkgs.coreutils}/bin/test "$rc" -eq 1 || exit "$rc"
        fi
      done < "$work/corpus"
      if ${pkgs.coreutils}/bin/test -s "$work/actual"; then
        echo "ai-module: expected ZERO direct native sink writes; route them through ai.<owner>.files or ai.<owner>.activation." >&2
        ${pkgs.coreutils}/bin/cat "$work/actual" >&2
        exit 1
      fi

      echo "PASS: zero factory library files write a native sink directly" > "$out"
    '';
}
