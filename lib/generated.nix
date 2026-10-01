# Build one store tree per delivery-router invocation. Per-type formatter
# overrides see only their own type at the target-relative paths the runtime
# will receive; treefmt sees every remaining composed file in one invocation.
{lib}: pkgs: let
  types = ["json" "markdown" "toml" "yaml"];
  style = import ./generated-style.nix;
  prettierConfig = (pkgs.formats.json {}).generate "generated-prettier.json" style.prettier;
  prettier = lib.getExe' pkgs.prettier "prettier";
  inherit (import ./markdown/byte-limit.nix pkgs) byteLimitCheck;
  guardDefinitions = import ./markdown/guards.nix {inherit lib;};
  generatedGuard = guardDefinitions.generatedGuard pkgs;
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
    guards,
    maxBytes ? {},
    name,
    passthru ? {},
    runtime,
    treefmt ? null,
  }: let
    sourceOf = path: file:
      file.source or (pkgs.writeText (lib.strings.sanitizeDerivationName (baseNameOf path)) file.text);
    guardTable = guardDefinitions.table pkgs (treefmt != null && treefmt.programs.prettier.enable);
    unknownGuards = lib.subtractLists (lib.attrNames guardTable) (lib.attrNames guards);
    selected = type: lib.filterAttrs (_: file: file.type == type) files;
    withFiles = type: f: lib.concatStrings (lib.mapAttrsToList f (selected type));
    allFiles = f: lib.concatStrings (lib.mapAttrsToList f files);
    selectedGuards = lib.filterAttrs (name: guard:
      (guards.${name} or false)
      && ((guard.runtime or null) == null || guard.runtime == runtime))
    guardTable;
    guardsFor = phase: lib.filterAttrs (_name: guard: guard.phase == phase) selectedGuards;
    eachType = f: lib.concatStrings (map (type: lib.optionalString (selected type != {}) (f type)) types);
    treefmtFiles = lib.concatMap (type:
      lib.optionals ((formatter.${type} or null) == null)
      (map (path: {inherit path type;}) (lib.attrNames (selected type))))
    types;
    treefmtPaths = map (file: file.path) treefmtFiles;
    # Unmarked Markdown carries no generator-owned data to compare.
    parseGuard = guard:
      lib.concatStrings (map (type:
        withFiles type (path: file:
          lib.optionalString (type != "markdown" || file.frontmatter or false) ''
            ${lib.getExe guard.program} ${lib.escapeShellArgs [file.type (sourceOf path file)]} "$out"/${lib.escapeShellArg path}
          ''))
      types);
    markedFrontmatter = action:
      withFiles "markdown" (path: file:
        lib.optionalString (file.frontmatter or false) ''
          ${generatedGuard} ${action} work/markdown/${lib.escapeShellArg path} frontmatter/${lib.escapeShellArg path} || exit 1
        '');
    installPath = type: source: target:
      if type == "raw"
      then ''
        if [ -d ${lib.escapeShellArg source} ]; then
          ${pkgs.coreutils}/bin/mkdir -p ${target}
          ${pkgs.coreutils}/bin/cp -R --preserve=mode ${lib.escapeShellArg source}/. ${target}/
        else
          ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname ${target})"
          ${pkgs.coreutils}/bin/cp --preserve=mode ${lib.escapeShellArg source} ${target}
        fi
        if [ -d ${target} ]; then
          ${pkgs.coreutils}/bin/chmod -R u+w ${target}
        fi
      ''
      else ''
        install -D -m 644 ${lib.escapeShellArg source} ${target}
      '';
    markdownGuard = guard:
      lib.optionalString (selected "markdown" != {}) ''
        pushd work/markdown >/dev/null
        ${lib.getExe guard.program} ${lib.escapeShellArgs (lib.attrNames (selected "markdown"))}
        popd >/dev/null
      '';
    runGuard = name: guard:
      if name == "parseCompare"
      then parseGuard guard
      else if name == "kiroFrontmatterFlow"
      then ''
        mapfile -d "" -t guard_files < <(${pkgs.findutils}/bin/find "$out" -type f -name '*.md' -print0)
        ${lib.getExe guard.program} "''${guard_files[@]}"
      ''
      else markdownGuard guard;
    runGuards = phase: lib.concatStrings (lib.mapAttrsToList runGuard (guardsFor phase));
  in
    assert lib.assertMsg (unknownGuards == [])
    "lib.ai.generated.mkTree: guards may name ${lib.concatStringsSep ", " (lib.attrNames guardTable)}.";
      pkgs.stdenvNoCC.mkDerivation {
        inherit name passthru;
        dontUnpack = true;
        dontConfigure = true;
        dontFixup = true;
        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR"
          ${pkgs.coreutils}/bin/mkdir -p frontmatter work
          ${allFiles (path: file: installPath file.type (sourceOf path file) "work/${file.type}/${lib.escapeShellArg path}")}
          ${runGuards "before"}
          ${markedFrontmatter "split"}
          ${eachType (type:
            lib.optionalString ((formatter.${type} or null) != null) ''
              pushd work/${type} >/dev/null
              ${formatter.${type}}
              popd >/dev/null
            '')}
          ${lib.optionalString (treefmt != null && treefmtPaths != []) ''
            ${pkgs.coreutils}/bin/mkdir -p work/treefmt
            ${lib.concatMapStrings (file:
              installPath file.type "work/${file.type}/${lib.escapeShellArg file.path}" "work/treefmt/${lib.escapeShellArg file.path}")
            treefmtFiles}
            pushd work/treefmt >/dev/null
            ${lib.getExe treefmt.package} --config-file ${treefmt.build.configFile} --tree-root . --walk filesystem --no-cache --on-unmatched=fatal ${lib.escapeShellArgs treefmtPaths}
            popd >/dev/null
            ${lib.concatMapStrings (file:
              installPath file.type "work/treefmt/${lib.escapeShellArg file.path}" "work/${file.type}/${lib.escapeShellArg file.path}")
            treefmtFiles}
          ''}
          ${markedFrontmatter "attach"}
          runHook postBuild
        '';
        # Copy only declared paths.
        installPhase = ''
          runHook preInstall
          ${pkgs.coreutils}/bin/mkdir -p "$out"
          ${allFiles (path: file: installPath file.type "work/${file.type}/${path}" ''"$out"/${lib.escapeShellArg path}'')}
          runHook postInstall
        '';
        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck
          ${runGuards "after"}
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
