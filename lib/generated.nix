# Build one store tree per delivery-router invocation. Treefmt formats whole
# composed files at target-relative paths; raw copies share the staging root.
{lib}: pkgs: let
  types = ["json" "markdown" "toml" "yaml"];
  inherit (import ./markdown/byte-limit.nix pkgs) byteLimitCheck;
  guardDefinitions = import ./markdown/guards.nix {inherit lib;};
in {
  mkTree = {
    checks ? {},
    files,
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
    surfaceFiles = surface: lib.filterAttrs (_: file: (file.surface or null) == surface) files;
    eachSurface = f: lib.concatStrings (map (surface: lib.optionalString (surfaceFiles surface != {}) (f surface)) (builtins.attrNames checks));
    surfaceCheck = surface:
      pkgs.writeShellScript "ai-${runtime}-${surface}-check" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        ai_surface_check() {
          :
          ${checks.${surface}}
        }

        ai_surface_check "$@"
      '';
    treefmtPaths = lib.attrNames (lib.filterAttrs (_: file: builtins.elem file.type types) files);
    parseGuard = guard:
      lib.concatStrings (map (type:
        withFiles type (path: file: ''
          ${lib.getExe guard.program} ${lib.escapeShellArgs [file.type (sourceOf path file)]} "$out"/${lib.escapeShellArg path}
        ''))
      types);
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
        pushd work >/dev/null
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
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          runHook preBuild
          export HOME="$TMPDIR"
          ${pkgs.coreutils}/bin/mkdir -p work
          ${allFiles (path: file: installPath file.type (sourceOf path file) "work/${lib.escapeShellArg path}")}
          ${runGuards "before"}
          ${lib.optionalString (treefmt != null && treefmtPaths != []) ''
            pushd work >/dev/null
            ${lib.getExe treefmt.package} --config-file ${treefmt.build.configFile} --tree-root . --walk filesystem --no-cache --on-unmatched=fatal ${lib.escapeShellArgs treefmtPaths}
            popd >/dev/null
          ''}
          runHook postBuild
        '';
        # Copy only declared paths.
        installPhase = ''
          runHook preInstall
          ${pkgs.coreutils}/bin/mkdir -p "$out"
          ${allFiles (path: file: installPath file.type "work/${path}" ''"$out"/${lib.escapeShellArg path}'')}
          runHook postInstall
        '';
        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck
          ${runGuards "after"}
          cd "$out"
          ${eachSurface (surface:
            lib.optionalString (checks.${surface} != "") ''
              echo "Running generated-file check for ${surface} in ${runtime}" >&2
              export AI_RUNTIME=${lib.escapeShellArg runtime}
              if ${surfaceCheck surface} ${lib.escapeShellArgs (builtins.attrNames (surfaceFiles surface))}; then
                :
              else
                status=$?
                echo "Generated-file check failed for surface ${surface} in runtime ${runtime} (exit $status)" >&2
                exit "$status"
              fi
            '')}
          ${lib.concatStrings (lib.mapAttrsToList (path: limit: ''
              ${lib.getExe byteLimitCheck} ${lib.escapeShellArgs [path (toString limit.bytes) name limit.hint]}
            '')
            maxBytes)}
          runHook postInstallCheck
        '';
      };
}
