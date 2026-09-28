# Generated Markdown as ONE store tree of target-relative files.
#
# The delivery router builds one tree per invocation (one per runtime per
# backend, plus the shared AGENTS.md owner) and points every Markdown entry at
# `${tree}/<target path>`. A tree rather than a file per entry, because the
# tree is where the whole generated set can be processed together as the files
# the runtime will actually read, at the paths it will read them.
#
# `stdenvNoCC.mkDerivation`, not `runCommand`: the phases are the extension
# points, and `runCommand` skips them.
{lib}: pkgs: let
  inherit (import ./byte-limit.nix pkgs) byteLimitCheck;
in {
  # `files` is keyed by TARGET-relative path; each value is `{text}` or
  # `{source}`, the shape `aiTypes.textSourceFile` returns. `maxBytes` is
  # keyed the same way, each value `{bytes; hint}`: the built file at that
  # path must not be larger, checked after the tree is installed.
  mkTree = {
    name,
    files,
    maxBytes ? {},
    passthru ? {},
  }: let
    # `writeText` rather than `builtins.toFile`: generated text can carry
    # store-path context, which `toFile` rejects. The store name is only a
    # label; `sanitizeDerivationName` keeps a key with a space or a leading
    # dot a valid one.
    sourceOf = path: file:
      file.source or (pkgs.writeText (lib.strings.sanitizeDerivationName (baseNameOf path)) file.text);
    forEachFile = line: lib.concatStrings (lib.mapAttrsToList line files);
  in
    pkgs.stdenvNoCC.mkDerivation {
      inherit name passthru;
      dontUnpack = true;
      dontConfigure = true;
      # Nothing in a Markdown tree needs fixup, and it keeps patchShebangs and
      # strip away from consumer files.
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        mkdir -p tree # bare-commands: ok (stdenv builder PATH)
        ${forEachFile (path: file: ''
          install -D -m 644 ${lib.escapeShellArg (sourceOf path file)} tree/${lib.escapeShellArg path}
        '')}
        runHook postBuild
      '';
      # A delivered path points INTO this tree, so a file missing from it is a
      # dangling link or copy at activation. Fail the build instead.
      installPhase = ''
        runHook preInstall
        cp -R tree "$out" # bare-commands: ok (stdenv builder PATH)
        ${forEachFile (path: _file: ''
          [ -f "$out"/${lib.escapeShellArg path} ] || {
            echo ${lib.escapeShellArg "${name}: ${path} is missing from the built tree"} >&2
            exit 1
          }
        '')}
        runHook postInstall
      '';
      doInstallCheck = maxBytes != {};
      installCheckPhase = ''
        runHook preInstallCheck
        cd "$out"
        ${lib.concatStrings (lib.mapAttrsToList (path: limit: ''
            ${lib.getExe byteLimitCheck} ${lib.escapeShellArgs [path (toString limit.bytes) name limit.hint]}
          '')
          maxBytes)}
        runHook postInstallCheck
      '';
    };
}
