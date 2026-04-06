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

    "update:hashes" = {
      description = "Compute all dependency hashes for discovered packages";
      after = ["update:locks"];
      before = ["update:all"];
      exec = let
        npmCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: ''
            log "Prefetching npmDepsHash for ${name}"
            hash=$(prefetch-npm-deps "${entry.lockDir}/${name}-package-lock.json" 2>/dev/null)
            inject_hash "${entry.hashFile}" "${name}" "npmDepsHash" "$hash"
          '')
          npmWithSource);

        srcHashCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: ''
            log "Prefetching srcHash for ${name}"
            base32=$(nix-prefetch-url --unpack --type sha256 "${entry.sourceUrl}" 2>/dev/null)
            hash=$(nix hash convert --hash-algo sha256 --to sri "$base32")
            inject_hash "${entry.hashFile}" "${name}" "srcHash" "$hash"
          '')
          srcHashWithUrl);

        cargoCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: let
            output = flakeOutput entry.group name;
          in ''
            old_hash=$(jq -r '."${name}".cargoHash // empty' "${entry.hashFile}")
            if [[ -n "$old_hash" ]] && nix build ".#${output}" --no-link 2>/dev/null; then
              log "cargoHash for ${name} is current, skipping"
            else
              log "Prefetching cargoHash for ${name}"
              inject_hash "${entry.hashFile}" "${name}" "cargoHash" \
                "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
              git add "${entry.hashFile}"

              hash=$(
                nix build ".#${output}" 2>&1 |
                  grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' |
                  head -1
              ) || true

              if [[ -n "$hash" ]]; then
                inject_hash "${entry.hashFile}" "${name}" "cargoHash" "$hash"
              else
                log "WARNING: could not determine cargoHash for ${name}"
                inject_hash "${entry.hashFile}" "${name}" "cargoHash" "$old_hash"
              fi
            fi
          '')
          cargoEntries);

        vendorCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: let
            output = flakeOutput entry.group name;
          in ''
            old_hash=$(jq -r '."${name}".vendorHash // empty' "${entry.hashFile}")
            if [[ -n "$old_hash" ]] && nix build ".#${output}" --no-link 2>/dev/null; then
              log "vendorHash for ${name} is current, skipping"
            else
              log "Prefetching vendorHash for ${name}"
              inject_hash "${entry.hashFile}" "${name}" "vendorHash" \
                "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
              git add "${entry.hashFile}"

              hash=$(
                nix build ".#${output}" 2>&1 |
                  grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' |
                  head -1
              ) || true

              if [[ -n "$hash" ]]; then
                inject_hash "${entry.hashFile}" "${name}" "vendorHash" "$hash"
              else
                log "WARNING: could not determine vendorHash for ${name}"
                inject_hash "${entry.hashFile}" "${name}" "vendorHash" "$old_hash"
              fi
            fi
          '')
          vendorEntries);
      in ''
        ${bashPreamble}
        ${bashHelpers}
        ${npmCommands}
        ${srcHashCommands}
        ${cargoCommands}
        ${vendorCommands}
      '';
    };

    "update:locks" = {
      description = "Regenerate npm lock files from upstream sources";
      after = ["update:nvfetcher"];
      before = ["update:all"];
      exec = let
        lockCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: let
          refreshCmd =
            if entry.sourceType == "git"
            then ''
              log "Refreshing lock for ${name} (git)"
              tmp=$(mktemp -d)
              git clone --depth 1 "${entry.sourceUrl}" "$tmp/repo" 2>/dev/null
              (cd "$tmp/repo" && npm install --package-lock-only --ignore-scripts --silent 2>/dev/null)
              cp "$tmp/repo/package-lock.json" "${entry.lockDir}/${name}-package-lock.json"
              rm -rf "$tmp"
            ''
            else ''
              log "Refreshing lock for ${name} (tarball)"
              tmp=$(mktemp -d)
              curl -sL "${entry.sourceUrl}" | tar xz -C "$tmp"
              (cd "$tmp/package" && npm install --package-lock-only --ignore-scripts --silent 2>/dev/null)
              cp "$tmp/package/package-lock.json" "${entry.lockDir}/${name}-package-lock.json"
              rm -rf "$tmp"
            '';
        in
          refreshCmd)
        npmWithSource);
      in ''
        ${bashPreamble}
        ${bashHelpers}
        ${lockCommands}
      '';
    };

    "update:nvfetcher" = {
      description = "Run nvfetcher to refresh source versions";
      after = ["update:flake"];
      before = ["update:all"];
      exec = ''
        ${bashPreamble}
        ${bashHelpers}
        log "Running nvfetcher"
        nvfetcher -c nvfetcher.toml -o .nvfetcher

        log "Formatting generated files"
        treefmt .nvfetcher/generated.nix

        log "Staging nvfetcher output"
        git add .nvfetcher
      '';
    };

    "update:verify" = {
      description = "Stage changes and verify all packages evaluate";
      after = ["update:hashes"];
      before = ["update:all"];
      exec = ''
        ${bashPreamble}
        ${bashHelpers}
        log "Staging changes"
        git add -A

        log "Verifying all packages evaluate"
        nix flake check --no-build 2>&1 | tail -3 || true

        log "Checking lock files for biome formatting"
        if grep -r '"cpu": \["' packages/*/locks/ 2>/dev/null \
          || grep -r '"os": \["' packages/*/locks/ 2>/dev/null; then
          log "ERROR: lock files contain biome-style compact arrays"
          log "Regenerate with: devenv tasks run update:locks"
          exit 1
        fi

        log "Done — review changes with: git diff --cached"
      '';
    };
  };
}
