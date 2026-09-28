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
  shellStrict = import ../../config/shell-strict.nix;
  # Both byte-limit programs are scripts rather than inline shell so the
  # checks execute exactly what the tree and the devenv shell run.
  strictScript = args:
    pkgs.writeShellApplication (args
      // {
        inherit (shellStrict) bashOptions;
        extraShellCheckFlags = shellStrict.shellcheckFlags;
        runtimeInputs = [pkgs.coreutils];
        text = ''
          ${shellStrict.shoptHeader}
          ${args.text}
        '';
      });

  # `FILE BYTES LABEL HINT`: fails when FILE is larger than BYTES. A reader
  # that silently drops everything past its limit is the reason to fail the
  # build instead of shipping the file.
  byteLimitCheck = strictScript {
    name = "ai-markdown-byte-limit";
    text = ''
      if [ "$#" -ne 4 ]; then
        echo "usage: ai-markdown-byte-limit FILE BYTES LABEL HINT" >&2
        exit 2
      fi
      file=$1
      limit=$2
      label=$3
      hint=$4
      size=$(wc -c <"$file")
      if [ "$size" -gt "$limit" ]; then
        echo "$label: $file renders to $size bytes, exceeding its limit ($limit bytes). $hint" >&2
        exit 1
      fi
    '';
  };

  # `FILE BYTES READER`: one warning on stderr when FILE is larger than what
  # READER takes where a raised limit does not apply, and silence otherwise,
  # including when FILE does not exist. It measures the file on disk, so it
  # runs where that file is, at devenv shell entry.
  windowNotice = strictScript {
    name = "ai-markdown-window-notice";
    text = ''
      if [ "$#" -ne 3 ]; then
        echo "usage: ai-markdown-window-notice FILE BYTES READER" >&2
        exit 2
      fi
      file=$1
      limit=$2
      reader=$3
      [ -f "$file" ] || exit 0
      size=$(wc -c <"$file")
      if [ "$size" -gt "$limit" ]; then
        echo "warning: $file is $size bytes; $reader in an untrusted project reads only the first $limit. Trust the project in $reader, or shrink the always-loaded content." >&2
      fi
    '';
  };
in {
  inherit byteLimitCheck windowNotice;

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
        mkdir -p tree
        ${forEachFile (path: file: ''
          install -D -m 644 ${lib.escapeShellArg (sourceOf path file)} tree/${lib.escapeShellArg path}
        '')}
        runHook postBuild
      '';
      # A delivered path points INTO this tree, so a file missing from it is a
      # dangling link or copy at activation. Fail the build instead.
      installPhase = ''
        runHook preInstall
        cp -R tree "$out"
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
