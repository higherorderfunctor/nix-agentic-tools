# Reuse a Semble entry point's interpreter and complete Python path, then
# append a script. The wrapped entry point's first three lines are its
# interpreter shebang and the site setup that puts Semble's whole Python
# closure on the path, so the script imports exactly the modules Semble does,
# without rebuilding or wrapping anything. `package` is any Semble build
# or a configured launcher whose `unwrapped` is that build. The injected
# store JSON is the same one carried by the package entry points.
pkgs: name: package: script:
pkgs.runCommand "semble-script-${name}" {} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  ${pkgs.coreutils}/bin/head -n 3 ${package.unwrapped or package}/bin/.semble-wrapped > "$out"
  printf '%s\n' 'import os' 'os.environ["SEMBLE_NIX_CONFIG"] = ${builtins.toJSON (toString package.passthru.sembleConfig)}' >> "$out"
  ${pkgs.coreutils}/bin/cat ${script} >> "$out"
  ${pkgs.coreutils}/bin/chmod +x "$out"
''
