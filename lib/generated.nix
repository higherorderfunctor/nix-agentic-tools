# Build one store tree per delivery-router invocation. Each formatter sees only
# its own type at the target-relative paths the runtime will receive.
{lib}: pkgs: let
  types = ["json" "markdown" "toml" "yaml"];
  style = import ./generated-style.nix;
  prettierConfig = (pkgs.formats.json {}).generate "generated-prettier.json" style.prettier;
  prettier = lib.getExe' pkgs.prettier "prettier";
  tableCells = import ./markdown/table-cells.nix {inherit pkgs;};
  inherit (import ./markdown/byte-limit.nix pkgs) byteLimitCheck;
  python = pkgs.python3.withPackages (ps: [ps.pyyaml]);
  guardReason = {
    parseCompare = "The parsed document or Markdown frontmatter changed or became invalid; the runtime could read a different configuration.";
    splitCodeSpans = "An inline code span crosses a newline; CommonMark inserts a space that can corrupt a path or identifier.";
    tableCells = "A Markdown table has inconsistent cell counts; an unescaped pipe can change or break its rendered columns.";
  };
  guardError = guard: ''
    echo "Generated-file guard ${guard} failed." >&2
    echo ${lib.escapeShellArg guardReason.${guard}} >&2
    echo "Choose one of three options:" >&2
    echo "  1. Fix the input or formatter." >&2
    echo "  2. Disable ai.generated.guards.${guard}." >&2
    echo "  3. Set this file's format to raw." >&2
    echo "See README.md: Generated-file guards." >&2
    exit 1
  '';
  formatStdin = type: command: ''
    ${pkgs.findutils}/bin/find . -type f -print0 | while IFS= read -r -d "" file; do
      formatted="$(${pkgs.coreutils}/bin/mktemp "$TMPDIR/generated-${type}.XXXXXXXX")"
      ${command}
      ${pkgs.coreutils}/bin/mv "$formatted" "$file"
    done
  '';
in rec {
  defaultFormatter = {
    json = formatStdin "json" ''
      ${lib.getExe pkgs.biome} format --stdin-file-path="$file.json" --indent-style=${style.biome.indentStyle} --indent-width=${toString style.biome.indentWidth} < "$file" > "$formatted"
    '';
    markdown = "find . -type f -print0 | xargs -0 -r ${prettier} --write --parser markdown --config ${prettierConfig}";
    toml = formatStdin "toml" ''
      ${lib.getExe pkgs.taplo} fmt --no-auto-config --stdin-filepath="$file.toml" - < "$file" > "$formatted"
    '';
    yaml = "find . -type f -print0 | xargs -0 -r ${prettier} --write --parser yaml --config ${prettierConfig}";
  };
  # A normal-priority default allows types.lines definitions to append and
  # mkForce to replace without forcing default tool references.
  defaultCheck = lib.genAttrs types (_: ":");
  mkTree = {
    check ? {},
    files,
    formatter ? {},
    guards ? {},
    maxBytes ? {},
    name,
    passthru ? {},
  }: let
    sourceOf = path: file:
      file.source or (pkgs.writeText (lib.strings.sanitizeDerivationName (baseNameOf path)) file.text);
    selected = type: lib.filterAttrs (_: file: file.type == type) files;
    withFiles = type: f: lib.concatStrings (lib.mapAttrsToList f (selected type));
    allFiles = f: lib.concatStrings (lib.mapAttrsToList f files);
    guardOn = guard: guards.${guard} or false;
    eachType = f: lib.concatStrings (map (type: lib.optionalString (selected type != {}) (f type)) types);
    parseGuard = lib.optionalString (guardOn "parseCompare") (lib.concatStrings (map (type:
      withFiles type (path: file: ''
        ${python}/bin/python3 ${./generated-guard.py} ${lib.escapeShellArgs [file.type (lib.boolToString (file.frontmatter or false)) "before/${file.type}/${path}"]} "$out"/${lib.escapeShellArg path} || {
          ${guardError "parseCompare"}
        }
      ''))
    types));
    tableGuard = directory:
      lib.optionalString (guardOn "tableCells" && selected "markdown" != {}) ''
        pushd ${directory} >/dev/null
        ${lib.getExe tableCells.package} ${lib.escapeShellArgs (lib.attrNames (selected "markdown"))} || {
          ${guardError "tableCells"}
        }
        popd >/dev/null
      '';
    splitGuard = lib.optionalString (guardOn "splitCodeSpans" && selected "markdown" != {}) ''
      pushd check/markdown >/dev/null
      ${pkgs.python3}/bin/python3 ${../checks/markdown/split-code-spans.py} ${lib.escapeShellArgs (lib.attrNames (selected "markdown"))} || {
        ${guardError "splitCodeSpans"}
      }
      popd >/dev/null
    '';
  in
    pkgs.stdenvNoCC.mkDerivation {
      inherit name passthru;
      dontUnpack = true;
      dontConfigure = true;
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        export HOME="$TMPDIR"
        ${pkgs.coreutils}/bin/mkdir -p before work
        ${allFiles (path: file: ''
          install -D -m 644 ${lib.escapeShellArg (sourceOf path file)} work/${file.type}/${lib.escapeShellArg path}
          install -D -m 644 ${lib.escapeShellArg (sourceOf path file)} before/${file.type}/${lib.escapeShellArg path}
        '')}
        ${tableGuard "before/markdown"}
        ${eachType (type:
          lib.optionalString ((formatter.${type} or null) != null) ''
            pushd work/${type} >/dev/null
            ${formatter.${type}}
            popd >/dev/null
          '')}
        runHook postBuild
      '';
      # R8-01: copy only declared paths; formatter-created caches stay in work/.
      installPhase = ''
        runHook preInstall
        ${pkgs.coreutils}/bin/mkdir -p "$out"
        ${allFiles (path: file: ''
          if [ ! -f work/${file.type}/${lib.escapeShellArg path} ]; then
            echo ${lib.escapeShellArg "${name}: formatter removed ${path}"} >&2
            exit 1
          fi
          install -D -m 644 work/${file.type}/${lib.escapeShellArg path} "$out"/${lib.escapeShellArg path}
        '')}
        runHook postInstall
      '';
      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        ${eachType (type: ''
          ${pkgs.coreutils}/bin/mkdir -p check/${type}
          ${withFiles type (path: _: ''              install -D -m 644 "$out"/${lib.escapeShellArg path} check/${type}/${lib.escapeShellArg path}
            '')}
        '')}
        ${tableGuard "check/markdown"}
        ${splitGuard}
        ${parseGuard}
        ${eachType (type:
          lib.optionalString ((check.${type} or "") != "") ''
            pushd check/${type} >/dev/null
            ${check.${type}}
            popd >/dev/null
          '')}
        cd "$out"
        ${lib.concatStrings (lib.mapAttrsToList (path: limit: ''
            ${lib.getExe byteLimitCheck} ${lib.escapeShellArgs [path (toString limit.bytes) name limit.hint]}
          '')
          maxBytes)}
        runHook postInstallCheck
      '';
    };
}
