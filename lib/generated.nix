# Build one store tree per delivery-router invocation. Each formatter sees only
# its own type at the target-relative paths the runtime will receive.
{lib}: pkgs: let
  types = ["json" "markdown" "toml" "yaml"];
  style = import ./generated-style.nix;
  prettierConfig = (pkgs.formats.json {}).generate "generated-prettier.json" style.prettier;
  prettier = lib.getExe' pkgs.prettier "prettier";
  inherit (import ./markdown/byte-limit.nix pkgs) byteLimitCheck;
  guardLib = import ./markdown/guards.nix {inherit lib;};
  generatedGuard = guardLib.generatedGuard pkgs;
  guardPrograms = guardLib.mkGuards pkgs {
    title = "Generated-file guard";
    fix = "Fix the input or formatter.";
    disable = name: "Disable ai.generated.guards.${name}.";
    optOut = "Set this file's format to raw.";
    see = "See README.md: Generated-file guards.";
  };
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
    # Unmarked Markdown carries no generator-owned data to compare.
    parseGuard = lib.optionalString (guardOn "parseCompare") (lib.concatStrings (map (type:
      withFiles type (path: file:
        lib.optionalString (type != "markdown" || file.frontmatter or false) ''
          ${lib.getExe guardPrograms.parseCompare} ${lib.escapeShellArgs [file.type (sourceOf path file)]} "$out"/${lib.escapeShellArg path}
        ''))
    types));
    markedFrontmatter = action:
      withFiles "markdown" (path: file:
        lib.optionalString (file.frontmatter or false) ''
          ${generatedGuard} ${action} work/markdown/${lib.escapeShellArg path} frontmatter/${lib.escapeShellArg path} || exit 1
        '');
    markdownGuard = guard:
      lib.optionalString (guardOn guard && selected "markdown" != {}) ''
        pushd work/markdown >/dev/null
        ${lib.getExe guardPrograms.${guard}} ${lib.escapeShellArgs (lib.attrNames (selected "markdown"))}
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
        ${markdownGuard "tableCells"}
        ${markdownGuard "splitCodeSpans"}
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
