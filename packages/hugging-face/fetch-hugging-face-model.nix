# fetchHuggingFaceModel — a thin wrapper over nixpkgs' fetchFromHuggingFace.
#
# nixpkgs does the fetching (fetchgit + git LFS) and owns its arguments:
# repoId, rev, repoType, domain, sparseCheckout, nonConeMode, hash, meta,
# passthru and every other fetchgit option pass straight through. This adds
# only:
#
# - `backend` defaults to "lfs". nixpkgs defaults to "xet", which throws
#   "not implemented yet".
# - `files`, exact repo paths. They become `nonConeMode = true` plus anchored,
#   glob-escaped `sparseCheckout` patterns. Pass `sparseCheckout` yourself for
#   globs such as "/*.json"; the two are mutually exclusive, and a caller's
#   `sparseCheckout` defaults `nonConeMode` to true as well.
# - `rev` must be a full commit. `tag` is refused: a tag can be moved, and
#   the default name and version are derived from the commit.
# - `license` defaults to unfree ON PURPOSE. nixpkgs has no
#   `licenses.unknown`, and check-meta treats a derivation with NO
#   meta.license as free (hasUnfreeLicense requires meta.license to be set).
#   Weights with no stated licence therefore have to be marked unfree
#   explicitly: evaluating them then needs allowUnfree (or an
#   allowUnfreePredicate on `pname`, the lowercased repo name), and
#   Hydra-style public caches will not build them. That does NOT keep them
#   out of a cache you push to yourself.
# - `licenseFile` / `attribution`, for licences that require the notice to
#   travel with the work (Apache-2.0 section 4(a), for one) when the
#   repository does not ship it. Either one wraps the fetched tree in a
#   derivation that symlinks its top-level entries and adds LICENSE /
#   ATTRIBUTION at the root. With neither, the fetched tree IS the result.
#   meta (licence included) is on BOTH layers, so the inner fetch, reachable
#   through passthru.fetched, carries the same licence gate.
# - `name` defaults to "<lowercased repo>-<short rev>" rather than "source",
#   with a stable pname/version so lib.getName survives rev bumps and name
#   overrides.
# - meta.position points at the caller's `rev` when the caller gives no
#   meta.description. nixpkgs takes it from meta.description, which the
#   wrapper would otherwise always set, so it named this file.
# - The result has no `override`. nixpkgs' makeOverridable version called
#   fetchFromHuggingFace directly, skipping every default and check above, and
#   kept the old name after a rev change. `overrideAttrs` stays, on both result
#   shapes.
{
  fetchFromHuggingFace,
  lib,
  runCommand,
  writeText,
}: {
  repoId,
  rev ? null,
  attribution ? null,
  backend ? "lfs",
  files ? null,
  license ? lib.licenses.unfree,
  licenseFile ? null,
  meta ? {},
  name ? null,
  passthru ? {},
  ...
} @ args: let
  pname = lib.toLower (baseNameOf repoId);
  version = builtins.substring 0 7 rev;
  drvName =
    if name == null
    then "${pname}-${version}"
    else name;
  # Only when the description is ours: nixpkgs already points a caller's own
  # meta.description at the caller.
  position = lib.optionalAttrs (!(meta ? description)) {
    pos = builtins.unsafeGetAttrPos "rev" args;
  };
  api = "https://${args.domain or "huggingface.co"}/api/${args.repoType or "model"}s/${repoId}";
  validPath = file:
    lib.isString file
    && !(lib.hasPrefix "/" file)
    && builtins.all (segment: !(builtins.elem segment ["" "." ".."])) (lib.splitString "/" file);
  # Non-cone patterns are gitignore syntax: the leading "/" anchors each path
  # at the repository root, and escaping keeps a literal `*`, `?` or `[` in a
  # file name from acting as a glob. A caller's own sparseCheckout also
  # defaults to non-cone: cone mode reads each entry as a DIRECTORY and always
  # checks out every root file, so "/*.json" would still fetch README.md,
  # .gitattributes and the rest of the root.
  selection =
    if files != null
    then {
      nonConeMode = true;
      sparseCheckout = map (file: "/" + lib.escape ["\\" "*" "?" "["] file) files;
    }
    else lib.optionalAttrs (args ? sparseCheckout) {nonConeMode = args.nonConeMode or true;};
  fetched = fetchFromHuggingFace (
    removeAttrs args ["attribution" "files" "license" "licenseFile"]
    // selection
    // {
      inherit backend passthru;
      name = drvName;
      derivationArgs = (args.derivationArgs or {}) // position // {inherit pname version;};
      meta = {description = "${repoId} at ${version} (Hugging Face)";} // meta // {inherit license;};
    }
  );
  notices =
    lib.optional (licenseFile != null) {
      target = "LICENSE";
      source = "${licenseFile}";
    }
    ++ lib.optional (attribution != null) {
      target = "ATTRIBUTION";
      # Through writeText, never interpolated into shell.
      source = writeText "${drvName}-attribution" attribution;
    };
in
  assert lib.assertMsg (!(args ? tag)) "fetchHuggingFaceModel: pass a full commit as `rev`, not `tag`; a tag can be moved.";
  assert lib.assertMsg (lib.isString rev && builtins.match "[0-9a-f]{40}" rev != null) ''
    fetchHuggingFaceModel: rev must be a full 40-hex commit hash, got ${builtins.toJSON rev}.
    Branches and tags are mutable, so they would break the hash. Take the
    commit from the "sha" field of ${api},
    or from the repository's commit history.'';
  assert lib.assertMsg (!(meta ? license)) "fetchHuggingFaceModel: pass the licence as `license`, not `meta.license`.";
  assert lib.assertMsg (files == null || !(args ? sparseCheckout)) "fetchHuggingFaceModel: pass either `files` (exact paths) or `sparseCheckout` (patterns), not both.";
  assert lib.assertMsg (files == null || (lib.isList files && files != [])) "fetchHuggingFaceModel: files must be a non-empty list";
  assert lib.assertMsg (files == null || lib.allUnique (map lib.toLower files)) "fetchHuggingFaceModel: files must be unique, ignoring case (a case-insensitive filesystem would merge them)";
  assert lib.assertMsg (files == null || builtins.all validPath files) "fetchHuggingFaceModel: files must be relative paths with no empty, '.' or '..' segment";
    if notices == []
    then removeAttrs fetched ["override" "overrideDerivation"]
    else
      runCommand drvName ({
          inherit pname version;
          inherit (fetched) meta;
          passthru = passthru // {inherit fetched;};
        }
        // position) ''
        mkdir "$out"
        # One copy of the weights, not two: each symlink is a store reference
        # that also retains the fetched tree against GC.
        find ${fetched} -mindepth 1 -maxdepth 1 -exec ln -s -t "$out" {} +
        # Refuse to shadow a notice the repository already ships. -iname
        # because a case-insensitive filesystem would merge license/LICENSE.
        notice() {
          if [ -n "$(find "$out" -mindepth 1 -maxdepth 1 -iname "$1")" ]; then
            echo "fetchHuggingFaceModel: the fetched tree already has $1. If the repository ships it, fetch it and drop licenseFile / attribution." >&2
            return 1
          fi
          cp "$2" "$out/$1"
        }
        ${lib.concatMapStrings (entry: ''
            notice ${lib.escapeShellArgs [entry.target entry.source]}
          '')
          notices}
      ''
