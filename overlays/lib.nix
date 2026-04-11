# overlays/lib.nix — DRY version extraction from source trees.
#
# Each helper reads a manifest from a Nix store path (src) at eval
# time and returns the upstream version string. Callers combine it
# with `builtins.substring 0 7 rev` to produce "x.y.z+abc1234".
{
  # Format: "{upstream}+{shortrev}"
  mkVersion = {
    upstream,
    rev,
  }: "${upstream}+${builtins.substring 0 7 rev}";

  # Read version from Cargo.toml [package] section.
  readCargoVersion = path:
    (builtins.fromTOML (builtins.readFile path)).package.version;

  # Read version from [workspace.package] in a workspace root Cargo.toml.
  readCargoWorkspaceVersion = path:
    (builtins.fromTOML (builtins.readFile path)).workspace.package.version;

  # Read version from pyproject.toml [project] section.
  readPyprojectVersion = path:
    (builtins.fromTOML (builtins.readFile path)).project.version;

  # Read version from package.json.
  readPackageJsonVersion = path:
    (builtins.fromJSON (builtins.readFile path)).version;

  # Read __version__ = "..." from a Python file.
  readPythonDunderVersion = path: let
    content = builtins.readFile path;
    lines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" content);
    vLine = builtins.head (builtins.filter (l: builtins.match "^__version__ = \".*\"$" l != null) lines);
  in
    builtins.head (builtins.match "^__version__ = \"(.*)\"$" vLine);

  # Generate an updateScript for per-platform binary packages that use
  # sources.json. Fetches the latest version, prefetches each platform's
  # binary, writes version + per-platform hashes to sourcesFile.
  #
  # versionCheck: { cmd = "curl ..."; } — shell command that prints the version
  # platforms: { "x86_64-linux" = ver: "https://.../${ver}/file.tar.gz"; ... }
  # sourcesFile: path to sources.json relative to repo root
  # pkgs: nixpkgs set (for curl, jq, nix)
  mkUpdateScript = {
    pname,
    versionCheck,
    platforms,
    sourcesFile,
    pkgs,
  }:
    pkgs.writeShellScript "update-${pname}" ''
      set -eu
      latest=$(${versionCheck.cmd})
      [ -z "$latest" ] && echo "Failed to fetch latest version" >&2 && exit 1

      current=$(${pkgs.jq}/bin/jq -r '.version' "${sourcesFile}")
      if [ "$latest" = "$current" ]; then
        echo "${pname}: already at $current"
        exit 0
      fi

      echo "${pname}: $current -> $latest"
      tmp=$(mktemp)
      ${pkgs.jq}/bin/jq -n --arg v "$latest" '{version: $v}' > "$tmp"

      ${builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (system: mkUrl: let
        url = mkUrl "$latest";
        # URLs with %20 need --name to avoid illegal store name
        nameArg =
          if builtins.match ".*%20.*" url != null
          then "--name ${pname}.dmg"
          else "";
      in ''
        url="${mkUrl "\$latest"}"
        hash=$(${pkgs.nix}/bin/nix hash convert --to sri --hash-algo sha256 \
          "$(${pkgs.nix}/bin/nix-prefetch-url --type sha256 ${nameArg} "$url" 2>/dev/null)")
        ${pkgs.jq}/bin/jq --arg sys "${system}" --arg u "$url" --arg h "$hash" \
          '. + {($sys): {url: $u, hash: $h}}' "$tmp" > "''${tmp}.new" && mv "''${tmp}.new" "$tmp"
      '') platforms))}

      mv "$tmp" "${sourcesFile}"
      echo "Updated ${sourcesFile}"
    '';
}
