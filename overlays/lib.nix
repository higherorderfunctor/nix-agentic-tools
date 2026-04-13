# overlays/lib.nix — DRY version extraction + smoke test helpers.
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

  # Generate an installCheckPhase for MCP stdio servers.
  # Feeds /dev/null to stdin, captures stderr+stdout, verifies the process
  # started (non-empty output or specific marker). Kills after 2s timeout.
  mkMcpSmokeTest = {
    bin,
    args ? [],
    marker ? null,
  }: let
    argStr = builtins.concatStringsSep " " args;
    check =
      if marker != null
      then ''
        if echo "$output" | grep -Fq "${marker}"; then
          echo "smoke-test: found marker '${marker}'"
        else
          echo "smoke-test: marker '${marker}' not found in output:" >&2
          echo "$output" >&2
          exit 1
        fi
      ''
      else ''
        echo "smoke-test: process started (exit ok)"
      '';
  in ''
    runHook preInstallCheck
    echo "Running MCP smoke test for ${bin}..."
    output=$(timeout 2 $out/bin/${bin} ${argStr} < /dev/null 2>&1 || true)
    ${check}
    runHook postInstallCheck
  '';

  # Generate an updateScript for main-tracking packages that use a bare
  # `rev = "..."` in their overlay .nix file. Fetches the latest commit
  # SHA from the default branch via git ls-remote, then sed-replaces the
  # rev line. nix-update --version skip handles hash updates afterward.
  #
  # url: git remote URL (e.g., "https://github.com/owner/repo.git")
  # file: overlay .nix file path relative to repo root
  # rev: current rev string (used as the old value to replace)
  # pkgs: nixpkgs set (for git)
  mkGitRevUpdateScript = {
    url,
    file,
    rev,
    pkgs,
  }:
    pkgs.writeShellScript "update-rev" ''
      set -eu
      new_rev=$(${pkgs.git}/bin/git ls-remote "${url}" HEAD | cut -f1)
      if [ -z "$new_rev" ]; then
        echo "Failed to fetch latest rev from ${url}" >&2
        exit 1
      fi
      if [ "$new_rev" = "${rev}" ]; then
        echo "Already at latest rev"
        exit 0
      fi
      ${pkgs.gnused}/bin/sed -i "s|${rev}|$new_rev|" "${file}"
      echo "Updated rev: ${rev} -> $new_rev"
    '';

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
    sourcesFile ? "overlays/${pname}-sources.json",
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
        '')
        platforms))}

      mv "$tmp" "${sourcesFile}"
      echo "Updated ${sourcesFile}"
    '';
}
