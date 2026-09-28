# Generated Markdown as ONE store tree of target-relative files.
#
# The delivery router builds one tree per invocation (one per runtime per
# backend, plus the shared AGENTS.md owner) and points every Markdown entry at
# `${tree}/<target path>`. A tree rather than a file per entry, because the
# tree is where the whole generated set can be processed together as the files
# the runtime will actually read, at the paths it will read them.
#
# The tree is also where the files are formatted and checked, as the files
# the runtime will read: the formatter runs in `buildPhase` with the tree as
# its working directory, and the check in `installCheckPhase` with `$out` as
# its working directory, so every path either sees is target-relative
# (`.claude/rules/foo.md`). `ai.markdown.formatter` and `ai.markdown.check`
# are the options; `defaultFormatter` and `defaultCheck` below are their
# defaults.
#
# `stdenvNoCC.mkDerivation`, not `runCommand`: the phases are the extension
# points, and `runCommand` skips them — `doInstallCheck` would be inert.
{lib}: pkgs: let
  shellStrict = import ../../config/shell-strict.nix;
  # The house prose style, rendered the way treefmt-nix renders
  # `programs.prettier.settings`, so the default formatter and this
  # repository's treefmt produce the same bytes.
  prettierrc = (pkgs.formats.json {}).generate "prettierrc.json" (import ./prose-style.nix);
  # rumdl + markdownlint-cli2 MD056, the same script the prek hook runs.
  # Imported lazily: only `defaultCheck` reads it, and a consumer that
  # replaces the check never instantiates either linter.
  tableCells = import ./table-cells.nix {inherit pkgs;};
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

  # The default `ai.markdown.formatter`: prettier in the house prose style over
  # every Markdown file in the tree.
  defaultFormatter = "find . -type f -name '*.md' -print0 | xargs -0 -r ${lib.getExe' pkgs.prettier "prettier"} --write --config ${prettierrc}";

  # The default `ai.markdown.check`: the table-cell check over every Markdown
  # file in the tree. `%P` drops the leading `./`, so a finding names the
  # target path. xargs turns the script's exit 1 into 123, which still fails
  # the phase.
  defaultCheck = "find . -type f -name '*.md' -printf '%P\\0' | LC_ALL=C sort -z | xargs -0 -r ${lib.getExe tableCells.package}";

  # `files` is keyed by TARGET-relative path; each value is `{text}` or
  # `{source}`, the shape `aiTypes.textSourceFile` returns. `formatter` is a
  # shell snippet run in the tree after the files are installed (null runs
  # nothing); `check` is a shell snippet run in the installed tree ("" runs
  # nothing). `maxBytes` is keyed like `files`, each value `{bytes; hint}`:
  # the built file at that path must not be larger, checked after `check`.
  mkTree = {
    name,
    files,
    formatter ? null,
    check ? "",
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
        # prettier and markdownlint-cli2 want a writable HOME; the sandbox's
        # does not exist. The phases share one shell, so the check sees it too.
        export HOME="$TMPDIR"
        mkdir -p tree
        ${forEachFile (path: file: ''
          install -D -m 644 ${lib.escapeShellArg (sourceOf path file)} tree/${lib.escapeShellArg path}
        '')}
        ${lib.optionalString (formatter != null) ''
          pushd tree >/dev/null
          ${formatter}
          popd >/dev/null
        ''}
        runHook postBuild
      '';
      # A delivered path points INTO this tree, so a file missing from it — a
      # formatter that deleted or renamed one, say — is a dangling link or
      # copy at activation. Fail the build instead.
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
      doInstallCheck = check != "" || maxBytes != {};
      installCheckPhase = ''
        runHook preInstallCheck
        cd "$out"
        ${check}
        ${lib.concatStrings (lib.mapAttrsToList (path: limit: ''
            ${lib.getExe byteLimitCheck} ${lib.escapeShellArgs [path (toString limit.bytes) name limit.hint]}
          '')
          maxBytes)}
        runHook postInstallCheck
      '';
    };
}
