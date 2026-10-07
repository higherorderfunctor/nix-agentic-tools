{pkgs}: let
  inherit (pkgs) lib;
  inherit (import ../runtime-values {inherit lib;}) classify;
  nonBlank = value: builtins.isString value && builtins.match "[[:space:]]*" value == null;
in {
  # Facts carry upstream types. Only string leaves and string-to-string maps
  # enter the classifier; objects and booleans are outside its contract.
  reconcile = surfaces:
    lib.mapAttrs (surface: {
      facts,
      fields ? [],
      needs ? [],
      rows,
      secretNeeds,
      uses ? {},
    }: let
      names = lib.sort builtins.lessThan (lib.unique (builtins.attrNames facts ++ builtins.attrNames rows ++ builtins.attrNames uses));
      perName = name: let
        present = facts ? ${name};
        recorded = rows ? ${name};
        fact = facts.${name} or {};
        raw = rows.${name} or {};
        row =
          if builtins.isAttrs raw
          then raw
          else {};
        replace = row.replace or [];
        replaceValid = builtins.isList replace && lib.all (field: builtins.isString field && row ? ${field} && builtins.elem field (fields ++ needs)) replace;
        allowed = fields ++ needs ++ ["ignored" "replace"];
        hand = builtins.removeAttrs row ["ignored" "replace"];
        badFields = lib.filter (field:
          !(builtins.elem field allowed)
          || (fact.${field} or null != null && !(replaceValid && builtins.elem field replace)))
        (builtins.attrNames hand);
        ignored = row ? ignored && nonBlank row.ignored;
        entry = fact // lib.filterAttrs (field: _: !(builtins.elem field badFields)) hand;
        missing = lib.filter (field: !nonBlank (entry.${field} or null)) needs;
        # An explicit type replacement must not hide a known string secret.
        # Use a filled type only when extraction could not derive one.
        typed =
          if fact.type or null == null
          then entry
          else fact;
        stringValued = typed.type or null == "string" || (typed.type or null == "object" && typed.additionalProperties.type or null == "string");
        secret =
          stringValued
          && classify {
            path = [name];
            hints = fact;
          };
        missingSecret = lib.filter (field: !nonBlank (row.${field} or null)) secretNeeds;
        badReasons =
          badFields
          ++ lib.optional (!builtins.isAttrs raw) "row must be an object"
          ++ lib.optional (!replaceValid) "replace must list supplied allowed fields"
          ++ lib.optional (row ? ignored && !ignored) "ignored must give a non-blank reason";
        bad = badReasons != [];
        failure = kind: details: {
          inherit kind name surface;
          inherit details;
        };
        added = present && !ignored && !bad && missing == [] && !secret && !recorded;
      in {
        inherit added entry ignored;
        failures =
          lib.optional (!present) (failure "removed" (uses.${name} or "delete the stale row"))
          ++ lib.optional bad (failure "bad-row" badReasons)
          ++ lib.optionals (present && !ignored) (
            lib.optional (missing != []) (failure "needs-human" missing)
            ++ lib.optional (secret && missingSecret != []) (failure "secret" missingSecret)
          )
          ++ lib.optional added (failure "unrecorded" "regenerate the rows");
      };
      results = lib.genAttrs names perName;
    in {
      added = lib.filter (name: results.${name}.added) names;
      entries = lib.mapAttrs (_: result: result.entry) (lib.filterAttrs (name: result: facts ? ${name} && !result.ignored) results);
      failures = lib.concatMap (name: results.${name}.failures) names;
    })
    surfaces;

  # Preserve hand rows and grouped ignores, adding only accepted new names.
  withAdded = rows: results:
    rows // lib.mapAttrs (surface: result: (rows.${surface} or {}) // lib.genAttrs result.added (_: {})) results;

  mkDriftCheck = {
    committed,
    extracted,
    name,
    results ? {},
    rows ? {},
    rowsPath ? null,
    # The sidecar's repository path, as a string, for messages only. A path
    # derived from `committed` would move with its owner, and
    # checks.facet-owner-relocation requires the check not to.
    sidecar,
  }: let
    failures = lib.concatMap (surface: surface.failures) (builtins.attrValues results);
    rowsCommand = "nix eval --json .#checks.${pkgs.stdenv.hostPlatform.system}.${name}-extracted.passthru.rows > extracted-rows.tmp && mv extracted-rows.tmp ${rowsPath} && nix fmt -- ${rowsPath}"; # bare-commands: ok — printed repository-root recipe
    printRowsCommand = lib.optionalString (rowsPath != null) "echo ${lib.escapeShellArg ("  " + rowsCommand)} >&2";
  in {
    "${name}-extracted" =
      pkgs.runCommand "${name}-extracted-drift" {
        passthru = {inherit extracted;} // lib.optionalAttrs (rowsPath != null) {inherit rows;};
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        jq="${pkgs.jq}/bin/jq"
        if ! "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} '$a == $b' > /dev/null; then
          echo "FAIL: ${name} sidecar (${sidecar}) is out of sync with its extraction sources." >&2
          "$jq" -S . ${committed} > committed.json
          "$jq" -S . ${extracted} > extracted.json
          ${pkgs.diffutils}/bin/diff -u committed.json extracted.json >&2 || :
          echo "Regenerate from the repository root:" >&2
          echo '  extracted="$(nix build --no-link --print-out-paths .#checks.${pkgs.stdenv.hostPlatform.system}.${name}-extracted.passthru.extracted)"' >&2
          echo '  cp "$extracted" ${sidecar}' >&2
          echo '  nix fmt -- ${sidecar}' >&2
          ${printRowsCommand}
          exit 1
        fi
        ${lib.optionalString (failures != []) ''
          echo 'FAIL: ${name} extraction rows need attention:' >&2
          "$jq" . ${pkgs.writeText "${name}-extracted-failures.json" (builtins.toJSON failures)} >&2
          ${lib.optionalString (lib.any (failure: failure.kind == "unrecorded") failures) printRowsCommand}
          exit 1
        ''}
        echo "ok — ${name} sidecar matches the fresh extraction" > "$out"
      '';
  };
}
