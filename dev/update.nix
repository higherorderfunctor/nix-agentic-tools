# dev/update.nix — Update task definitions with auto-discovery.
#
# Reads packages/*/hashes.json and .nvfetcher/generated.json at eval
# time. Produces devenv task attrsets with Nix-interpolated exec strings.
# No hardcoded package lists — adding a package to hashes.json is
# sufficient for the update pipeline to discover it.
{lib, ...}: let
  packagesDir = ./../packages;
  nvfetcherDir = ./../.nvfetcher;

  # ── Discovery: overlay groups with hashes ──────────────────────────
  dirs = lib.filterAttrs (_: t: t == "directory") (builtins.readDir packagesDir);

  hashGroups = lib.filterAttrs (_: v: v != null) (lib.mapAttrs (name: _: let
    path = packagesDir + "/${name}/hashes.json";
  in
    if builtins.pathExists path
    then builtins.fromJSON (builtins.readFile path)
    else null)
  dirs);

  # ── Discovery: source metadata from generated.json ────────────────
  generatedJson =
    if builtins.pathExists (nvfetcherDir + "/generated.json")
    then builtins.fromJSON (builtins.readFile (nvfetcherDir + "/generated.json"))
    else {};

  # ── Discovery: lock file directories ───────────────────────────────
  groupsWithLocks = lib.filterAttrs (name: _:
    builtins.pathExists (packagesDir + "/${name}/locks"))
  dirs;

  # ── Derived: packages by hash type ────────────────────────────────
  # Each entry: { group, hashFile, name, ... }
  collectByField = field:
    lib.concatMapAttrs (group: pkgs:
      lib.mapAttrs' (name: _:
        lib.nameValuePair name {
          inherit group name;
          hashFile = toString (packagesDir + "/${group}/hashes.json");
        }) (lib.filterAttrs (_: v: v ? ${field}) pkgs))
    hashGroups;

  npmEntries = collectByField "npmDepsHash";
  srcHashEntries = collectByField "srcHash";
  cargoEntries = collectByField "cargoHash";
  vendorEntries = collectByField "vendorHash";

  # ── Derived: npm packages needing lock file refresh ────────────────
  # Cross-reference npmEntries with generated.json source types
  npmWithSource = lib.mapAttrs (name: entry: let
    src = generatedJson.${name}.src or {};
  in
    entry
    // {
      sourceType = src.type or "unknown";
      sourceUrl = src.url or "";
      sourceRev = src.rev or "";
      lockDir = toString (packagesDir + "/${entry.group}/locks");
    })
  npmEntries;

  # ── Derived: srcHash packages with URLs ────────────────────────────
  srcHashWithUrl = lib.mapAttrs (name: entry: let
    src = generatedJson.${name}.src or {};
  in
    entry // {sourceUrl = src.url or "";})
  srcHashEntries;

  # ── Derived: flake output names for build-hash packages ────────────
  # nvfetcher key usually matches flake output. Override via
  # "flakeOutput" field in hashes.json if they diverge.
  flakeOutput = group: name: let
    pkgAttrs = hashGroups.${group}.${name};
  in
    pkgAttrs.flakeOutput or name;

  # ── Shared bash preamble and helpers ───────────────────────────────
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';

  bashHelpers = ''
    log() { echo "==> $*" >&2; }

    inject_hash() {
      local file=$1 key=$2 field=$3 value=$4
      local tmp
      tmp=$(mktemp)
      jq --arg key "$key" --arg field "$field" --arg val "$value" \
        '.[$key][$field] = $val' "$file" >"$tmp" && mv "$tmp" "$file"
    }
  '';
in {
  inherit bashPreamble bashHelpers flakeOutput;
  inherit npmEntries npmWithSource srcHashEntries srcHashWithUrl;
  inherit cargoEntries vendorEntries groupsWithLocks;

  tasks = {
    "update:flake" = {
      description = "Update flake inputs";
      exec = ''
        ${bashPreamble}
        ${bashHelpers}
        log "Updating flake inputs"
        nix flake update
      '';
      before = ["update:all"];
    };
  };
}
