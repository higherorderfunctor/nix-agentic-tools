# Go/Rust release checks and their controls share the same ordering assertion.
{
  dependencyFixer,
  orderExplanation ? "Record the source version before dependency hashing forces its compiler.",
  pkgs,
  requireSrc ? false,
  versionFixer,
  versionLabel ? versionFixer,
}: ''
  line_of() {
    ${pkgs.gnugrep}/bin/grep -n -F -- "$1" "$2" \
      | ${pkgs.coreutils}/bin/head -n1 \
      | ${pkgs.coreutils}/bin/cut -d: -f1
  }

  assert_chain_order() {
    local chain="$1" label="$2" version dependency src

    version=$(line_of "-fix-${versionFixer}-" "$chain" || :)
    dependency=$(line_of "-fix-${dependencyFixer}-" "$chain" || :)
    src=$(line_of "-fix-src-" "$chain" || :)

    if [ -z "$version" ]; then
      echo "FAIL: $label: no ${versionLabel} fixer in its extract chain" >&2
      cat "$chain" >&2
      return 1
    fi
    if [ -z "$dependency" ]; then
      echo "FAIL: $label: no ${dependencyFixer} fixer in its extract chain" >&2
      cat "$chain" >&2
      return 1
    fi
    if [ "$version" -ge "$dependency" ]; then
      echo "FAIL: $label: ${versionLabel} fixer (line $version) does not precede the ${dependencyFixer} fixer (line $dependency)." >&2
      echo ${pkgs.lib.escapeShellArg orderExplanation} >&2
      cat "$chain" >&2
      return 1
    fi
    if { ${builtins.toJSON requireSrc} && [ -z "$src" ]; } || { [ -n "$src" ] && [ "$src" -ge "$version" ]; }; then
      echo "FAIL: $label: source hash repair must precede ${versionFixer} extraction" >&2
      echo "The ${versionLabel} fixer builds .src, so a sidecar-held srcHash must be restored first." >&2
      cat "$chain" >&2
      return 1
    fi
    echo "ok — $label: src=''${src:-prefetched} ${versionFixer}=$version ${dependencyFixer}=$dependency"
  }
''
