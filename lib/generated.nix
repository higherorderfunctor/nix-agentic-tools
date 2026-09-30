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
    parseCompare = "Parsed JSON, TOML or YAML changed, or generator-owned Markdown frontmatter bytes changed; the runtime could read a different configuration.";
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
in rec {
  defaultFormatter = {
    json = "find . -type f -print0 | xargs -0 -r ${lib.getExe pkgs.biome} format --write --indent-style=${style.biome.indentStyle} --indent-width=${toString style.biome.indentWidth}";
    markdown = "find . -type f -print0 | xargs -0 -r ${prettier} --write --parser markdown --config ${prettierConfig}";
    toml = "find . -type f -print0 | xargs -0 -r ${lib.getExe pkgs.taplo} fmt --no-auto-config";
    yaml = "find . -type f -print0 | xargs -0 -r ${prettier} --write --parser yaml --config ${prettierConfig}";
  };
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
        ${python}/bin/python3 ${./generated-guard.py} ${lib.escapeShellArgs [file.type (lib.boolToString (file.frontmatter or false)) (sourceOf path file)]} "$out"/${lib.escapeShellArg path} || {
          ${guardError "parseCompare"}
        }
      ''))
    types));
    markedFrontmatter = action:
      withFiles "markdown" (path: file:
        lib.optionalString (file.frontmatter or false) ''
          ${python}/bin/python3 ${./generated-guard.py} ${action} work/markdown/${lib.escapeShellArg path} frontmatter/${lib.escapeShellArg path} || exit 1
        '');
    tableGuard = lib.optionalString (guardOn "tableCells" && selected "markdown" != {}) ''
      pushd work/markdown >/dev/null
      ${lib.getExe tableCells.package} ${lib.escapeShellArgs (lib.attrNames (selected "markdown"))} || {
        ${guardError "tableCells"}
      }
      popd >/dev/null
    '';
    splitGuard = lib.optionalString (guardOn "splitCodeSpans" && selected "markdown" != {}) ''
      pushd work/markdown >/dev/null
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
        ${pkgs.coreutils}/bin/mkdir -p frontmatter work
        ${allFiles (path: file: ''
          install -D -m 644 ${lib.escapeShellArg (sourceOf path file)} work/${file.type}/${lib.escapeShellArg path}
        '')}
        ${tableGuard}
        ${splitGuard}
        ${markedFrontmatter "split"}
        ${eachType (type:
          lib.optionalString ((formatter.${type} or null) != null) ''
            pushd work/${type} >/dev/null
            ${formatter.${type}}
            popd >/dev/null
          '')}
        ${markedFrontmatter "attach"}
        runHook postBuild
      '';
      # Copy only declared paths.
      installPhase = ''
        runHook preInstall
        ${pkgs.coreutils}/bin/mkdir -p "$out"
        ${allFiles (path: file: ''
          install -D -m 644 work/${file.type}/${lib.escapeShellArg path} "$out"/${lib.escapeShellArg path}
        '')}
        runHook postInstall
      '';
      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        ${parseGuard}
        ${eachType (type:
          lib.optionalString ((check.${type} or "") != "") ''
            pushd work/${type} >/dev/null
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
