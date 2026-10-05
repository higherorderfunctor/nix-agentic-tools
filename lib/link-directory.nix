# Link whole top-level entries so delivery copies links, not package payloads.
{lib}: pkgs: name: source:
pkgs.runCommand (lib.strings.sanitizeDerivationName name) {} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  ${pkgs.coreutils}/bin/mkdir -p "$out"
  shopt -s dotglob nullglob
  for entry in "${source}"/*; do
    ${pkgs.coreutils}/bin/ln -s "$entry" "$out/$(${pkgs.coreutils}/bin/basename "$entry")"
  done
''
