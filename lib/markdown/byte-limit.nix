# The generated tree's install check runs byteLimitCheck on every limited file.
# Launch-time Codex truncation checks live with its launcher, not this guard.
pkgs: let
  # The script is shared with the fixture check. Its one
  # external command, `wc`, is referenced by store path, so it never relies on
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
in {
  inherit byteLimitCheck;
}
