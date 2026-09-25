# Reuse a Semble entry point's interpreter and complete Python path, then
# append a script. The wrapped entry point's first three lines are its
# interpreter shebang and the site setup that puts Semble's whole Python
# closure on the path, so the script imports exactly the modules Semble does,
# without rebuilding or wrapping anything. `package` is any Semble build
# (patched or upstream).
pkgs: name: package: script:
pkgs.runCommand "semble-script-${name}" {} ''
  ${pkgs.coreutils}/bin/head -n 3 ${package}/bin/.semble-wrapped > "$out"
  ${pkgs.coreutils}/bin/cat ${script} >> "$out"
  ${pkgs.coreutils}/bin/chmod +x "$out"
''
