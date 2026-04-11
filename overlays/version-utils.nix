# overlays/version-utils.nix — DRY version extraction from source trees.
#
# Each helper reads a manifest from a Nix store path (src) at eval
# time and returns the upstream version string. Callers combine it
# with `builtins.substring 0 7 rev` to produce "x.y.z+abc1234".
let
  # Shared: read the first `version = "..."` line from a TOML file.
  readTomlVersion = tomlPath: let
    content = builtins.readFile tomlPath;
    lines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" content);
    vLine = builtins.head (builtins.filter (l: builtins.match "^version = \".*\"$" l != null) lines);
  in
    builtins.head (builtins.match "^version = \"(.*)\"$" vLine);

  # Read version from the [workspace.package] section of a Cargo.toml.
  # Skips lines until after the `[workspace.package]` header, then
  # returns the first `version = "..."` in that section.
  readTomlSectionVersion = {
    tomlPath,
    section,
  }: let
    content = builtins.readFile tomlPath;
    lines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" content);
    # Find index of the section header
    indexed = builtins.genList (i: {
      idx = i;
      line = builtins.elemAt lines i;
    }) (builtins.length lines);
    sectionIdx = (builtins.head (builtins.filter (e: e.line == "[${section}]") indexed)).idx;
    # Lines after the section header
    afterSection = builtins.genList (i: builtins.elemAt lines (sectionIdx + 1 + i)) (builtins.length lines - sectionIdx - 1);
    # Take lines until the next section header
    inSection = let
      go = acc: remaining:
        if remaining == []
        then acc
        else let
          h = builtins.head remaining;
        in
          if builtins.match "^[[].*[]]$" h != null
          then acc
          else go (acc ++ [h]) (builtins.tail remaining);
    in
      go [] afterSection;
    vLine = builtins.head (builtins.filter (l: builtins.match "^version = \".*\"$" l != null) inSection);
  in
    builtins.head (builtins.match "^version = \"(.*)\"$" vLine);
in {
  # Format: "{upstream}+{shortrev}"
  mkVersion = {
    upstream,
    rev,
  }: "${upstream}+${builtins.substring 0 7 rev}";

  # Read version from Cargo.toml (single-crate or [package] section).
  readCargoVersion = readTomlVersion;

  # Read version from [workspace.package] in a workspace root Cargo.toml.
  readCargoWorkspaceVersion = cargoTomlPath:
    readTomlSectionVersion {
      tomlPath = cargoTomlPath;
      section = "workspace.package";
    };

  # Read version from pyproject.toml.
  readPyprojectVersion = readTomlVersion;

  # Read version from package.json.
  readPackageJsonVersion = packageJsonPath: let
    pkg = builtins.fromJSON (builtins.readFile packageJsonPath);
  in
    pkg.version;

  # Read __version__ = "..." from a Python file.
  readPythonDunderVersion = pyFilePath: let
    content = builtins.readFile pyFilePath;
    lines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" content);
    vLine = builtins.head (builtins.filter (l: builtins.match "^__version__ = \".*\"$" l != null) lines);
  in
    builtins.head (builtins.match "^__version__ = \"(.*)\"$" vLine);
}
