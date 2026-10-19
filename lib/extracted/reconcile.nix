# Reconcile committed facts, hand rows and named uses. It needs only nixpkgs lib,
# so a consumer that declares options before `pkgs` exists (the git tools'
# option modules) can call it.
{lib}: let
  inherit (import ../redact/classify.nix {inherit lib;}) classify;
  nonBlank = value: builtins.isString value && builtins.match "[[:space:]]*" value == null;
in {
  # Facts carry upstream types. Only string leaves and string-to-string maps
  # enter the classifier; objects and booleans are outside its contract.
  #
  # `patterns` are rows that each stand for every fact whose name they match,
  # for a field repeated under many parents: a `*` in the name matches one
  # key of letters, digits, `_` and `-`. A pattern that matches no fact is
  # stale, and a fact claimed by two rows, a pattern included, is a bad row.
  reconcile = surfaces:
    lib.mapAttrs (surface: {
      facts,
      fields ? [],
      needs ? [],
      patterns ? {},
      rows,
      secretNeeds,
      uses ? {},
    }: let
      matchesOf = pattern: let
        regex = lib.concatMapStringsSep "[A-Za-z0-9_-]+" lib.escapeRegex (lib.splitString "*" pattern);
      in
        builtins.filter (name: builtins.match regex name != null) (builtins.attrNames facts);
      matched = lib.mapAttrs (pattern: _: matchesOf pattern) patterns;
      claims =
        lib.zipAttrs (map (name: {${name} = name;}) (builtins.attrNames rows)
          ++ lib.concatLists (lib.mapAttrsToList (pattern: map (name: {${name} = pattern;})) matched));
      allRows = rows // lib.concatMapAttrs (pattern: names: lib.genAttrs names (_: patterns.${pattern})) matched;
      names = lib.sort builtins.lessThan (lib.unique (builtins.attrNames facts ++ builtins.attrNames allRows ++ builtins.attrNames uses));
      perName = name: let
        present = facts ? ${name};
        recorded = allRows ? ${name};
        fact = facts.${name} or {};
        raw = allRows.${name} or {};
        claimedBy = claims.${name} or [];
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
          || !nonBlank hand.${field}
          || (fact.${field} or null != null && !(replaceValid && builtins.elem field replace)))
        (builtins.attrNames hand);
        ignored = row ? ignored && nonBlank row.ignored;
        entry = fact // lib.filterAttrs (field: _: !(builtins.elem field badFields)) hand;
        missing = lib.filter (field: entry.${field} or null == null) needs;
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
        missingSecret = lib.filter (field: entry.${field} or null == null) secretNeeds;
        badReasons =
          badFields
          ++ lib.optional (!builtins.isAttrs raw) "row must be an object"
          ++ lib.optional (!replaceValid) "replace must list supplied allowed fields"
          ++ lib.optional (row ? ignored && !ignored) "ignored must give a non-blank reason"
          ++ lib.optional (builtins.length claimedBy > 1) "claimed by several rows: ${lib.concatStringsSep ", " claimedBy}";
        bad = badReasons != [];
        failure = kind: details: {
          inherit kind name surface;
          inherit details;
        };
      in {
        inherit entry ignored;
        failures =
          lib.optional (!present) (failure "removed" (uses.${name} or "delete the stale row"))
          ++ lib.optional bad (failure "bad-row" badReasons)
          ++ lib.optionals (present && !ignored) (
            lib.optional (missing != []) (failure "needs-human" missing)
            ++ lib.optional (secret && (!recorded || missingSecret != [])) (failure "secret" missingSecret)
          );
      };
      results = lib.genAttrs names perName;
    in {
      entries = lib.mapAttrs (_: result: result.entry) (lib.filterAttrs (name: result: facts ? ${name} && !result.ignored) results);
      failures =
        lib.concatMap (name: results.${name}.failures) names
        ++ lib.mapAttrsToList (pattern: _: {
          inherit surface;
          details = "delete the stale pattern row";
          kind = "removed";
          name = pattern;
        }) (lib.filterAttrs (_: names: names == []) matched);
    })
    surfaces;
}
