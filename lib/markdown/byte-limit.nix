# The two byte-limit programs: `byteLimitCheck`, which the generated tree's
# install check runs on each limited file (lib/generated.nix), and `windowNotice`,
# which devenv's shell entry runs on the project's AGENTS.md
# (lib/ai/app/sharedAgentsMd.nix). They live apart from generated-file exports
# exports so nothing public exists only for the check that executes them
# (checks/markdown/markdown-byte-limit-scripts.nix).
pkgs: let
  # Both byte-limit programs are scripts rather than inline shell so the
  # checks execute exactly what the tree and the devenv shell run. Their one
  # external command, `wc`, is referenced by store path, so neither relies on
  # the caller's PATH.
  strictShellApplication = import ../strict-shell-application.nix pkgs;

  # `FILE BYTES LABEL HINT`: fails when FILE is larger than BYTES. A reader
  # that silently drops everything past its limit is the reason to fail the
  # build instead of shipping the file.
  byteLimitCheck = strictShellApplication {
    name = "ai-markdown-byte-limit";
    text = ''
      if [ "$#" -ne 4 ]; then
        echo "usage: ai-markdown-byte-limit FILE BYTES LABEL HINT" >&2
        exit 2
      fi
      file=$1
      limit=$2
      label=$3
      hint=$4
      size=$(${pkgs.coreutils}/bin/wc -c <"$file")
      if [ "$size" -gt "$limit" ]; then
        echo "$label: $file renders to $size bytes, exceeding its limit ($limit bytes). $hint" >&2
        exit 1
      fi
    '';
  };

  # `FILE BYTES READER RESOLVER`: one warning on stderr when FILE is larger
  # than RESOLVER reports READER will take, and silence otherwise, including
  # when FILE does not exist. A failed or invalid resolution uses BYTES.
  windowNotice = strictShellApplication {
    name = "ai-markdown-window-notice";
    text = ''
      if [ "$#" -ne 4 ]; then
        echo "usage: ai-markdown-window-notice FILE BYTES READER RESOLVER" >&2
        exit 2
      fi
      file=$1
      limit=$2
      reader=$3
      resolver=$4
      [ -f "$file" ] || exit 0
      size=$(${pkgs.coreutils}/bin/wc -c <"$file")
      resolved="$("$resolver" "$(${pkgs.coreutils}/bin/dirname "$file")" "$limit" 2>/dev/null || :)"
      if [[ "$resolved" =~ ^[0-9]+$ ]]; then
        limit=$resolved
      fi
      if [ "$size" -gt "$limit" ]; then
        echo "warning: $file is $size bytes; $reader reads only the first $limit bytes with its current configuration. Raise the limit in $reader, or shrink the always-loaded content." >&2
      fi
    '';
  };
in {
  inherit byteLimitCheck windowNotice;
}
