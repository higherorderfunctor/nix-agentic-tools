# Generated Markdown as ONE store tree of target-relative files.
#
# The delivery router builds one Markdown tree per invocation (one per runtime
# per backend, plus the shared AGENTS.md owner) and points every Markdown entry
# at `${tree}/<target path>`, plus a measure-only limited tree for a
# byte-limited non-Markdown file. A tree rather than a file per entry, because
# the tree is where the whole generated set can be processed together as the
# files the runtime will actually read, at the paths it will read them.
#
# The tree is also where the files are formatted and checked, as the files
# the runtime will read: the formatter runs in `buildPhase` with the tree as
# its working directory, and the check in `installCheckPhase` with the
# build's copy of the installed tree as its working directory, so every path
# either sees is target-relative (`.claude/rules/foo.md`).
# `ai.markdown.formatter` and `ai.markdown.check` are the options;
# `defaultFormatter` and `defaultCheck` below are their defaults.
#
# `stdenvNoCC.mkDerivation`, not `runCommand`: the phases are the extension
# points, and `runCommand` skips them — `doInstallCheck` would be inert.
{lib}: pkgs: let
  # The house prose style, rendered the way treefmt-nix renders
  # `programs.prettier.settings`, so the default formatter and this
  # repository's treefmt produce the same bytes.
  prettierrc = (pkgs.formats.json {}).generate "prettierrc.json" (import ./prose-style.nix);
  # rumdl + markdownlint-cli2 MD056, the same script the prek hook runs.
  # Imported lazily: only `defaultCheck` reads it, and a consumer that
  # replaces the check never instantiates either linter.
  tableCells = import ./table-cells.nix {inherit pkgs;};
  inherit (import ./byte-limit.nix pkgs) byteLimitCheck;
in {
  # Both defaults process EVERY file in the tree, not a `*.md` glob: the
  # router selects Markdown by `format`, so every file in a tree given a
  # formatter or a check is Markdown whatever its name (a context file named
  # `CONTEXT` included).

  # The default `ai.markdown.check`: the table-cell check. `%P` drops the
  # leading `./`, so a finding names the target path. xargs turns the
  # script's exit 1 into 123, which still fails the phase.
  defaultCheck = "find . -type f -printf '%P\\0' | LC_ALL=C sort -z | xargs -0 -r ${lib.getExe tableCells.package}";

  # The default `ai.markdown.formatter`: prettier in the house prose style.
  # `--parser markdown` because a name without `.md` gives prettier nothing to
  # infer a parser from.
  defaultFormatter = "find . -type f -print0 | xargs -0 -r ${lib.getExe' pkgs.prettier "prettier"} --write --parser markdown --config ${prettierrc}";

  # `files` is keyed by TARGET-relative path; each value is `{text}` or
  # `{source}`, the shape `aiTypes.textSourceFile` returns. Every file must
  # be Markdown when a formatter or check is given (see the defaults above).
  # `formatter` is a shell snippet run in the tree after the files are
  # installed (null runs nothing); `check` is a shell snippet run in the
  # installed tree ("" runs nothing). `maxBytes` is keyed like `files`, each
  # value `{bytes; hint}`: the built file at that path must not be larger,
  # checked after `check`.
  mkTree = {
    check ? "",
    files,
    formatter ? null,
    maxBytes ? {},
    name,
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
        mkdir -p tree # bare-commands: ok (stdenv builder PATH)
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
        cp -R tree "$out" # bare-commands: ok (stdenv builder PATH)
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
        # The check runs in the build's copy of the tree, byte for byte what
        # installPhase copied to `$out`, and never in `$out` itself: whatever
        # a check wrote into its working directory (a linter's cache, say)
        # would ship in the tree and be delivered as Markdown. Not a
        # read-only `$out` instead: `testers.testBuildFailure` writes its log
        # into `$out` after the builder fails, which the byte-limit checks
        # rely on.
        pushd tree >/dev/null
        ${check}
        popd >/dev/null
        cd "$out"
        ${lib.concatStrings (lib.mapAttrsToList (path: limit: ''
            ${lib.getExe byteLimitCheck} ${lib.escapeShellArgs [path (toString limit.bytes) name limit.hint]}
          '')
          maxBytes)}
        runHook postInstallCheck
      '';
    };
}
